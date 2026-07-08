defmodule Librarian.Flusher do
  @moduledoc """
  The thing that actually moves memory between tiers. Deliberately a
  plain module with functions you can call by hand (great for the demo
  and for tests) rather than something hidden behind a timer — wire it
  to a timer (or `Librarian.Scheduler`) once you trust it.

      Librarian.Flusher.flush_bucket("project")   # HOT -> WARM, via Curator
      Librarian.Flusher.flush_all()                # every active bucket
      Librarian.Flusher.archive_stale()            # WARM -> COLD, low importance

  Ingestion here is ADD-only, on purpose — same idea Mem0's 2026
  algorithm leans on: don't ask a model (especially a small local one)
  to read-modify-write an existing memory in one pass, since that's a
  multi-step logical-state-tracking task small models are bad at.
  Instead, always append a new memory, then let deterministic code
  (not a model call) decide whether it supersedes something older with
  high tag overlap in the same `:supersede`-policy bucket. The model's
  only job is extraction; resolution is a code problem, which is exactly
  the kind of problem Elixir is good at doing cheaply and concurrently.
  """

  @supersede_tag_overlap_threshold 0.5

  @doc """
  Drain one HOT bucket's payloads and run each through the curator, storing
  the result in WARM under the *curator-assigned* bucket (not the HOT
  staging bucket name). The HOT bucket is just a per-user buffer
  ("user_id:inbox"); the semantic bucket decision belongs to the curator
  at flush time, which is what lets the model override the old ingest-time
  keyword routing.
  """
  def flush_bucket(bucket) do
    case Librarian.HotStore.drain(bucket) do
      [] ->
        :empty

      payloads ->
        user_id = bucket |> String.split(":") |> hd()

        results =
          Enum.map(payloads, fn payload ->
            case Librarian.Curator.summarize([payload]) do
              {:ok, result} ->
                result =
                  case Librarian.Curator.embed(result.summary) do
                    {:ok, vec} -> %{result | embedding: vec}
                    _ -> result
                  end

                warm_bucket = "#{user_id}:#{result.bucket || "inbox"}"
                memory = Librarian.WarmStore.put(warm_bucket, result)
                {:ok, memory}

              {:error, reason} ->
                # Put this payload back so a curator failure loses nothing.
                Librarian.HotStore.put(bucket, payload)
                {:error, reason}
            end
          end)

        Librarian.Wal.truncate(bucket)
        Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:flushed, bucket})

        case Enum.filter(results, &match?({:ok, _}, &1)) do
          [] -> {:error, :all_failed}
          ok -> {:ok, Enum.map(ok, fn {:ok, m} -> m end)}
        end
    end
  end

  # Deterministic, not model-driven: does an older memory in the same
  # bucket share enough tags with the new one to plausibly be "the same
  # claim, updated"? If so and the bucket's policy is :supersede, mark it.
  # This is a heuristic stand-in for real contradiction detection — it
  # will false-positive on "two unrelated things that happen to share
  # tags" and false-negative on "same claim, totally different wording."
  # Good enough to demo the mechanism; a real Curator backend should
  # eventually do this check with actual semantic comparison instead.
  defp maybe_supersede(%Librarian.WarmStore.Memory{} = new_memory) do
    policies = Application.get_env(:librarian, :decay_policies, %{})
    bare = new_memory.bucket |> String.split(":") |> List.last()

    policy =
      Map.get(
        policies,
        new_memory.bucket,
        Map.get(policies, bare, Application.get_env(:librarian, :default_decay_policy, :decay))
      )

    if policy == :supersede do
      candidates =
        Librarian.WarmStore.by_bucket(new_memory.bucket)
        |> Enum.filter(&(&1.id != new_memory.id and is_nil(&1.superseded_by)))

      case Enum.find(
             candidates,
             &(tag_overlap_ratio(&1.tags, new_memory.tags) >= @supersede_tag_overlap_threshold)
           ) do
        nil ->
          :ok

        old_memory ->
          # If the summaries are identical, this is a duplicate, not an
          # evolution. Don't log a spurious supersession — just skip it.
          if old_memory.summary == new_memory.summary do
            :ok
          else
            Librarian.WarmStore.supersede(old_memory.id, new_memory.id)

            Librarian.ColdStore.log_insight(%{
              "kind" => "supersession",
              "bucket" => new_memory.bucket,
              "old_id" => old_memory.id,
              "new_id" => new_memory.id,
              "old_summary" => old_memory.summary,
              "new_summary" => new_memory.summary
            })
          end
      end
    end
  end

  defp tag_overlap_ratio([], _), do: 0.0
  defp tag_overlap_ratio(_, []), do: 0.0

  defp tag_overlap_ratio(tags_a, tags_b) do
    a = MapSet.new(tags_a)
    b = MapSet.new(tags_b)
    smaller = min(MapSet.size(a), MapSet.size(b))

    if smaller == 0,
      do: 0.0,
      else: MapSet.intersection(a, b) |> MapSet.size() |> Kernel./(smaller)
  end

  @doc "Flush every bucket that currently has HOT data."
  def flush_all(max_concurrency \\ 1) do
    buckets = Librarian.HotStore.buckets()

    if max_concurrency > 1 do
      buckets
      |> Task.async_stream(&flush_bucket/1, max_concurrency: max_concurrency, timeout: 60_000)
      |> Enum.map(fn {bucket, result} -> {bucket, result} end)
    else
      buckets
      |> Enum.map(fn bucket -> {bucket, flush_bucket(bucket)} end)
    end
  end

  @doc "Move anything in WARM below the relevance threshold into the durable COLD archive, then drop it from WARM."
  def archive_stale(threshold \\ 0.15) do
    Librarian.WarmStore.low_relevance(threshold)
    |> Enum.map(fn memory ->
      user_id = memory.bucket |> String.split(":") |> hd()
      Librarian.ColdStore.archive(memory, user_id)
      Librarian.WarmStore.forget(memory.id)
      memory.id
    end)
  end

  @doc """
  The "nightly curator" / dream-cycle pass:

    1. Decay WARM memory importance (per-bucket policy applies — see
       `Librarian.WarmStore.decay_all/1`).
    2. Archive whatever fell below the threshold to COLD.
    3. Run a Qwen deep-reasoning pass over all WARM memories when
       the Hybrid curator is configured — this finds cross-bucket
       connections, detects contradictions, and re-ranks importance
       scores that the local small model may have gotten wrong.

  Cross-bucket associative links discovered during the day (via
  `maybe_supersede/1`, or `Librarian.recall/1`'s synaptic-jump lookups)
  are already logged to `priv/cold/insights.jsonl` as they happen.
  """
  def nightly_pass(opts \\ []) do
    half_life = Keyword.get(opts, :half_life_seconds, 60 * 60 * 24 * 14)
    threshold = Keyword.get(opts, :archive_threshold, 0.15)

    Librarian.WarmStore.decay_all(half_life)
    archived = archive_stale(threshold)

    # Deep pass: only when Hybrid curator is configured
    deep =
      case Application.get_env(:librarian, :curator, Librarian.Curator.Stub) do
        Librarian.Curator.Hybrid ->
          memories = Librarian.WarmStore.all()

          case Librarian.Curator.Hybrid.deep_pass(memories) do
            {:ok, actions} ->
              apply_deep_pass_actions(actions)
              actions

            {:error, reason} ->
              require Logger
              Logger.warning("Nightly pass deep_pass failed: #{inspect(reason)}")
              %{error: reason}
          end

        _ ->
          %{skipped: :no_hybrid_curator}
      end

    %{archived: archived, deep: deep}
  end

  defp apply_deep_pass_actions(actions) do
    # Apply supersessions Qwen detected
    Enum.each(actions[:supersessions] || [], fn %{"old_id" => old_id, "new_id" => new_id} ->
      Librarian.WarmStore.supersede(old_id, new_id)

      Librarian.ColdStore.log_insight(%{
        "kind" => "deep_supersession",
        "old_id" => old_id,
        "new_id" => new_id
      })
    end)

    # Apply re-scores
    Enum.each(actions[:re_scores] || [], fn %{"id" => id, "importance" => imp} ->
      case Librarian.WarmStore.get(id) do
        nil ->
          :ok

        memory ->
          updated = %{memory | importance: imp}
          :ets.insert(Librarian.WarmStore, {id, updated})
      end
    end)

    # Log cross-connections as insights
    Enum.each(actions[:cross_connections] || [], fn conn ->
      Librarian.ColdStore.log_insight(%{
        "kind" => "deep_cross_connection",
        "id_a" => conn["id_a"],
        "id_b" => conn["id_b"],
        "note" => conn["note"]
      })
    end)

    # Apply new tags
    Enum.each(actions[:new_tags] || [], fn %{"id" => id, "tags" => tags} ->
      case Librarian.WarmStore.get(id) do
        nil ->
          :ok

        memory ->
          updated = %{memory | tags: Enum.uniq((memory.tags || []) ++ (tags || []))}
          :ets.insert(Librarian.WarmStore, {id, updated})
      end
    end)
  end
end

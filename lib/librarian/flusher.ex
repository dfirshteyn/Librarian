defmodule Librarian.Flusher do
  @moduledoc """
  The thing that actually moves memory between tiers. Deliberately a
  plain module with functions you can call by hand (great for the demo
  and for tests) rather than something hidden behind a timer — wire it
  to a timer (or `Librarian.Scheduler`) once you trust it.

      Librarian.Flusher.flush_bucket("project")   # HOT -> WARM, via Curator
      Librarian.Flusher.flush_all()                # every active bucket
      Librarian.Flusher.archive_stale()            # WARM -> COLD, low importance

  The flusher is a pure APPEND-ONLY write path — it drains HOT, runs the
  curator for summarization/embedding, and writes to WARM. All semantic
  deduplication, contradiction resolution, and supersession is handled
  asynchronously by the tournament-bracket consolidator, which uses real
  cosine similarity (not a tag-heuristic threshold) to merge clusters.
  """

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

  Cross-bucket associative links discovered during recall (via
  `Librarian.recall/1`'s synaptic-jump lookups) are logged to
  `priv/cold/insights.jsonl` as they happen. Supersessions are handled
  by the tournament-bracket consolidator, not inline during flush.
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

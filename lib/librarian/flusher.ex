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

  @doc "Drain one bucket's HOT payloads, run them through the curator, store the result in WARM."
  def flush_bucket(bucket) do
    case Librarian.HotStore.drain(bucket) do
      [] ->
        :empty

      payloads ->
        case Librarian.Curator.summarize(payloads) do
          {:ok, result} ->
            # Enrich with embedding if the backend supports it.
            # QwenApi returns {:error, :not_implemented}; Stub returns a real
            # vector. Either way recall/1 degrades gracefully on nil.
            result =
              case Librarian.Curator.embed(result.summary) do
                {:ok, vec} -> %{result | embedding: vec}
                _ -> result
              end

            memory = Librarian.WarmStore.put(bucket, result)
            maybe_supersede(memory)
            Librarian.Wal.truncate(bucket)
            Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:flushed, bucket})
            {:ok, memory}

          {:error, reason} ->
            # put the payloads back rather than lose them on a curator failure —
            # this is the "let it crash, don't let it lose data" behaviour.
            Enum.each(payloads, &Librarian.HotStore.put(bucket, &1))
            {:error, reason}
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
    policy = Map.get(policies, new_memory.bucket,
      Map.get(policies, bare,
        Application.get_env(:librarian, :default_decay_policy, :decay)))

    if policy == :supersede do
      candidates =
        Librarian.WarmStore.by_bucket(new_memory.bucket)
        |> Enum.filter(&(&1.id != new_memory.id and is_nil(&1.superseded_by)))

      case Enum.find(candidates, &tag_overlap_ratio(&1.tags, new_memory.tags) >= @supersede_tag_overlap_threshold) do
        nil ->
          :ok

        old_memory ->
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

  defp tag_overlap_ratio([], _), do: 0.0
  defp tag_overlap_ratio(_, []), do: 0.0

  defp tag_overlap_ratio(tags_a, tags_b) do
    a = MapSet.new(tags_a)
    b = MapSet.new(tags_b)
    smaller = min(MapSet.size(a), MapSet.size(b))
    if smaller == 0, do: 0.0, else: MapSet.intersection(a, b) |> MapSet.size() |> Kernel./(smaller)
  end

  @doc "Flush every bucket that currently has HOT data."
  def flush_all do
    Librarian.HotStore.buckets()
    |> Enum.map(fn bucket -> {bucket, flush_bucket(bucket)} end)
  end

  @doc "Move anything in WARM below the relevance threshold into the durable COLD archive, then drop it from WARM."
  def archive_stale(threshold \\ 0.15) do
    Librarian.WarmStore.low_relevance(threshold)
    |> Enum.map(fn memory ->
      Librarian.ColdStore.archive(memory)
      Librarian.WarmStore.forget(memory.id)
      memory.id
    end)
  end

  @doc """
  The "nightly curator" / dream-cycle pass: decay (per-bucket policy
  applies — see `Librarian.WarmStore.decay_all/1`), then archive whatever
  fell below the threshold. Cross-bucket associative links discovered
  during the day (via `maybe_supersede/1`, or `Librarian.recall/1`'s
  synaptic-jump lookups) are already logged to `priv/cold/insights.jsonl`
  as they happen — `nightly_pass` doesn't need to redo that work, just
  the decay/archive housekeeping.
  """
  def nightly_pass(opts \\ []) do
    half_life = Keyword.get(opts, :half_life_seconds, 60 * 60 * 24 * 14)
    threshold = Keyword.get(opts, :archive_threshold, 0.15)

    Librarian.WarmStore.decay_all(half_life)
    archived = archive_stale(threshold)
    %{archived: archived}
  end
end

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
  def flush_bucket(bucket, opts \\ []) do
    case Librarian.HotStore.drain(bucket) do
      [] ->
        :empty

      payloads ->
        require Logger
        user_id = bucket |> String.split(":") |> hd()
        curator_impl = Librarian.Curator.resolve_curator(user_id, opts)

        Logger.debug("[Flusher] Flushing #{length(payloads)} payloads from #{bucket} via #{inspect(curator_impl)}")

        results =
          Enum.map(payloads, fn payload ->
            case Librarian.Curator.summarize([payload], curator_impl) do
              {:ok, result} ->
                result =
                  case Librarian.Curator.embed(result.summary, curator_impl) do
                    {:ok, vec} -> %{result | embedding: vec}
                    {:error, embed_err} ->
                      Logger.warning("[Flusher] Embed failed for bucket=#{bucket}: #{inspect(embed_err)}, storing without embedding")
                      result
                  end

                normalized = Librarian.Router.normalize_bucket(result.bucket || "inbox", user_id)
                warm_bucket = "#{user_id}:#{normalized}"
                memory = Librarian.WarmStore.put(warm_bucket, result, correlation_id: payload.parent_id)
                Logger.debug("[Flusher] Stored memory id=#{memory.id} in #{warm_bucket}")

                # Notify ChunkTracker if this was a chunked payload
                if payload.parent_id do
                  Librarian.ChunkTracker.chunk_flushed(payload.parent_id, memory.id)
                end

                {:ok, memory}

              {:error, reason} ->
                Logger.warning("[Flusher] Summarize failed for bucket=#{bucket}: #{inspect(reason)} — re-queuing payload")
                # Put this payload back so a curator failure loses nothing.
                Librarian.HotStore.put(bucket, payload)
                {:error, reason}
            end
          end)

        succeeded = Enum.filter(results, &match?({:ok, _}, &1))

        # Only truncate WAL if at least one payload was successfully curated.
        # If everything failed the WAL stays intact so payloads survive a restart.
        if succeeded != [] do
          Librarian.Wal.truncate(bucket)
        end

        Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:flushed, bucket})

        case succeeded do
          [] -> {:error, :all_failed}
          ok -> {:ok, Enum.map(ok, fn {:ok, m} -> m end)}
        end
    end
  end

  @doc "Flush every bucket that currently has HOT data."
  def flush_all(max_concurrency \\ 1, opts \\ []) do
    buckets = Librarian.HotStore.buckets()

    if max_concurrency > 1 do
      buckets
      |> Task.async_stream(&flush_bucket(&1, opts), max_concurrency: max_concurrency, timeout: 60_000)
      |> Enum.map(fn {bucket, result} -> {bucket, result} end)
    else
      buckets
      |> Enum.map(fn bucket -> {bucket, flush_bucket(bucket, opts)} end)
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

      # Also log to relationships table for audit trail
      user_id = extract_user_id_from_memory_id(old_id)
      Librarian.ColdStore.log_relationship(
        to_string(old_id),
        to_string(new_id),
        "superseded_by",
        user_id,
        %{}
      )

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

    # Log cross-connections as insights AND relationships
    Enum.each(actions[:cross_connections] || [], fn conn ->
      Librarian.ColdStore.log_insight(%{
        "kind" => "deep_cross_connection",
        "id_a" => conn["id_a"],
        "id_b" => conn["id_b"],
        "note" => conn["note"]
      })

      # Also log to relationships table
      user_id = extract_user_id_from_memory_id(conn["id_a"])
      Librarian.ColdStore.log_relationship(
        conn["id_a"],
        conn["id_b"],
        "cross_connected",
        user_id,
        %{note: conn["note"]}
      )
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

  # Extract user_id from memory - need to look up the memory to find its bucket
  defp extract_user_id_from_memory_id(id) do
    case Librarian.WarmStore.get(id) do
      nil -> "unknown"
      memory -> memory.bucket |> String.split(":") |> hd()
    end
  end
end

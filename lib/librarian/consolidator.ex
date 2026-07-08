defmodule Librarian.Consolidator do
  @moduledoc ~S"""
  Decentralized generational tournament bracket for memory clustering.

  `consolidate/1` fetches all active WARM memories for a user, shuffles them
  to break ingestion bias, chunks them into parallel pools, and runs a swarm
  loop that merges semantically similar memories (cosine similarity > 0.75)
  using element-wise weighted mean embeddings.

  Merged clusters are archived to the SQLite ColdStore and the original
  memories are flagged as superseded in the WarmStore.
  """

  @similarity_threshold 0.75

  @doc ~S"""
  Run a full consolidation pass for a user.

  Broadcasts PubSub events on "consolidation:#{user_id}":
    - `{:spawned, count}` — initial memory count
    - `{:pool_started, pool_id, size}` — each parallel pool
    - `{:merged, from_id, into_id, similarity, preview_a, preview_b}`
    - `{:complete, final_count}` — survivors after all passes
  """
  def consolidate(user_id, opts \\ []) when is_binary(user_id) do
    memories = Librarian.WarmStore.all_for_user(user_id)

    if length(memories) < 2 do
      Phoenix.PubSub.broadcast(
        Librarian.PubSub,
        "consolidation:#{user_id}",
        {:complete, length(memories)}
      )

      :noop
    else
      shuffled = Enum.shuffle(memories)

      Phoenix.PubSub.broadcast(
        Librarian.PubSub,
        "consolidation:#{user_id}",
        {:spawned, length(shuffled)}
      )

      pool_size = min(50, ceil(length(shuffled) / 10))
      pools = Enum.chunk_every(shuffled, pool_size)

      # Round 1: parallel pool swarms — returns [{merged_memory, [original_ids]}]
      round1_clusters =
        pools
        |> Task.async_stream(
          fn pool -> run_pool_swarm(pool) end,
          max_concurrency: length(pools),
          timeout: 30_000
        )
        |> Enum.flat_map(fn
          {:ok, clusters} -> clusters
          _ -> []
        end)

      # Semifinals: flatten to memories for the semi pass, carrying lineage forward
      semi_memories = Enum.map(round1_clusters, fn {mem, _ids} -> mem end)
      round1_lineage = Map.new(round1_clusters, fn {mem, ids} -> {mem.id, ids} end)

      final_clusters_raw = run_pool_swarm(semi_memories)

      # Merge the lineage from both rounds: if a semi-pass keeper absorbed a
      # round-1 cluster, fold that cluster's original_ids into the final lineage.
      final_clusters =
        Enum.map(final_clusters_raw, fn {mem, absorbed_in_semi} ->
          all_originals =
            Enum.flat_map([mem.id | absorbed_in_semi], fn id ->
              # Look up round-1 lineage; fall back to the id itself
              Map.get(round1_lineage, id, [id])
            end)
            |> Enum.uniq()

          {mem, all_originals}
        end)

      # Persist: write new cluster nodes, supersede originals, archive to COLD
      persist_clusters(final_clusters, user_id, opts)

      survivors = Enum.map(final_clusters, fn {mem, _} -> mem end)

      Phoenix.PubSub.broadcast(
        Librarian.PubSub,
        "consolidation:#{user_id}",
        {:complete, length(survivors)}
      )

      {:ok, survivors}
    end
  end

  # ── Pool swarm ─────────────────────────────────────────────────────

  defp run_pool_swarm(memories) when is_list(memories) do
    table_ref = :ets.new(:pool_swarm, [:public, :set])

    # Seed: store {memory.id, {memory, [memory.id]}}
    Enum.each(memories, fn m ->
      :ets.insert(table_ref, {m.id, {m, [m.id]}})
    end)

    IO.inspect(:ets.tab2list(table_ref), label: "[Swarm Init] Current ETS Table State")

    # For each memory still in the table, scan for mergeable neighbors
    Enum.each(memories, fn m ->
      candidates =
        :ets.tab2list(table_ref)
        |> Enum.map(fn {_id, {mem, _ids}} -> mem end)
        |> Enum.reject(fn mem -> mem.id == m.id end)

      Enum.each(candidates, fn neighbor ->
        neighbor_id = neighbor.id

        take_res = :ets.take(table_ref, neighbor_id)
        IO.inspect(take_res, label: "[Atomic Take Result] Key: #{neighbor_id}")

        case take_res do
          [{^neighbor_id, {neighbor_mem, neighbor_lineage}}] ->
            sim = cosine_similarity(m.embedding, neighbor_mem.embedding)

            if sim && sim > @similarity_threshold && can_merge?(m, neighbor_mem) do
              IO.puts("[Match Found] M1: #{m.id} -> M2: #{neighbor_mem.id} | Sim: #{sim}")
              # Look up the current state of the keeper (it may have been updated
              # by a prior merge in this same iteration)
              {current_keeper, current_lineage} =
                case :ets.lookup(table_ref, m.id) do
                  [{_id, val}] -> val
                  # Keeper was itself taken by a concurrent merge — skip
                  [] -> {nil, nil}
                end

              if current_keeper do
                merged = merge_memories(current_keeper, neighbor_mem)
                # Accumulate lineage: both keeper's lineage and neighbor's lineage
                new_lineage = Enum.uniq(current_lineage ++ neighbor_lineage)
                :ets.insert(table_ref, {merged.id, {merged, new_lineage}})

                Phoenix.PubSub.broadcast(
                  Librarian.PubSub,
                  "consolidation:#{user_id_from_bucket(m.bucket)}",
                  {:merged, neighbor_id, m.id, sim,
                   String.slice(m.summary || "", 0, 60),
                   String.slice(neighbor_mem.summary || "", 0, 60)}
                )
              else
                # Keeper gone — return the neighbor to the table unchanged
                :ets.insert(table_ref, {neighbor_id, {neighbor_mem, neighbor_lineage}})
              end
            else
              # Not similar enough / blocked by project tag — put it back
              :ets.insert(table_ref, {neighbor_id, {neighbor_mem, neighbor_lineage}})
            end

          _ ->
            :ok
        end
      end)
    end)

    # Collect survivors as {memory, lineage} pairs
    result = :ets.tab2list(table_ref) |> Enum.map(fn {_id, pair} -> pair end)
    :ets.delete(table_ref)
    result
  end

  # ── Merge logic ────────────────────────────────────────────────────

  defp merge_memories(keeper, absorbed) do
    %{
      keeper
      | summary: (keeper.summary || "") <> " | " <> (absorbed.summary || ""),
        facts: Enum.uniq((keeper.facts || []) ++ (absorbed.facts || [])),
        tags: Enum.uniq((keeper.tags || []) ++ (absorbed.tags || [])),
        embedding:
          weighted_mean_embedding(
            keeper.embedding,
            keeper.importance,
            absorbed.embedding,
            absorbed.importance
          ),
        importance: max(keeper.importance || 0.0, absorbed.importance || 0.0)
    }
  end

  @doc """
  Element-wise weighted mean of two embedding vectors.

  Each component is weighted by the memory's importance score:
    result[i] = (importance_a * vec_a[i] + importance_b * vec_b[i]) / (importance_a + importance_b)
  """
  def weighted_mean_embedding(nil, _imp_a, vec_b, _imp_b) when is_list(vec_b), do: vec_b
  def weighted_mean_embedding(vec_a, _imp_a, nil, _imp_b) when is_list(vec_a), do: vec_a
  def weighted_mean_embedding(nil, _imp_a, nil, _imp_b), do: nil

  def weighted_mean_embedding(vec_a, imp_a, vec_b, imp_b)
      when is_list(vec_a) and is_list(vec_b) do
    total = (imp_a || 0.0) + (imp_b || 0.0)

    if total == 0.0 do
      # Fallback: simple average
      Enum.zip(vec_a, vec_b)
      |> Enum.map(fn {a, b} -> (a + b) / 2.0 end)
    else
      Enum.zip(vec_a, vec_b)
      |> Enum.map(fn {a, b} -> ((imp_a || 0.0) * a + (imp_b || 0.0) * b) / total end)
    end
  end

  # ── Tag boundary check ─────────────────────────────────────────────

  @doc """
  Check if two memories can be merged based on project tag boundaries.

  If both memories have explicit "project-X" tags, they must match.
  If either (or both) lack a project tag, merging is allowed.
  """
  def can_merge?(memory_a, memory_b) do
    project_a = project_tag(memory_a)
    project_b = project_tag(memory_b)

    case {project_a, project_b} do
      {nil, _} -> true
      {_, nil} -> true
      {a, b} -> a == b
    end
  end

  defp project_tag(memory) do
    Enum.find(memory.tags || [], &String.starts_with?(&1, "project-"))
  end

  # ── Persistence ────────────────────────────────────────────────────

  # Persist each surviving cluster:
  #   1. Write a new WarmStore entry (so the merged cluster gets a fresh id)
  #   2. Supersede every original memory that was absorbed into this cluster
  #   3. Archive the saved cluster to long-term SQLite ColdStore
  defp persist_clusters(clusters, user_id, opts) do
    # Tier-aware re-curation: judges (user_id starts with "judge_") get the
    # premium Alibaba Cloud Qwen API; free/anon users get the local model.
    # `force_local` opt lets the dashboard toggle the local model even for judges.
    curator_impl = Librarian.Curator.resolve_curator(user_id, opts)

    Enum.each(clusters, fn {cluster_mem, original_ids} ->
      # Skip clusters that had no merges — the original already lives in WARM
      if length(original_ids) <= 1 do
        :ok
      else
        # 1. Reconstruct clean, uncorrupted individual summaries directly from WARM
        combined_text =
          [cluster_mem.id | original_ids]
          |> Enum.flat_map(fn id ->
            case Librarian.WarmStore.get(id) do
              nil -> []
              m -> [m.summary]
            end
          end)
          |> Enum.uniq()
          |> Enum.join("\n")

        payload = %Librarian.Capture.Payload{
          source: "consolidator",
          raw_text: combined_text
        }

        # 2. Run synthesis through the configured curator engine
        case curator_impl.summarize([payload]) do
          {:ok, curated} ->
            # 3. Assemble a pristine Result struct with correctly isolated bucket context
            curator_result = %Librarian.Curator.Result{
              summary: curated.summary,
              facts: curated.facts,
              tags: curated.tags,
              importance: curated.importance,
              bucket: cluster_mem.bucket |> String.split(":") |> List.last(),
              embedding: nil
            }

            # 4. Atomic storage, cross-linking, and cold-storage archival
            saved = Librarian.WarmStore.put(cluster_mem.bucket, curator_result)

            all_originals = Enum.uniq([cluster_mem.id | original_ids])

            Enum.each(all_originals, fn orig_id ->
              Librarian.WarmStore.supersede(orig_id, saved.id)
            end)

            Librarian.ColdStore.archive(saved, user_id)

          {:error, reason} ->
            require Logger

            Logger.warning(
              "Consolidation re-curation failed via #{inspect(curator_impl)}, skipping cluster. Reason: #{inspect(reason)}"
            )

            :ok
        end
      end
    end)
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp cosine_similarity(nil, _), do: nil
  defp cosine_similarity(_, nil), do: nil

  defp cosine_similarity(a, b) when length(a) == length(b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    norm_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    norm_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))
    dot / (norm_a * norm_b + 1.0e-8)
  end

  defp cosine_similarity(_, _), do: 0.0

  defp user_id_from_bucket(bucket) do
    bucket |> String.split(":") |> hd()
  end
end

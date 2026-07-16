defmodule Librarian.Ancestry do
  @moduledoc """
  Ancestry embeddings + progressive-disclosure recall.

  The Librarian keeps two kinds of content bound together per memory:
    - the **curated summary** (the only thing embedded into the vector
      index, so short/standard captures never pollute the 1024-dim space),
    - the **raw original** (the pre-curation capture / chunk source, linked
      to the row but NOT embedded).

  This module exposes the recall paths that walk the `memory_relationships`
  graph (`derived_from`, `chunk_of`, `merged_into`, `superseded_by`,
  `cross_connected`) and progressively disclose deeper layers once a clean
  summary card is matched:

    - `progressive_recall/3` — query → top summary cards → for each, its
      raw original + its chunk children + parent(s) + cross-bucket links.
    - `get_tree/3` — full recursive ancestry tree for a memory id, enriched
      with summary / raw original / embedding presence.
    - `snippet_search/3` — vector search that surfaces the raw originals
      (specific code blocks, sentences) behind the matched summaries, so a
      single snippet can be retrieved for audit or drill-down.

  Chunked / large docs already embed each chunk's summary (see
  `ParentSummarizer`), so snippet-level retrieval works without embedding
  the entire raw document.
  """

  @default_limit 5
  @default_depth 5

  # ── Progressive disclosure recall ──────────────────────────────────

  @doc """
  Recall memories by query, then attach progressive-disclosure layers for
  each top result: the linked raw original, chunk children (1-hop
  `chunk_of`), parent(s) (`derived_from`), and cross-bucket links
  (`cross_connected` — the edges the Qwen deep pass discovers).

  Returns `%{query: ..., user_id: ..., results: [%{summary_card, raw_original,
  children, parents, cross_links}]}`.
  """
  def progressive_recall(query, user_id \\ "local", opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, @default_limit)

    ranked = Librarian.WarmStore.recall(query, user_id, opts)

    results =
      ranked
      |> Enum.take(limit)
      |> Enum.map(fn mem -> build_layers(mem, user_id) end)

    %{query: query, user_id: user_id, results: results}
  end

  defp build_layers(mem, user_id) do
    %{
      summary_card: serialize_card(mem),
      raw_original: mem.raw_original,
      has_embedding: not is_nil(mem.embedding),
      children: child_chunks(mem.id, user_id),
      parents: parents_of(mem.id, user_id),
      cross_links: cross_links_of(mem.id, user_id)
    }
  end

  # Chunks that point at this memory via `chunk_of` (this memory is the parent).
  defp child_chunks(memory_id, user_id) when is_integer(memory_id) do
    lineage = Librarian.ColdStore.get_memory_lineage(to_string(memory_id), user_id)

    lineage.incoming
    |> Enum.filter(&(&1.type == "chunk_of"))
    |> Enum.map(& &1.source_id)
    |> Enum.map(&resolve_node/1)
    |> Enum.reject(&is_nil/1)
  end

  # Parents this memory was `derived_from`.
  defp parents_of(memory_id, user_id) when is_integer(memory_id) do
    lineage = Librarian.ColdStore.get_memory_lineage(to_string(memory_id), user_id)

    (lineage.outgoing ++ lineage.incoming)
    |> Enum.filter(&(&1.type in ["derived_from", "merged_into", "superseded_by"]))
    |> Enum.map(fn rel ->
      other_id = if rel.source_id == to_string(memory_id), do: rel.target_id, else: rel.source_id
      resolve_node(other_id)
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Cross-bucket links discovered by the Qwen deep pass.
  defp cross_links_of(memory_id, user_id) when is_integer(memory_id) do
    lineage = Librarian.ColdStore.get_memory_lineage(to_string(memory_id), user_id)

    (lineage.outgoing ++ lineage.incoming)
    |> Enum.filter(&(&1.type == "cross_connected"))
    |> Enum.map(fn rel ->
      other_id = if rel.source_id == to_string(memory_id), do: rel.target_id, else: rel.source_id
      node = resolve_node(other_id)
      note = Map.get(rel.metadata || %{}, "note")
      if node, do: Map.put(node, :note, note), else: nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  # ── Full ancestry tree ─────────────────────────────────────────────

  @doc """
  Return the full recursive ancestry tree for a memory id, each node enriched
  with its summary, raw original, and embedding presence.

  Returns a list of `%{depth, source_id, target_id, type, metadata,
  created_at, source, target}` where `source`/`target` are enriched node maps
  (or nil if the node is no longer in WARM).
  """
  def get_tree(memory_id, user_id, depth \\ @default_depth)
      when is_integer(memory_id) and is_binary(user_id) do
    Librarian.ColdStore.get_memory_ancestry(to_string(memory_id), user_id, depth)
    |> Enum.map(fn rel ->
      Map.merge(rel, %{
        source: resolve_node(rel.source_id),
        target: resolve_node(rel.target_id)
      })
    end)
  end

  # ── Snippet / raw-original search ──────────────────────────────────

  @doc """
  Vector search that surfaces the raw originals behind matched summaries.
  Useful when you need a specific code block, sentence, or audit snippet from
  the original capture rather than the curated summary.

  Returns a list of `%{memory_id, summary, raw_original, bucket, distance}`
  ranked by vector similarity.
  """
  def snippet_search(query, user_id \\ "local", limit \\ @default_limit) when is_binary(query) do
    curator_impl = Librarian.Curator.resolve_curator(user_id, [])

    case Librarian.Curator.embed(query, curator_impl) do
      {:ok, embedding} ->
        ranked = Librarian.WarmStore.recall(query, user_id, include_superseded: true)

        ranked
        |> Enum.take(limit * 3)
        |> Enum.map(fn mem ->
          {:ok, vec} = Librarian.Curator.embed(mem.summary || "", curator_impl)
          dist = cosine_distance(embedding, vec)

          %{
            memory_id: mem.id,
            bucket: mem.bucket,
            summary: mem.summary,
            raw_original: mem.raw_original,
            distance: dist
          }
        end)
        |> Enum.sort_by(& &1.distance)
        |> Enum.take(limit)

      {:error, _} ->
        []
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp resolve_node(id_str) when is_binary(id_str) do
    case Integer.parse(id_str) do
      {int_id, ""} -> resolve_node(int_id)
      _ -> nil
    end
  end

  defp resolve_node(int_id) when is_integer(int_id) do
    case Librarian.WarmStore.get(int_id) do
      nil -> nil
      mem -> serialize_card(mem)
    end
  end

  defp serialize_card(mem) do
    %{
      id: mem.id,
      bucket: mem.bucket,
      summary: mem.summary,
      facts: mem.facts || [],
      tags: mem.tags || [],
      importance: mem.importance,
      has_embedding: not is_nil(mem.embedding),
      has_raw_original: not is_nil(mem.raw_original),
      created_at: DateTime.to_iso8601(mem.created_at)
    }
  end

  defp cosine_distance(a, b) when is_list(a) and is_list(b) and length(a) == length(b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    norm_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    norm_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))
    1.0 - dot / (norm_a * norm_b + 1.0e-8)
  end

  defp cosine_distance(_, _), do: 1.0
end

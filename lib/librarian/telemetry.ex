defmodule Librarian.Telemetry do
  @moduledoc """
  Dashboard-facing telemetry that turns the memory pipeline into visible,
  judge-verifiable counters.

  The metrics intentionally derive from existing HOT/WARM/ancestry state:
  raw source text, curated summaries/facts, embeddings, supersession flags,
  and relationship edges. No separate tracking process is required.
  """

  alias Librarian.{HotStore, WarmStore, ColdStore}

  @type snapshot :: %{
          raw_tokens: non_neg_integer(),
          consolidated_tokens: non_neg_integer(),
          tokens_saved: integer(),
          compression_ratio: float(),
          warm_cards: non_neg_integer(),
          hot_payloads: non_neg_integer(),
          lineage_edges: non_neg_integer(),
          lineage_depth: non_neg_integer(),
          lineage_raw_chunks: non_neg_integer(),
          synaptic_similarity: float() | nil,
          synaptic_drift: float() | nil,
          superseded_count: non_neg_integer(),
          grounding_interventions: non_neg_integer()
        }

  @doc "Build a telemetry snapshot for one tenant."
  @spec snapshot(String.t()) :: snapshot()
  def snapshot(user_id) when is_binary(user_id) do
    hot_payloads = HotStore.all_for_user(user_id)
    memories = WarmStore.all() |> Enum.filter(&(Librarian.Bucket.user_of(&1.bucket) == user_id))
    active = Enum.reject(memories, & &1.superseded_by)

    raw_tokens =
      Enum.reduce(hot_payloads, 0, fn {_bucket, payload}, acc ->
        acc + estimate_tokens(payload.raw_text)
      end) + Enum.reduce(memories, 0, fn mem, acc -> acc + estimate_tokens(mem.raw_original) end)

    consolidated_tokens =
      Enum.reduce(active, 0, fn mem, acc ->
        acc + estimate_tokens(mem.summary) + estimate_tokens(Enum.join(mem.facts || [], " "))
      end)

    lineage = lineage_rollup(active, user_id)
    similarity = average_pairwise_similarity(active)

    %{
      raw_tokens: raw_tokens,
      consolidated_tokens: consolidated_tokens,
      tokens_saved: raw_tokens - consolidated_tokens,
      compression_ratio: ratio(raw_tokens, consolidated_tokens),
      warm_cards: length(active),
      hot_payloads: length(hot_payloads),
      lineage_edges: lineage.edges,
      lineage_depth: lineage.depth,
      lineage_raw_chunks: lineage.raw_chunks,
      synaptic_similarity: similarity,
      synaptic_drift: if(is_nil(similarity), do: nil, else: 1.0 - similarity),
      superseded_count: Enum.count(memories, & &1.superseded_by),
      grounding_interventions: grounding_interventions()
    }
  end

  defp estimate_tokens(nil), do: 0

  defp estimate_tokens(text) when is_binary(text) do
    text
    |> String.trim()
    |> case do
      "" -> 0
      trimmed -> max(1, Float.ceil(String.length(trimmed) / 4) |> trunc())
    end
  end

  defp ratio(_raw, 0), do: 0.0
  defp ratio(raw, consolidated), do: raw / consolidated

  defp lineage_rollup([], _user_id), do: %{edges: 0, depth: 0, raw_chunks: 0}

  defp lineage_rollup(memories, user_id) do
    memories
    |> Enum.flat_map(fn mem -> safe_ancestry(mem.id, user_id) end)
    |> then(fn relationships ->
      %{
        edges: length(relationships),
        depth: relationships |> Enum.map(&Map.get(&1, :depth, 0)) |> Enum.max(fn -> 0 end),
        raw_chunks:
          relationships |> Enum.count(&(&1.type in ["chunk_of", "derived_from", "merged_into"]))
      }
    end)
  end

  defp safe_ancestry(id, user_id) do
    ColdStore.get_memory_ancestry(to_string(id), user_id)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp average_pairwise_similarity(memories) do
    vectors = memories |> Enum.map(& &1.embedding) |> Enum.filter(&is_list/1)

    case pairs(vectors) do
      [] -> nil
      pairs -> Enum.sum(Enum.map(pairs, fn {a, b} -> cosine_similarity(a, b) end)) / length(pairs)
    end
  end

  defp pairs([]), do: []
  defp pairs([_]), do: []
  defp pairs([h | t]), do: Enum.map(t, &{h, &1}) ++ pairs(t)

  defp cosine_similarity(a, b) when length(a) == length(b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    norm_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    norm_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))
    dot / (norm_a * norm_b + 1.0e-8)
  end

  defp cosine_similarity(_, _), do: 0.0

  defp grounding_interventions do
    ColdStore.read_insights(500)
    |> Enum.count(fn insight ->
      insight["kind"] in ["grounding_intervention", "fabrication_dropped"]
    end)
  rescue
    _ -> 0
  end
end

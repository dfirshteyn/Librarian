defmodule Librarian.Network do
  @moduledoc """
  Manages the border crossing from private sandboxed text into the public,
  immutable Postgres graph substrate (the "MemWay Superhighway").

  Uses Postgres via `Librarian.PublicRepo` with pgvector for 1024-dim
  cosine similarity search (BGE-M3 embeddings). No HNSW index is
  needed at hackathon scale — exact k-NN via `ORDER BY embedding <=> ?`
  is sub-millisecond for < 10k nodes.

  ## Architecture

  When a memory is finalized and published:
    1. SHA-256 hash of the summary is computed as the immutable node ID
    2. Node is inserted into `public_nodes` with metadata, embedding, and
       the anonymous publisher hash (X-User-Id)
    3. Asynchronously, the 3 nearest existing nodes are found via cosine
       distance and `adjacent_discovery` edges are created

  OSS storage of full raw text can be added later via `oss_url` on the node.
  """

  @similarity_threshold 0.35
  @max_neighbors 3

  @doc """
  Publish a finalized Council deliberation result to the public graph.

  Returns `{:ok, hash_id}` or `{:error, reason}`.

  ## Parameters
    - `artifact`: map with keys:
      - `"summary"` (required) — the Judge's final synthesis
      - `"importance"` (required) — 0.0-1.0
      - `"bucket"` (required) — e.g. "research", "ideas"
      - `"metadata"` (optional map) — tags, facts, persona_perspectives
    - `embedding_vector`: a list of 1024 floats from BGE-M3 (configurable via `:embedding_dimensions`)
    - `publisher_hash`: anonymous X-User-Id hash (optional)
  """
  @spec publish(map(), [float()], String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def publish(artifact, embedding_vector, publisher_hash \\ nil)

  def publish(artifact, embedding_vector, publisher_hash) do
    expected_dims = Application.get_env(:librarian, :embedding_dimensions, 1024)

    cond do
      not is_map(artifact) or is_nil(Map.get(artifact, "summary")) or
          Map.get(artifact, "summary") == "" ->
        {:error, :invalid_artifact, "Missing required key: summary"}

      not is_list(embedding_vector) ->
        {:error, :invalid_embedding, "Embedding vector must be a list"}

      length(embedding_vector) != expected_dims ->
        {:error, :invalid_embedding,
         "Embedding vector must be exactly #{expected_dims} dimensions (got #{length(embedding_vector)})"}

      true ->
        do_actual_publish(artifact, embedding_vector, publisher_hash)
    end
  end

  defp do_actual_publish(%{"summary" => summary} = artifact, embedding_vector, publisher_hash) do
    # 1. Generate deterministic content hash
    hash_id = :crypto.hash(:sha256, summary) |> Base.encode16(case: :lower)

    # 2. Build metadata JSONB payload
    metadata =
      artifact
      |> Map.get("metadata", %{})
      |> Map.merge(%{
        "tags" => Map.get(artifact, "tags", []),
        "facts" => Map.get(artifact, "facts", []),
        "persona_perspectives" => Map.get(artifact, "persona_perspectives", %{})
      })

    importance = artifact["importance"] || 0.5
    bucket = artifact["bucket"] || "inbox"

    # 3. Insert with ON CONFLICT DO NOTHING (idempotent)
    #    The embedding is passed as a raw Elixir list — Postgrex handles
    #    the vector encoding automatically via the registered TypeModule.
    result =
      Ecto.Adapters.SQL.query!(
        Librarian.PublicRepo,
        """
        INSERT INTO public_nodes (id, summary, importance, bucket, metadata, embedding, publisher_hash)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        ON CONFLICT (id) DO NOTHING
        """,
        [
          hash_id,
          summary,
          importance,
          bucket,
          Librarian.Json.encode!(metadata),
          embedding_vector,
          publisher_hash
        ]
      )

    case result do
      %{num_rows: 1} ->
        # 5. Async neighbor linking
        Task.Supervisor.start_child(Librarian.TaskSupervisor, fn ->
          link_adjacent_neighbors(hash_id, embedding_vector)
        end)

        {:ok, hash_id}

      %{num_rows: 0} ->
        # Already published
        {:ok, hash_id}

      _ ->
        {:error, :insert_failed}
    end
  end

  @doc """
  Find the 3 closest existing nodes in the public graph and draw
  `adjacent_discovery` edges if they are semantically close enough.
  """
  def link_adjacent_neighbors(node_hash, embedding_vector) when is_list(embedding_vector) do
    results =
      Ecto.Adapters.SQL.query!(
        Librarian.PublicRepo,
        """
        SELECT id, (embedding <=> $1) AS distance
        FROM public_nodes
        WHERE id != $2
        ORDER BY embedding <=> $1
        LIMIT $3
        """,
        [embedding_vector, node_hash, @max_neighbors]
      )

    case results do
      %{rows: rows} when is_list(rows) ->
        Enum.each(rows, fn [neighbor_hash, distance] when is_number(distance) ->
          if distance < @similarity_threshold do
            weight = Float.round(1.0 - distance, 4)

            Ecto.Adapters.SQL.query!(
              Librarian.PublicRepo,
              """
              INSERT INTO public_edges (source_id, target_id, edge_type, weight)
              VALUES ($1, $2, 'adjacent_discovery', $3)
              ON CONFLICT (source_id, target_id, edge_type) DO NOTHING
              """,
              [node_hash, neighbor_hash, weight]
            )
          end
        end)

      _ ->
        :ok
    end
  end

  @doc """
  Search the public graph by embedding similarity (exact k-NN).

  Returns up to `limit` nodes with their `metadata` decoded and an
  added `distance` field (cosine distance, 0 = identical).
  """
  @spec search_public_graph([float()], integer()) :: [map()]
  def search_public_graph(embedding_vector, limit \\ 10) when is_list(embedding_vector) do
    results =
      Ecto.Adapters.SQL.query!(
        Librarian.PublicRepo,
        """
        SELECT id, summary, importance, bucket, metadata, publisher_hash, oss_url,
               (embedding <=> $1) AS distance,
               inserted_at
        FROM public_nodes
        ORDER BY embedding <=> $1
        LIMIT $2
        """,
        [embedding_vector, limit]
      )

    case results do
      %{rows: rows} when is_list(rows) ->
        Enum.map(rows, fn row ->
          [
            id,
            summary,
            importance,
            bucket,
            metadata_json,
            publisher_hash,
            oss_url,
            distance,
            inserted_at
          ] = row

          %{
            id: id,
            summary: summary,
            importance: importance,
            bucket: bucket,
            metadata: decode_json(metadata_json, %{}),
            publisher_hash: publisher_hash,
            oss_url: oss_url,
            distance: distance,
            inserted_at: inserted_at
          }
        end)

      _ ->
        []
    end
  end

  @doc """
  Get all nodes and edges for the graph visualization.

  Returns `%{nodes: [...], edges: [...]}`.
  """
  @spec get_graph() :: %{nodes: [map()], edges: [map()]}
  def get_graph do
    nodes_result =
      Ecto.Adapters.SQL.query!(
        Librarian.PublicRepo,
        """
        SELECT id, summary, importance, bucket, metadata, publisher_hash,
               inserted_at
        FROM public_nodes
        ORDER BY inserted_at DESC
        LIMIT 200
        """,
        []
      )

    nodes =
      case nodes_result do
        %{rows: rows} when is_list(rows) ->
          Enum.map(rows, fn [
                              id,
                              summary,
                              importance,
                              bucket,
                              metadata_json,
                              publisher_hash,
                              inserted_at
                            ] ->
            %{
              id: id,
              summary: summary,
              importance: importance,
              bucket: bucket,
              metadata: decode_json(metadata_json, %{}),
              publisher_hash: publisher_hash,
              inserted_at: inserted_at
            }
          end)

        _ ->
          []
      end

    node_ids = Enum.map(nodes, & &1.id)

    edges =
      if node_ids != [] do
        placeholders =
          node_ids
          |> Enum.with_index()
          |> Enum.map(fn {_, i} -> "$#{i + 1}" end)
          |> Enum.join(", ")

        query = """
        SELECT id, source_id, target_id, edge_type, weight
        FROM public_edges
        WHERE source_id IN (#{placeholders}) OR target_id IN (#{placeholders})
        ORDER BY weight DESC
        LIMIT 500
        """

        params = node_ids

        edges_result =
          Ecto.Adapters.SQL.query!(Librarian.PublicRepo, query, params)

        case edges_result do
          %{rows: rows} when is_list(rows) ->
            Enum.map(rows, fn [id, source_id, target_id, edge_type, weight] ->
              %{id: id, source: source_id, target: target_id, type: edge_type, weight: weight}
            end)

          _ ->
            []
        end
      else
        []
      end

    %{nodes: nodes, edges: edges}
  end

  defp decode_json(nil, default), do: default

  defp decode_json(json, default) when is_binary(json) do
    case Librarian.Json.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> default
    end
  end
end

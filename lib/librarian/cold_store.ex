defmodule Librarian.ColdStore do
  @moduledoc """
  The COLD tier: per-tenant SQLite databases under `priv/data/<user_id>.db`.

  Each tenant database has a `memories` table with FTS5 full-text search,
  a `memory_fts` virtual table kept in sync by triggers, and optional
  sqlite-vec extension for fast vector similarity search.

  The separate `priv/cold/insights.jsonl` file is still written by
  `log_insight/1` and `read_insights/1` — this is the curator's
  cross-bucket observation log, not memory storage.
  """

  @insights_dir Application.compile_env(:librarian, :cold_dir, "priv/cold")
  require Logger

  # ── insights.jsonl (unchanged) ──────────────────────────────────────

  @doc """
  Append a structured insight (a supersession, a synaptic jump, etc.)
  to `priv/cold/insights.jsonl`. This is separate from memory storage.
  """
  def log_insight(map) when is_map(map) do
    File.mkdir_p!(@insights_dir)
    path = Path.join(@insights_dir, "insights.jsonl")

    line =
      map
      |> Map.put("logged_at", DateTime.to_iso8601(DateTime.utc_now()))
      |> Librarian.Json.encode()

    File.write!(path, line <> "\n", [:append])
    :ok
  end

  @doc "Read the most recent N insights from the JSONL log."
  def read_insights(limit \\ 10) do
    path = Path.join(@insights_dir, "insights.jsonl")

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case Librarian.Json.decode(line) do
          {:ok, map} -> map
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(-limit)
      |> Enum.reverse()
    else
      []
    end
  end

  # ── Memory Relationships (audit trail) ────────────────────────────────

  @doc """
  Log a relationship between two memory IDs.

  Supports: merged_into, superseded_by, cross_connected, derived_from
  Metadata can include similarity scores, notes, or other context.
  """
  def log_relationship(source_id, target_id, relationship_type, user_id, metadata \\ %{})
      when is_binary(source_id) and is_binary(target_id) and is_binary(relationship_type) and
             is_binary(user_id) do
    conn = Librarian.ColdStore.ConnectionManager.get_conn(user_id)

    metadata_json = Librarian.Json.encode!(metadata)

    {:ok, _} =
      Exqlite.query(
        conn,
        "INSERT INTO memory_relationships (source_id, target_id, relationship_type, metadata_json) VALUES (?1, ?2, ?3, ?4)",
        [source_id, target_id, relationship_type, metadata_json]
      )

    :ok
  end

  @doc """
  Get direct lineage for a memory - all relationships where this memory is involved.
  Returns map with :outgoing (source) and :incoming (target) relationships.
  """
  def get_memory_lineage(memory_id, user_id) do
    try do
      conn = Librarian.ColdStore.ConnectionManager.get_conn(user_id)

      # Handle nil connection gracefully (connection failed)
      if is_nil(conn) do
        {:ok, %{outgoing: [], incoming: []}}
      else

        outgoing =
          case Exqlite.query(
                conn,
                "SELECT * FROM memory_relationships WHERE source_id = ?1 ORDER BY created_at DESC",
                [memory_id]
              ) do
            {:ok, %{rows: rows}} -> rows_to_relationships(rows)
            _ -> []
          end

        incoming =
          case Exqlite.query(
                conn,
                "SELECT * FROM memory_relationships WHERE target_id = ?1 ORDER BY created_at DESC",
                [memory_id]
              ) do
            {:ok, %{rows: rows}} -> rows_to_relationships(rows)
            _ -> []
          end

        %{outgoing: outgoing, incoming: incoming}
      end
    rescue
      e ->
        Logger.warning("Lineage lookup failed for memory #{memory_id}: #{inspect(e)}")
        {:ok, %{outgoing: [], incoming: []}}
    end
  end

  @doc """
  Get full ancestry tree for a memory using recursive CTE.
  Returns all ancestors and descendants up to a specified depth.
  """
  def get_memory_ancestry(memory_id, user_id, depth \\ 5) do
    conn = Librarian.ColdStore.ConnectionManager.get_conn(user_id)

    {:ok, result} =
      Exqlite.query(
        conn,
        """
        WITH RECURSIVE ancestry(depth, source_id, target_id, relationship_type, metadata_json, created_at, path) AS (
          -- Seed: direct relationships
          SELECT 1, source_id, target_id, relationship_type, metadata_json, created_at,
                 source_id || '->' || target_id AS path
          FROM memory_relationships
          WHERE source_id = ?1 OR target_id = ?1

          UNION ALL

          -- Recursive: follow the chain
          SELECT a.depth + 1, r.source_id, r.target_id, r.relationship_type, r.metadata_json, r.created_at,
                 a.path || '->' || r.target_id
          FROM memory_relationships r
          JOIN ancestry a ON r.source_id = a.target_id
          WHERE a.depth < ?2
        )
        SELECT * FROM ancestry ORDER BY depth, created_at DESC
        """,
        [memory_id, depth]
      )

    result.rows |> Enum.map(&row_to_ancestry/1)
  end

  defp row_to_relationship(row) do
    [_id, source_id, target_id, relationship_type, metadata_json, created_at] = row

    %{
      source_id: source_id,
      target_id: target_id,
      type: relationship_type,
      metadata: decode_json_map(metadata_json),
      created_at: created_at
    }
  end

  defp row_to_ancestry(row) do
    [depth, source_id, target_id, relationship_type, metadata_json, created_at, _path] = row

    %{
      depth: depth,
      source_id: source_id,
      target_id: target_id,
      type: relationship_type,
      metadata: decode_json_map(metadata_json),
      created_at: created_at
    }
  end

  defp rows_to_relationships(rows) do
    Enum.map(rows, &row_to_relationship/1)
  end

  defp decode_json_map(nil), do: %{}

  defp decode_json_map(json) when is_binary(json) do
    case Librarian.Json.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  # ── Bucket CRUD ────────────────────────────────────────────────────

  @default_buckets ["inbox", "project", "research", "ideas", "thoughts", "finance"]
  @system_buckets ["inbox"]

  @doc """
  List active (non-deleted) buckets for a user.
  Lazily seeds defaults on first access.
  """
  def list_buckets(user_id) when is_binary(user_id) do
    conn = Librarian.ColdStore.ConnectionManager.get_conn(user_id)
    seed_default_buckets(conn)

    {:ok, result} =
      Exqlite.query(
        conn,
        "SELECT name, display_name, created_at FROM buckets WHERE deleted_at IS NULL ORDER BY name",
        []
      )

    result.rows
    |> Enum.map(fn [name, display_name, created_at] ->
      %{name: name, display_name: display_name || name, created_at: created_at}
    end)
  end

  @doc """
  List all buckets including soft-deleted ones.
  """
  def list_buckets(user_id, include_deleted: true) when is_binary(user_id) do
    conn = Librarian.ColdStore.ConnectionManager.get_conn(user_id)
    seed_default_buckets(conn)

    {:ok, result} =
      Exqlite.query(
        conn,
        "SELECT name, display_name, created_at, deleted_at FROM buckets ORDER BY name",
        []
      )

    result.rows
    |> Enum.map(fn [name, display_name, created_at, deleted_at] ->
      %{
        name: name,
        display_name: display_name || name,
        created_at: created_at,
        deleted_at: deleted_at
      }
    end)
  end

  @doc """
  Add a new bucket for a user. Returns `{:ok, bucket_name}` or `{:error, reason}`.
  """
  def add_bucket(user_id, name) when is_binary(user_id) and is_binary(name) do
    conn = Librarian.ColdStore.ConnectionManager.get_conn(user_id)
    seed_default_buckets(conn)

    name = String.trim(String.downcase(name))

    cond do
      name == "" ->
        {:error, :name_empty}

      name in @system_buckets ->
        {:error, :reserved_name}

      true ->
        # Check limit
        max_buckets = Application.get_env(:librarian, :max_buckets_per_user, 30)

        {:ok, %{rows: [[count]]}} =
          Exqlite.query(
            conn,
            "SELECT COUNT(*) FROM buckets WHERE deleted_at IS NULL",
            []
          )

        if count >= max_buckets do
          {:error, {:bucket_limit_reached, max_buckets}}
        else
          case Exqlite.query(
                 conn,
                 "INSERT OR IGNORE INTO buckets (name, display_name) VALUES (?1, ?1)",
                 [name]
               ) do
            {:ok, _} -> {:ok, name}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  @doc """
  Rename a bucket. Returns `{:ok, new_name}` or `{:error, reason}`.
  Preserves relationship graph edges by updating the bucket field on all memories.
  """
  def rename_bucket(user_id, old_name, new_name)
      when is_binary(user_id) and is_binary(old_name) and is_binary(new_name) do
    conn = Librarian.ColdStore.ConnectionManager.get_conn(user_id)
    seed_default_buckets(conn)

    new_name = String.trim(String.downcase(new_name))

    cond do
      old_name in @system_buckets ->
        {:error, :cannot_modify_system_bucket}

      new_name == "" ->
        {:error, :name_empty}

      new_name in @system_buckets ->
        {:error, :reserved_name}

      true ->
        # Check old bucket exists
        {:ok, %{rows: [[count]]}} =
          Exqlite.query(
            conn,
            "SELECT COUNT(*) FROM buckets WHERE name = ?1 AND deleted_at IS NULL",
            [old_name]
          )

        if count == 0 do
          {:error, :not_found}
        else
          # Check new name doesn't already exist
          {:ok, %{rows: [[existing]]}} =
            Exqlite.query(
              conn,
              "SELECT COUNT(*) FROM buckets WHERE name = ?1",
              [new_name]
            )

          if existing > 0 do
            {:error, :already_exists}
          else
            # Step 1: Update COLD memories table
            Exqlite.query(
              conn,
              "UPDATE memories SET bucket = ?1 WHERE bucket = ?2",
              [new_name, old_name]
            )

            # Step 2: Update buckets table
            Exqlite.query(
              conn,
              "UPDATE buckets SET name = ?1, display_name = ?1 WHERE name = ?2",
              [new_name, old_name]
            )

            {:ok, new_name}
          end
        end
    end
  end

  @doc """
  Soft-delete a bucket. Returns `{:ok, name}` or `{:error, reason}`.
  Memories in the bucket are preserved with their bucket field intact.
  Relationship graph edges are NOT severed — archived memories remain queryable.
  """
  def remove_bucket(user_id, name) when is_binary(user_id) and is_binary(name) do
    conn = Librarian.ColdStore.ConnectionManager.get_conn(user_id)
    seed_default_buckets(conn)

    name = String.trim(String.downcase(name))

    cond do
      name in @system_buckets ->
        {:error, :cannot_modify_system_bucket}

      true ->
        {:ok, %{rows: [[count]]}} =
          Exqlite.query(
            conn,
            "SELECT COUNT(*) FROM buckets WHERE name = ?1 AND deleted_at IS NULL",
            [name]
          )

        if count == 0 do
          {:error, :not_found}
        else
          Exqlite.query(
            conn,
            "UPDATE buckets SET deleted_at = datetime('now') WHERE name = ?1",
            [name]
          )

          {:ok, name}
        end
    end
  end

  @doc """
  Check if a bucket name exists and is active for a user.
  """
  def bucket_exists?(user_id, name) when is_binary(user_id) and is_binary(name) do
    conn = Librarian.ColdStore.ConnectionManager.get_conn(user_id)
    seed_default_buckets(conn)

    {:ok, %{rows: [[count]]}} =
      Exqlite.query(
        conn,
        "SELECT COUNT(*) FROM buckets WHERE name = ?1 AND deleted_at IS NULL",
        [name]
      )

    count > 0
  end

  @doc """
  Get all active bucket names for a user. Used by Router.normalize_bucket/2.
  """
  def valid_bucket_names(user_id) when is_binary(user_id) do
    conn = Librarian.ColdStore.ConnectionManager.get_conn(user_id)
    seed_default_buckets(conn)

    {:ok, result} =
      Exqlite.query(
        conn,
        "SELECT name FROM buckets WHERE deleted_at IS NULL",
        []
      )

    result.rows |> Enum.map(fn [name] -> name end)
  end

  defp seed_default_buckets(conn) do
    {:ok, %{rows: [[count]]}} =
      Exqlite.query(conn, "SELECT COUNT(*) FROM buckets", [])

    if count == 0 do
      Enum.each(@default_buckets, fn name ->
        Exqlite.query(
          conn,
          "INSERT OR IGNORE INTO buckets (name, display_name) VALUES (?1, ?1)",
          [name]
        )
      end)
    end

    :ok
  end

  # ── Memory archive (SQLite) ────────────────────────────────────────

  @doc """
  Archive a memory into the tenant's SQLite COLD database.

  The embedding is stored as a float32 little-endian binary blob for
  sqlite-vec compatibility.
  """
  def archive(%Librarian.WarmStore.Memory{} = memory, user_id) when is_binary(user_id) do
    conn = Librarian.ColdStore.ConnectionManager.get_conn(user_id)

    facts_json = Librarian.Json.encode!(memory.facts || [])
    tags_json = Librarian.Json.encode!(memory.tags || [])
    embedding_blob = pack_embedding(memory.embedding)

    now = DateTime.to_iso8601(DateTime.utc_now())

    created_at =
      if memory.created_at, do: DateTime.to_iso8601(memory.created_at), else: now

    {:ok, _} =
      Exqlite.query(
        conn,
        """
        INSERT INTO memories (bucket, summary, facts, tags, importance, embedding, created_at, last_accessed_at, original_content)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
        """,
        [
          memory.bucket,
          memory.summary,
          facts_json,
          tags_json,
          memory.importance || 0.0,
          embedding_blob,
          created_at,
          now,
          memory.raw_original
        ]
      )

    :ok
  end

  # ── FTS5 search ────────────────────────────────────────────────────

  @doc """
  Full-text search across memories using FTS5 BM25 ranking.

  The query is automatically stemmed by the porter tokenizer.
  Returns a list of memory maps with an added `rank` field.
  """
  def search_fts(query, user_id) when is_binary(query) and is_binary(user_id) do
    conn = Librarian.ColdStore.ConnectionManager.get_conn(user_id)

    {:ok, result} =
      Exqlite.query(
        conn,
        """
        SELECT m.id, m.bucket, m.summary, m.facts, m.tags,
               m.importance, m.created_at, m.last_accessed_at, m.superseded_by,
               rank
        FROM memory_fts
        JOIN memories m ON memory_fts.rowid = m.id
        WHERE memory_fts MATCH ?1
        ORDER BY rank
        """,
        [query]
      )

    result.rows |> Enum.map(&row_to_memory/1)
  end

  # ── Vector search ──────────────────────────────────────────────────

  @doc """
  Search memories by vector similarity using cosine distance.

  Tries three strategies in order:
    1. **vec0 virtual table** — fastest, uses sqlite-vec's native index
    2. **vec_distance_cosine** — direct on `memories.embedding` column
    3. **Elixir-side cosine similarity** — fallback when extension not loaded

  Returns up to `limit` results, each with an added `distance` field.
  """
  def search_vector(query_embedding, user_id, limit \\ 5) when is_list(query_embedding) do
    conn = Librarian.ColdStore.ConnectionManager.get_conn(user_id)
    blob = pack_embedding(query_embedding)

    # Strategy 1: vec0 virtual table (fastest, requires extension)
    case try_vec0_search(conn, blob, limit) do
      {:ok, rows} ->
        rows |> Enum.map(&row_to_memory/1)

      {:error, _} ->
        # Strategy 2: vec_distance_cosine on memories table
        case try_vec_distance(conn, blob, limit) do
          {:ok, rows} ->
            rows |> Enum.map(&row_to_memory/1)

          {:error, _} ->
            # Strategy 3: Elixir-side cosine similarity (no extension)
            {:ok, result} =
              Exqlite.query(
                conn,
                """
                SELECT id, bucket, summary, facts, tags, importance,
                       created_at, last_accessed_at, superseded_by, embedding, original_content
                FROM memories
                WHERE embedding IS NOT NULL
                """,
                []
              )

            result.rows
            |> Enum.map(fn row ->
              memory = row_to_memory_full(row)
              distance = cosine_distance(query_embedding, memory.embedding)
              Map.put(memory, :distance, distance)
            end)
            |> Enum.sort_by(fn m -> m.distance end)
            |> Enum.take(limit)
        end
    end
  end

  # ── Hybrid search (RRF fusion) ─────────────────────────────────────

  @doc """
  Hybrid search: runs FTS and vector searches independently, then fuses
  results via Reciprocal Rank Fusion (RRF) with k=60.

  Returns up to `limit` results ranked by combined score.
  """
  def search_hybrid(query, embedding, user_id, limit \\ 5) do
    k = 60

    fts_results = search_fts(query, user_id)
    vec_results = search_vector(embedding, user_id, limit * 3)

    # Build RRF scores
    scores = %{}

    scores =
      fts_results
      |> Enum.with_index(1)
      |> Enum.reduce(scores, fn {m, rank}, acc ->
        Map.put(acc, m.id, %{memory: m, score: 1.0 / (k + rank), sources: [:fts]})
      end)

    scores =
      vec_results
      |> Enum.with_index(1)
      |> Enum.reduce(scores, fn {m, rank}, acc ->
        case Map.get(acc, m.id) do
          nil ->
            Map.put(acc, m.id, %{memory: m, score: 1.0 / (k + rank), sources: [:vector]})

          existing ->
            Map.put(acc, m.id, %{
              existing
              | score: existing.score + 1.0 / (k + rank),
                sources: existing.sources ++ [:vector]
            })
        end
      end)

    scores
    |> Map.values()
    |> Enum.sort_by(fn %{score: s} -> -s end)
    |> Enum.take(limit)
    |> Enum.map(fn %{memory: m} -> m end)
  end

  # ── Admin: cross-tenant query ──────────────────────────────────────

  @doc """
  Admin query across all tenant databases.

  Uses `Task.async_stream` with max_concurrency: 50. Each task opens its
  OWN independent connection to a tenant DB (NOT ATTACH DATABASE) —
  this avoids SQLite's ATTACH concurrency limitations and scales cleanly
  across many tenants.

  Per-tenant hybrid search is run; results are collected and re-ranked
  via RRF in Elixir.
  """
  def admin_query(query, embedding, all_user_ids) when is_list(all_user_ids) do
    k = 60

    tasks =
      Task.async_stream(
        all_user_ids,
        fn user_id ->
          # Open an independent connection for this tenant
          conn = Librarian.ColdStore.ConnectionManager.get_conn(user_id)

          # FTS search
          fts_rows =
            case Exqlite.query(
                   conn,
                   """
                   SELECT m.id, m.bucket, m.summary, m.facts, m.tags,
                          m.importance, m.created_at, m.last_accessed_at, m.superseded_by,
                          rank
                   FROM memory_fts
                   JOIN memories m ON memory_fts.rowid = m.id
                   WHERE memory_fts MATCH ?1
                   ORDER BY rank
                   """,
                   [query]
                 ) do
              {:ok, %{rows: rows}} ->
                rows |> Enum.map(&row_to_memory/1)

              _ ->
                []
            end

          # Vector search
          blob = pack_embedding(embedding)

          vec_rows =
            case try_vec_distance(conn, blob, 20) do
              {:ok, rows} ->
                rows |> Enum.map(&row_to_memory/1)

              {:error, _} ->
                {:ok, result} =
                  Exqlite.query(
                    conn,
                    """
                    SELECT id, bucket, summary, facts, tags, importance,
                           created_at, last_accessed_at, superseded_by, embedding, original_content
                    FROM memories WHERE embedding IS NOT NULL
                    """,
                    []
                  )

                result.rows
                |> Enum.map(fn row ->
                  memory = row_to_memory_full(row)
                  distance = cosine_distance(embedding, memory.embedding)
                  Map.put(memory, :distance, distance)
                end)
                |> Enum.sort_by(fn m -> m.distance end)
                |> Enum.take(20)
            end

          %{fts: fts_rows, vec: vec_rows, user_id: user_id}
        end,
        max_concurrency: 50,
        timeout: 30_000
      )

    # Collect all results
    {per_tenant, _failures} =
      Enum.reduce(tasks, {[], []}, fn
        {:ok, result}, {acc, errs} -> {[result | acc], errs}
        {:exit, reason}, {acc, errs} -> {acc, [{:exit, reason} | errs]}
      end)

    # RRF re-rank across all tenants
    scores = %{}

    scores =
      per_tenant
      |> Enum.flat_map(fn %{fts: fts} -> fts end)
      |> Enum.with_index(1)
      |> Enum.reduce(scores, fn {m, rank}, acc ->
        key = {m.id, m.bucket}
        Map.put(acc, key, %{memory: m, score: 1.0 / (k + rank)})
      end)

    scores =
      per_tenant
      |> Enum.flat_map(fn %{vec: vec} -> vec end)
      |> Enum.with_index(1)
      |> Enum.reduce(scores, fn {m, rank}, acc ->
        key = {m.id, m.bucket}

        case Map.get(acc, key) do
          nil ->
            Map.put(acc, key, %{memory: m, score: 1.0 / (k + rank)})

          existing ->
            Map.put(acc, key, %{existing | score: existing.score + 1.0 / (k + rank)})
        end
      end)

    scores
    |> Map.values()
    |> Enum.sort_by(fn %{score: s} -> -s end)
    |> Enum.map(fn %{memory: m} -> m end)
  end

  # ── Packing / helpers ──────────────────────────────────────────────

  @doc false
  def pack_embedding(nil), do: nil

  def pack_embedding(embedding) when is_list(embedding) do
    for x <- embedding, into: <<>>, do: <<x::float-size(32)-little>>
  end

  @doc false
  def unpack_embedding(nil), do: nil

  def unpack_embedding(blob) when is_binary(blob) do
    for <<x::float-size(32)-little <- blob>>, do: x
  end

  # For rows with rank from FTS
  defp row_to_memory([
         id,
         bucket,
         summary,
         facts_json,
         tags_json,
         importance,
         created_at,
         last_accessed_at,
         superseded_by | rest
       ]) do
    rank = if rest != [], do: List.first(rest), else: nil

    %{
      id: id,
      bucket: bucket,
      summary: summary,
      facts: decode_json_list(facts_json),
      tags: decode_json_list(tags_json),
      importance: importance,
      created_at: created_at,
      last_accessed_at: last_accessed_at,
      superseded_by: superseded_by,
      rank: rank
    }
  end

  # For rows with embedding blob (vector fallback)
  defp row_to_memory_full([
         id,
         bucket,
         summary,
         facts_json,
         tags_json,
         importance,
         created_at,
         last_accessed_at,
         superseded_by,
         embedding_blob,
         original_content
       ]) do
    %{
      id: id,
      bucket: bucket,
      summary: summary,
      facts: decode_json_list(facts_json),
      tags: decode_json_list(tags_json),
      importance: importance,
      created_at: created_at,
      last_accessed_at: last_accessed_at,
      superseded_by: superseded_by,
      embedding: unpack_embedding(embedding_blob),
      original_content: original_content
    }
  end

  defp decode_json_list(nil), do: []

  defp decode_json_list(json) when is_binary(json) do
    case Librarian.Json.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp try_vec0_search(conn, blob, limit) do
    Exqlite.query(
      conn,
      """
      SELECT m.id, m.bucket, m.summary, m.facts, m.tags, m.importance,
             m.created_at, m.last_accessed_at, m.superseded_by,
             v.distance
      FROM vec_memories v
      JOIN memories m ON v.rowid = m.id
      WHERE v.embedding MATCH ?1
        AND k = ?2
      ORDER BY v.distance
      """,
      [blob, limit]
    )
  end

  defp try_vec_distance(conn, blob, limit) do
    Exqlite.query(
      conn,
      """
      SELECT id, bucket, summary, facts, tags, importance,
             created_at, last_accessed_at, superseded_by,
             vec_distance_cosine(embedding, ?1) AS distance
      FROM memories
      WHERE embedding IS NOT NULL
      ORDER BY distance ASC
      LIMIT ?2
      """,
      [blob, limit]
    )
  end

  defp cosine_distance(a, b) when is_list(a) and is_list(b) and length(a) == length(b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    norm_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    norm_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))
    1.0 - dot / (norm_a * norm_b + 1.0e-8)
  end

  defp cosine_distance(_, _), do: 1.0
end

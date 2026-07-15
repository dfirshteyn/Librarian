defmodule LibrarianWeb.ApiController do
  use LibrarianWeb, :controller

  @doc """
  POST /api/ingest
  Body: {"source": "...", "raw_text": "...", "hint_tags": [], "metadata": {}}
  Optional header: X-User-Id (defaults to "local")

  This is the universal capture endpoint. Anything that can make an HTTP
  POST can feed the Librarian — shell scripts, Zapier, n8n, mobile apps,
  other languages. Same payload shape as the WebSocket and iex API.

  Supports:
    - Regular JSON text ingestion
    - File uploads via multipart/form-data (with `file` field)
    - Auto-chunking of large documents
    - File type detection via extension
  """
  def ingest(conn, params) do
    user_id = get_user_id(conn)

    with {:ok, _remaining} <- Librarian.Auth.Manifest.record_request(user_id) do
      # Handle multipart file uploads
      params =
        if conn.private[:phoenix_format] == "multipart" ||
           conn.path_info == ["api", "ingest"] && has_multipart?(conn) do
          extract_file_from_multipart(conn, params)
        else
          params
        end

      case Librarian.IngestRouter.process(params, user_id) do
        {:ok, bucket} ->
          json(conn, %{ok: true, bucket: bucket, user_id: user_id})

        {:ok, bucket, chunk_count} ->
          json(conn, %{
            ok: true,
            bucket: bucket,
            user_id: user_id,
            chunk_count: chunk_count,
            note: "Document auto-chunked into #{chunk_count} pieces"
          })

        {:error, reason} ->
          conn
          |> put_status(422)
          |> json(%{ok: false, error: inspect(reason)})
      end
    else
      {:error, :budget_exhausted} ->
        conn
        |> put_status(429)
        |> json(%{ok: false, error: "daily request budget exhausted", sandbox_id: user_id})
    end
  end

  @doc """
  GET /api/recall?q=query
  Optional header: X-User-Id (defaults to "local")

  Returns warm memories ranked by cosine similarity + importance,
  plus cross-bucket synaptic jumps.
  """
  def recall(conn, %{"q" => query}) do
    user_id = get_user_id(conn)

    with {:ok, _remaining} <- Librarian.Auth.Manifest.record_request(user_id) do
      %{warm: warm, related: related} = Librarian.recall(query, user_id)

      json(conn, %{
        ok: true,
        query: query,
        user_id: user_id,
        warm: Enum.map(warm, &serialize_memory/1),
        related: Enum.map(related, &serialize_memory/1)
      })
    else
      {:error, :budget_exhausted} ->
        conn
        |> put_status(429)
        |> json(%{ok: false, error: "daily request budget exhausted", sandbox_id: user_id})
    end
  end

  def recall(conn, _params) do
    conn |> put_status(400) |> json(%{ok: false, error: "missing query param ?q="})
  end

  @doc """
  GET /api/health/curator
  Sends a minimal test payload through the configured curator backend
  and returns the raw result. Use this to confirm the model is responding
  correctly before trying to flush real data.
  """
  def curator_health(conn, _params) do
    user_id = get_user_id(conn)

    with {:ok, _remaining} <- Librarian.Auth.Manifest.record_request(user_id) do
      curator_impl = Librarian.Curator.resolve_curator(user_id, [])

      test_payload = %Librarian.Capture.Payload{
        source: "health_check",
        raw_text: "The server deployed successfully to production at midnight.",
        occurred_at: DateTime.utc_now(),
        hint_tags: []
      }

      result =
        case Librarian.Curator.summarize([test_payload], curator_impl) do
          {:ok, r} ->
            %{
              ok: true,
              curator: inspect(curator_impl),
              summary: r.summary,
              facts: r.facts,
              tags: r.tags,
              bucket: r.bucket,
              importance: r.importance
            }

          {:error, reason} ->
            %{ok: false, curator: inspect(curator_impl), error: inspect(reason)}
        end

      json(conn, result)
    else
      {:error, :budget_exhausted} ->
        conn
        |> put_status(429)
        |> json(%{ok: false, error: "daily request budget exhausted", sandbox_id: user_id})
    end
  end

  @doc """
  GET /api/status
  Returns HOT and WARM tier counts for the requesting user.
  """
  def status(conn, _params) do
    user_id = get_user_id(conn)

    with {:ok, _remaining} <- Librarian.Auth.Manifest.record_request(user_id) do
      json(conn, Map.put(Librarian.status(user_id), :ok, true))
    else
      {:error, :budget_exhausted} ->
        conn
        |> put_status(429)
        |> json(%{ok: false, error: "daily request budget exhausted", sandbox_id: user_id})
    end
  end

  @doc """
  POST /api/flush
  Optional header: X-User-Id (defaults to "local")
  Optional body: {"bucket": "local:project"} (defaults to all buckets)

  Drains HOT buffers to WARM through the configured curator.
  """
  def flush(conn, params) do
    user_id = get_user_id(conn)

    with {:ok, _remaining} <- Librarian.Auth.Manifest.record_request(user_id) do
      bucket = params["bucket"] || "all"

      results =
        case bucket do
          "all" -> Librarian.Flusher.flush_all()
          b -> [Librarian.Flusher.flush_bucket(b)]
        end

      json(conn, %{ok: true, bucket: bucket, results: inspect(results)})
    else
      {:error, :budget_exhausted} ->
        conn
        |> put_status(429)
        |> json(%{ok: false, error: "daily request budget exhausted", sandbox_id: user_id})
    end
  end

  @doc """
  GET /api/export
  Optional header: X-User-Id (defaults to "local")

  Downloads a JSON backup of all memories for the requesting user.
  Used by the "Export/Download Memory Backup" button on the dashboard.
  """
  def export(conn, _params) do
    user_id = get_user_id(conn)

    with {:ok, _remaining} <- Librarian.Auth.Manifest.record_request(user_id) do
      path = Librarian.ColdStore.ConnectionManager.db_path(user_id)

      if File.exists?(path) do
        memories = export_memories(user_id)

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("content-disposition", "attachment; filename=\"#{user_id}_memories.json\"")
        |> send_resp(200, Jason.encode!(%{user_id: user_id, exported_at: DateTime.to_iso8601(DateTime.utc_now()), memories: memories}))
      else
        conn
        |> put_status(404)
        |> json(%{ok: false, error: "no memories found for this user"})
      end
    else
      {:error, :budget_exhausted} ->
        conn
        |> put_status(429)
        |> json(%{ok: false, error: "daily request budget exhausted", sandbox_id: user_id})
    end
  end

  # sandbox_id is assigned by the Librarian.Auth.Plug running in the :api pipeline.
  # It is either an existing verified token or a freshly generated anonymous one.
  defp get_user_id(conn) do
    conn.assigns[:sandbox_id] || "local"
  end

  defp export_memories(user_id) do
    warm = Librarian.WarmStore.all_for_user(user_id) |> Enum.map(&serialize_memory/1)

    cold =
      try do
        conn = Librarian.ColdStore.ConnectionManager.get_conn(user_id)
        {:ok, result} = Exqlite.query(conn, "SELECT id, bucket, summary, facts, tags, importance, created_at, last_accessed_at FROM memories ORDER BY created_at DESC", [])
        result.rows |> Enum.map(fn [id, bucket, summary, facts, tags, importance, created_at, last_accessed_at] ->
          %{
            id: id,
            bucket: bucket,
            summary: summary,
            facts: facts |> Jason.decode() |> case do {:ok, v} -> v; _ -> [] end,
            tags: tags |> Jason.decode() |> case do {:ok, v} -> v; _ -> [] end,
            importance: importance,
            created_at: created_at,
            last_accessed_at: last_accessed_at
          }
        end)
      rescue
        _ -> []
      end

    %{warm: warm, cold: cold}
  end

  defp serialize_memory(m) do
    %{
      id: m.id,
      bucket: m.bucket,
      summary: m.summary,
      tags: m.tags,
      importance: m.importance,
      facts: m.facts,
      has_embedding: not is_nil(m.embedding),
      created_at: DateTime.to_iso8601(m.created_at)
    }
  end

  @doc """
  GET /api/buckets
  Optional header: X-User-Id (defaults to "local")

  Lists all active buckets for the requesting user with HOT/WARM counts.
  """
  def list_buckets(conn, _params) do
    user_id = get_user_id(conn)

    with {:ok, _remaining} <- Librarian.Auth.Manifest.record_request(user_id) do
      buckets = Librarian.list_buckets(user_id)
      json(conn, %{ok: true, user_id: user_id, buckets: buckets})
    else
      {:error, :budget_exhausted} ->
        conn
        |> put_status(429)
        |> json(%{ok: false, error: "daily request budget exhausted", sandbox_id: user_id})
    end
  end

  @doc """
  POST /api/buckets
  Body: {"name": "new_bucket"}
  Optional header: X-User-Id (defaults to "local")

  Creates a new bucket for the requesting user.
  Returns 422 if name is reserved, empty, or limit reached.
  """
  def create_bucket(conn, %{"name" => name}) do
    user_id = get_user_id(conn)

    with {:ok, _remaining} <- Librarian.Auth.Manifest.record_request(user_id) do
      case Librarian.create_bucket(name, user_id) do
        {:ok, bucket_name} ->
          json(conn, %{ok: true, bucket: bucket_name, user_id: user_id})

        {:error, :reserved_name} ->
          conn
          |> put_status(422)
          |> json(%{ok: false, error: "reserved bucket name", user_id: user_id})

        {:error, :name_empty} ->
          conn
          |> put_status(422)
          |> json(%{ok: false, error: "bucket name cannot be empty", user_id: user_id})

        {:error, {:bucket_limit_reached, limit}} ->
          conn
          |> put_status(422)
          |> json(%{ok: false, error: "bucket limit (#{limit}) reached", user_id: user_id, limit: limit})

        {:error, reason} ->
          conn
          |> put_status(422)
          |> json(%{ok: false, error: inspect(reason), user_id: user_id})
      end
    else
      {:error, :budget_exhausted} ->
        conn
        |> put_status(429)
        |> json(%{ok: false, error: "daily request budget exhausted", sandbox_id: user_id})
    end
  end

  def create_bucket(conn, _params) do
    user_id = get_user_id(conn)
    conn |> put_status(422) |> json(%{ok: false, error: "missing name field", user_id: user_id})
  end

  @doc """
  PUT /api/buckets/:name
  Body: {"new_name": "renamed_bucket"}
  Optional header: X-User-Id (defaults to "local")

  Renames a bucket across all tiers.
  Returns 422 if name is reserved, empty, already exists, or not found.
  """
  def rename_bucket(conn, %{"name" => old_name, "new_name" => new_name}) do
    user_id = get_user_id(conn)

    with {:ok, _remaining} <- Librarian.Auth.Manifest.record_request(user_id) do
      case Librarian.rename_bucket(old_name, new_name, user_id) do
        {:ok, bucket_name} ->
          json(conn, %{ok: true, bucket: bucket_name, user_id: user_id})

        {:error, :cannot_modify_system_bucket} ->
          conn
          |> put_status(422)
          |> json(%{ok: false, error: "cannot modify system bucket", user_id: user_id})

        {:error, :not_found} ->
          conn
          |> put_status(404)
          |> json(%{ok: false, error: "bucket not found", user_id: user_id})

        {:error, :already_exists} ->
          conn
          |> put_status(422)
          |> json(%{ok: false, error: "bucket name already exists", user_id: user_id})

        {:error, reason} ->
          conn
          |> put_status(422)
          |> json(%{ok: false, error: inspect(reason), user_id: user_id})
      end
    else
      {:error, :budget_exhausted} ->
        conn
        |> put_status(429)
        |> json(%{ok: false, error: "daily request budget exhausted", sandbox_id: user_id})
    end
  end

  def rename_bucket(conn, _params) do
    user_id = get_user_id(conn)
    conn |> put_status(422) |> json(%{ok: false, error: "missing name or new_name", user_id: user_id})
  end

  @doc """
  DELETE /api/buckets/:name
  Optional header: X-User-Id (defaults to "local")

  Soft-deletes a bucket. Archives WARM memories to COLD, discards HOT data.
  Returns 422 if name is a system bucket, 404 if not found.
  """
  def delete_bucket(conn, %{"name" => name}) do
    user_id = get_user_id(conn)

    with {:ok, _remaining} <- Librarian.Auth.Manifest.record_request(user_id) do
      case Librarian.delete_bucket(name, user_id) do
        {:ok, archived_count} ->
          json(conn, %{ok: true, bucket: name, user_id: user_id, archived: archived_count})

        {:error, :cannot_modify_system_bucket} ->
          conn
          |> put_status(422)
          |> json(%{ok: false, error: "cannot modify system bucket", user_id: user_id})

        {:error, :not_found} ->
          conn
          |> put_status(404)
          |> json(%{ok: false, error: "bucket not found", user_id: user_id})
      end
    else
      {:error, :budget_exhausted} ->
        conn
        |> put_status(429)
        |> json(%{ok: false, error: "daily request budget exhausted", sandbox_id: user_id})
    end
  end

  def delete_bucket(conn, _params) do
    user_id = get_user_id(conn)
    conn |> put_status(422) |> json(%{ok: false, error: "missing name", user_id: user_id})
  end

  @doc """
  GET /api/network

  Returns the full public graph — nodes and edges — for the dashboard
  visualization. No auth required (public data).
  """
  def public_graph(conn, _params) do
    graph = Librarian.Network.get_graph()
    json(conn, Map.put(graph, :ok, true))
  end

  @doc """
  POST /api/network/publish

  Publish a Council deliberation result to the public graph.
  Body: {"summary": "...", "importance": 0.8, "bucket": "research",
         "facts": [...], "tags": [...], "embedding": [1024 floats...]}

  Requires a valid embedding vector. The publisher's anonymous X-User-Id
  hash is recorded if available.
  """
  def publish_to_network(conn, params) do
    user_id = get_user_id(conn)
    expected_dims = Application.get_env(:librarian, :embedding_dimensions, 1024)

    with {:ok, _remaining} <- Librarian.Auth.Manifest.record_request(user_id) do
      embedding = params["embedding"]

      cond do
        is_nil(embedding) or not is_list(embedding) ->
          conn
          |> put_status(422)
          |> json(%{ok: false, error: "missing or invalid embedding (requires list of #{expected_dims} floats)"})

        length(embedding) != expected_dims ->
          conn
          |> put_status(422)
          |> json(%{ok: false, error: "embedding must be exactly #{expected_dims} floats"})

        is_nil(params["summary"]) ->
          conn
          |> put_status(422)
          |> json(%{ok: false, error: "missing required field: summary"})

        true ->
          artifact = %{
            "summary" => params["summary"],
            "importance" => params["importance"] || 0.5,
            "bucket" => params["bucket"] || "inbox",
            "facts" => params["facts"] || [],
            "tags" => params["tags"] || [],
            "metadata" => params["metadata"] || %{}
          }

          case Librarian.Network.publish(artifact, embedding, user_id) do
            {:ok, hash_id} ->
              json(conn, %{ok: true, hash_id: hash_id})

            {:error, reason} ->
              conn
              |> put_status(422)
              |> json(%{ok: false, error: inspect(reason)})
          end
      end
    else
      {:error, :budget_exhausted} ->
        conn
        |> put_status(429)
        |> json(%{ok: false, error: "daily request budget exhausted", sandbox_id: user_id})
    end
  end

  # Multipart file handling

  defp has_multipart?(conn) do
    # Check content-type header for multipart
    case get_req_header(conn, "content-type") do
      [ct | _] -> String.contains?(ct, "multipart/form-data")
      _ -> false
    end
  end

  defp extract_file_from_multipart(conn, params) do
    # For now, just add the file info to params
    # Full multipart parsing would require Plug.Parsers config
    # This is a simplified version that works with pre-parsed multipart data
    case conn.params["file"] do
      %Plug.Upload{} = upload ->
        file_content = File.read!(upload.path)

        # Add file info to params
        params
        |> Map.put("raw_text", file_content)
        |> Map.put("original_filename", upload.filename)
        |> Map.put("file_type", Librarian.Utils.FileDetector.mime_type(upload.filename))

      _ ->
        params
    end
  after
    # Clean up temp file if we created one
    :ok
  end
end

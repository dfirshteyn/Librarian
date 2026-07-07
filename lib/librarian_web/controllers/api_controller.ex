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
  end

  @doc """
  GET /api/recall?q=query
  Optional header: X-User-Id (defaults to "local")

  Returns warm memories ranked by cosine similarity + importance,
  plus cross-bucket synaptic jumps.
  """
  def recall(conn, %{"q" => query}) do
    user_id = get_user_id(conn)
    %{warm: warm, related: related} = Librarian.recall(query, user_id)

    json(conn, %{
      ok: true,
      query: query,
      user_id: user_id,
      warm: Enum.map(warm, &serialize_memory/1),
      related: Enum.map(related, &serialize_memory/1)
    })
  end

  def recall(conn, _params) do
    conn |> put_status(400) |> json(%{ok: false, error: "missing query param ?q="})
  end

  @doc """
  GET /api/status
  Returns HOT and WARM tier counts for the requesting user.
  """
  def status(conn, _params) do
    user_id = get_user_id(conn)
    json(conn, Map.put(Librarian.status(user_id), :ok, true))
  end

  @doc """
  POST /api/flush
  Optional header: X-User-Id (defaults to "local")
  Optional body: {"bucket": "local:project"} (defaults to all buckets)

  Drains HOT buffers to WARM through the configured curator.
  """
  def flush(conn, params) do
    bucket = params["bucket"] || "all"

    results =
      case bucket do
        "all" -> Librarian.Flusher.flush_all()
        b -> [Librarian.Flusher.flush_bucket(b)]
      end

    json(conn, %{ok: true, bucket: bucket, results: inspect(results)})
  end

  # X-User-Id header for multi-tenant — in production this would be
  # validated against a session token. For the hackathon, trust the header.
  defp get_user_id(conn) do
    case get_req_header(conn, "x-user-id") do
      [id | _] when byte_size(id) > 0 -> id
      _ -> "local"
    end
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

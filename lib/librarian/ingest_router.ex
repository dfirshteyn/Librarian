defmodule Librarian.IngestRouter do
  @moduledoc """
  Pre-processing layer for ingestion that handles multi-type content and auto-chunking.

  Features:
    - File type detection via extension and content analysis
    - Automatic chunking of large text documents
    - Concurrent ingestion of multiple chunks
    - Correlation ID tracking for chunked documents
  """

  alias Librarian.Capture.Payload
  alias Librarian.Utils.Chunker
  alias Librarian.Utils.FileDetector

  @default_large_text_threshold 1500
  @default_chunk_size 350
  @default_chunk_overlap 50

  @doc """
  Process an ingest request with automatic type detection and chunking.

  This is the main entry point that replaces direct calls to `Librarian.ingest/2`.

  Returns:
    - `{:ok, bucket}` - Single document ingested
    - `{:ok, bucket, chunk_count}` - Multiple chunks ingested
    - `{:error, reason}` - Processing failed
  """
  def process(params, user_id \\ "local")

  def process(%{} = params, user_id) do
    with {:ok, payload} <- build_payload(params),
         {:ok, _routed} <- route_payload(payload, user_id) do
      case should_chunk?(payload) do
        false ->
          Librarian.ingest(payload, user_id)

        {:chunk, correlation_id} ->
          ingest_chunks(payload, correlation_id, user_id)
      end
    end
  end

  @doc """
  Process a payload directly (used by internal callers).
  """
  def process_payload(%Payload{} = payload, user_id \\ "local") do
    case should_chunk?(payload) do
      false ->
        Librarian.ingest(payload, user_id)

      {:chunk, correlation_id} ->
        ingest_chunks(payload, correlation_id, user_id)
    end
  end

  # Private functions

  defp build_payload(params) do
    # Detect file type if filename provided
    file_type =
      params["file_type"] ||
      (params["original_filename"] && FileDetector.mime_type(params["original_filename"]))

    # Build payload with enhanced metadata
    payload = %Payload{
      source: params["source"] || "unknown",
      raw_text: params["raw_text"],
      occurred_at: parse_time(params["occurred_at"]) || DateTime.utc_now(),
      hint_tags: params["hint_tags"] || [],
      metadata: Map.put(params["metadata"] || %{}, "upload_source", params["source"]),
      file_type: file_type,
      original_filename: params["original_filename"],
      parent_id: params["parent_id"],
      chunk_index: params["chunk_index"]
    }

    {:ok, payload}
  rescue
    e -> {:error, "Invalid payload: #{inspect(e)}"}
  end

  defp route_payload(payload, _user_id) do
    case FileDetector.detect_content_type(payload) do
      :binary ->
        # Binary content - route to Vision module or log for later processing
        {:error, {:unsupported_type, "binary content detected - use Vision module"}}

      :image ->
        {:error, {:unsupported_type, "image content detected - use Vision module"}}

      :pdf ->
        {:error, {:unsupported_type, "PDF content detected - use text extractor"}}

      :text ->
        {:ok, payload}
    end
  end

  defp should_chunk?(%Payload{raw_text: text, file_type: _file_type}) when is_binary(text) do
    threshold = Application.get_env(:librarian, :ingest, [])
               |> Keyword.get(:large_text_threshold, @default_large_text_threshold)

    cond do
      String.length(text) > threshold ->
        {:chunk, generate_correlation_id()}
      true ->
        false
    end
  end

  defp should_chunk?(_), do: false

  defp ingest_chunks(%Payload{} = payload, correlation_id, user_id) do
    chunk_size = Application.get_env(:librarian, :ingest, [])
                |> Keyword.get(:chunk_size, @default_chunk_size)
    overlap = Application.get_env(:librarian, :ingest, [])
               |> Keyword.get(:chunk_overlap, @default_chunk_overlap)

    # Chunk the text
    chunks = Chunker.split_document(payload.raw_text,
      chunk_size: chunk_size,
      overlap: overlap,
      correlation_id: correlation_id
    )

    # Process chunks concurrently
    results =
      chunks
      |> Task.async_stream(
        fn %{text: chunk_text, metadata: meta} ->
          # Update struct fields directly
          chunk_payload = %Payload{
            payload |
            raw_text: chunk_text,
            parent_id: correlation_id,
            chunk_index: meta.chunk_index
          }
          Librarian.ingest(chunk_payload, user_id)
        end,
        timeout: 30_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.to_list()

    # Check results
    case Enum.any?(results, &match?({:error, _}, &1)) do
      true -> {:error, "Some chunks failed to ingest"}
      false ->
        case List.first(results) do
          {:ok, {:ok, bucket}} -> {:ok, bucket, length(chunks)}
          _ -> {:error, "Unknown chunking result"}
        end
    end
  end

  defp generate_correlation_id do
    "corr_" <> (:erlang.unique_integer([:positive]) |> Integer.to_string(16))
  end

  defp parse_time(nil), do: nil

  defp parse_time(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil
end

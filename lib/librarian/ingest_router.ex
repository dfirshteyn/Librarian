defmodule Librarian.IngestRouter do
  @moduledoc """
  Pre-processing layer for ingestion that handles multi-type content and auto-chunking.

  Extended with multi-media support:
    - Images: validates with ExImageInfo, stores file, calls Qwen-VL for description
    - PDFs: extracts markdown via pdf_oxide, stores file, chunks the extracted text
    - Large text: auto-chunks into overlapping segments
    - Code/text: direct ingest
  """

  alias Librarian.Capture.Payload
  alias Librarian.Utils.Chunker
  alias Librarian.Utils.FileDetector
  alias Librarian.Utils.FileStore
  alias Librarian.Utils.PdfExtractor
  alias Librarian.Router
  alias Librarian.HotStore

  @default_large_text_threshold 1500
  @default_chunk_size 350
  @default_chunk_overlap 50

  @doc """
  Process an ingest request with automatic type detection, chunking, and
  multi-media handling.

  This is the main entry point that replaces direct calls to `Librarian.ingest/2`.

  Returns:
    - `{:ok, bucket}` - Single document ingested
    - `{:ok, bucket, chunk_count}` - Multiple chunks ingested
    - `{:ok, bucket, payload}` - File was stored and extracted text ingested
    - `{:error, reason}` - Processing failed
  """
  def process(params, user_id \\ "local")

  def process(%{} = params, user_id) do
    with {:ok, payload} <- build_payload(params),
         {:ok, routed_payload} <- route_payload(payload, user_id) do
      # After routing, check if we should chunk
      case should_chunk?(routed_payload) do
        false ->
          Librarian.ingest(routed_payload, user_id)

        {:chunk, correlation_id} ->
          ingest_chunks(routed_payload, correlation_id, user_id)
      end
    end
  end

  @doc """
  Process a payload directly (used by internal callers).
  """
  def process_payload(%Payload{} = payload, user_id \\ "local") do
    with {:ok, routed_payload} <- route_payload(payload, user_id) do
      case should_chunk?(routed_payload) do
        false ->
          Librarian.ingest(routed_payload, user_id)

        {:chunk, correlation_id} ->
          ingest_chunks(routed_payload, correlation_id, user_id)
      end
    end
  end

  # Private functions

  defp build_payload(params) do
    # Detect file type if filename provided
    file_type =
      params["file_type"] ||
        (params["original_filename"] && FileDetector.mime_type(params["original_filename"]))

    # Handle file_data (base64-encoded binary from multipart upload)
    # If present, decode it for storage
    original_data =
      cond do
        is_binary(params["file_data"]) ->
          params["file_data"]

        is_binary(params["raw_text"]) && FileDetector.is_base64?(params["raw_text"]) ->
          params["raw_text"]

        true ->
          nil
      end

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
      chunk_index: params["chunk_index"],
      stored_path: params["stored_path"],
      dimensions: params["dimensions"],
      raw_extraction: params["raw_extraction"],
      original_data: original_data
    }

    {:ok, payload}
  rescue
    e -> {:error, "Invalid payload: #{inspect(e)}"}
  end

  defp route_payload(payload, user_id) do
    case FileDetector.detect_content_type(payload) do
      :image ->
        process_image(payload, user_id)

      :pdf ->
        process_pdf(payload, user_id)

      :text ->
        {:ok, payload}

      :binary ->
        {:error, {:unsupported_type, "unknown binary format — supported: images, PDFs, text"}}
    end
  end

  # --- Image processing ---

  defp process_image(%Payload{} = payload, user_id) do
    # 1. Get the image data (from original_data or raw_text)
    image_data = payload.original_data || payload.raw_text

    # 2. Decode base64 if needed
    raw_binary =
      if FileDetector.is_base64?(image_data) do
        Base.decode64!(image_data)
      else
        image_data
      end

    # 3. Validate with ExImageInfo and extract dimensions
    dimensions = extract_image_dimensions(raw_binary)

    # 4. Store the file
    filename = payload.original_filename || "image.png"

    {:ok, stored_path} =
      FileStore.store(
        user_id: user_id,
        filename: filename,
        data: raw_binary
      )

    # 5. Call Qwen-VL for description
    description =
      case Librarian.Curator.describe_image(raw_binary) do
        {:ok, desc} -> desc
        {:error, _reason} -> "[Image description pending]"
      end

    # 6. Build return payload with description as raw_text + file metadata
    return_payload = %Payload{
      payload
      | raw_text: "Image: #{filename}\n\n#{description}",
        raw_extraction: description,
        stored_path: stored_path,
        dimensions: dimensions,
        # Don't keep binary in memory
        original_data: nil
    }

    {:ok, return_payload}
  rescue
    e -> {:error, {:image_processing_error, inspect(e)}}
  end

  # --- PDF processing ---

  defp process_pdf(%Payload{} = payload, user_id) do
    # 1. Get the PDF data
    pdf_data = payload.original_data || payload.raw_text

    # 2. Decode base64 if needed
    raw_binary =
      if FileDetector.is_base64?(pdf_data) do
        Base.decode64!(pdf_data)
      else
        pdf_data
      end

    # 3. Store the file
    filename = payload.original_filename || "document.pdf"

    {:ok, stored_path} =
      FileStore.store(
        user_id: user_id,
        filename: filename,
        data: raw_binary
      )

    # 4. Extract markdown using pdf_oxide with detect_headings
    markdown =
      case PdfExtractor.extract(raw_binary) do
        {:ok, md} -> md
        {:error, _reason} -> "[PDF text extraction failed]"
      end

    # 5. Build return payload with extracted markdown as raw_text + file metadata
    return_payload = %Payload{
      payload
      | raw_text: "Document: #{filename}\n\n#{markdown}",
        raw_extraction: markdown,
        stored_path: stored_path,
        # Don't keep binary in memory
        original_data: nil
    }

    {:ok, return_payload}
  rescue
    e -> {:error, {:pdf_processing_error, inspect(e)}}
  end

  # --- Image dimension extraction ---

  defp extract_image_dimensions(binary_data) when is_binary(binary_data) do
    case ExImageInfo.info(binary_data) do
      {_mime, width, height, _format} when is_integer(width) and is_integer(height) ->
        "#{width}x#{height}"

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp extract_image_dimensions(_), do: nil

  # --- Chunking ---

  defp should_chunk?(%Payload{raw_text: text, file_type: file_type})
       when is_binary(text) do
    threshold =
      Application.get_env(:librarian, :ingest, [])
      |> Keyword.get(:large_text_threshold, @default_large_text_threshold)

    cond do
      # Don't chunk images — their description text is usually short
      is_binary(file_type) and String.starts_with?(file_type, "image/") ->
        false

      String.length(text) > threshold ->
        {:chunk, generate_correlation_id()}

      true ->
        false
    end
  end

  defp should_chunk?(_), do: false

  defp ingest_chunks(%Payload{} = payload, correlation_id, user_id) do
    chunk_size =
      Application.get_env(:librarian, :ingest, [])
      |> Keyword.get(:chunk_size, @default_chunk_size)

    overlap =
      Application.get_env(:librarian, :ingest, [])
      |> Keyword.get(:chunk_overlap, @default_chunk_overlap)

    # Chunk the text
    chunks =
      Chunker.split_document(payload.raw_text,
        chunk_size: chunk_size,
        overlap: overlap,
        correlation_id: correlation_id
      )

    total_chunks = length(chunks)

    # Register with ChunkTracker BEFORE dispatching any concurrent ingestion
    :ok = Librarian.ChunkTracker.register_chunks(correlation_id, total_chunks, user_id)

    # Process chunks concurrently using deterministic storage.
    # Chunks are uniquely identified by their source path + index, not raw_text.
    # This avoids the overlap-duplicate bug where chunk N's tail matches chunk N+1's head.
    results =
      chunks
      |> Task.async_stream(
        fn %{text: chunk_text, metadata: meta} ->
          # Strip the "Document: filename\n\n" prefix from chunk text so
          # each chunk only contains the actual extracted content.
          clean_text =
            chunk_text
            |> String.replace(~r/^Document:\s+[^\n]+\n\n/, "", global: false)

          chunk_payload = %Payload{
            payload
            | raw_text: clean_text,
              parent_id: correlation_id,
              chunk_index: meta.chunk_index,
              # Carry forward file metadata so the flusher can store it
              # on each chunk's WARM memory for the ancestry modal
              stored_path: payload.stored_path,
              file_type: payload.file_type,
              dimensions: payload.dimensions
          }

          # Use deterministic storage - skip text dedup, chunks are unique by source+index
          {bucket, _tags} = Router.route(chunk_payload, user_id)

          case HotStore.put_deterministic(bucket, chunk_payload) do
            {:ok, :stored} ->
              Phoenix.PubSub.broadcast(
                Librarian.PubSub,
                "ingest",
                {:ingested, bucket, chunk_payload.source, String.slice(clean_text, 0, 80), user_id}
              )

              {:ok, bucket}

            _ ->
              {:ok, {:error, "Deterministic put failed"}}
          end
        end,
        timeout: 30_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.to_list()

    # With deterministic storage, all chunks are stored (no duplicates possible).
    # The count we registered is accurate.
    # Check results for errors
    case Enum.any?(results, &match?({:ok, {:error, _}}, &1)) or
           Enum.any?(results, &match?({:error, _}, &1)) do
      true ->
        {:error, "Some chunks failed to ingest"}

      false ->
        {:ok, "#{user_id}:inbox", total_chunks}
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

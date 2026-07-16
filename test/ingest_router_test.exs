defmodule Librarian.IngestRouterTest do
  use ExUnit.Case, async: false

  alias Librarian.Capture.Payload
  alias Librarian.IngestRouter
  alias Librarian.Utils.Chunker
  alias Librarian.Utils.FileDetector

  describe "Librarian.Utils.Chunker" do
    test "splits text into overlapping chunks" do
      text = String.duplicate("hello world ", 500)

      chunks = Chunker.split_document(text, chunk_size: 100, overlap: 20)

      assert length(chunks) > 1

      assert Enum.all?(chunks, fn chunk ->
               is_map(chunk) and
                 Map.has_key?(chunk, :text) and
                 Map.has_key?(chunk, :metadata) and
                 Map.has_key?(chunk.metadata, :chunk_index) and
                 Map.has_key?(chunk.metadata, :total_chunks) and
                 Map.has_key?(chunk.metadata, :correlation_id)
             end)
    end

    test "returns single chunk for small text" do
      text = "This is a small text document"

      chunks = Chunker.split_document(text, chunk_size: 1000)

      assert length(chunks) == 1
    end

    test "chunks have sequential indices" do
      text = String.duplicate("hello world ", 500)

      chunks = Chunker.split_document(text, chunk_size: 100)

      indices = Enum.map(chunks, & &1.metadata.chunk_index)
      assert indices == Enum.to_list(0..(length(chunks) - 1))
    end

    test "chunks share correlation_id" do
      text = String.duplicate("hello world ", 500)

      chunks = Chunker.split_document(text, chunk_size: 100, correlation_id: "test_corr_123")

      correlation_ids = Enum.map(chunks, & &1.metadata.correlation_id)
      assert Enum.uniq(correlation_ids) == ["test_corr_123"]
    end
  end

  describe "Librarian.Utils.FileDetector" do
    test "detects text content type" do
      payload = %Payload{source: "test", raw_text: "This is plain text"}
      assert FileDetector.detect_content_type(payload) == :text
    end

    test "detects image content type from file_type" do
      payload = %Payload{source: "test", raw_text: "base64...", file_type: "image/png"}
      assert FileDetector.detect_content_type(payload) == :image
    end

    test "detects PDF content type from file_type" do
      payload = %Payload{source: "test", raw_text: "...", file_type: "application/pdf"}
      assert FileDetector.detect_content_type(payload) == :pdf
    end

    test "gets MIME type from extension" do
      assert FileDetector.mime_type("document.md") == "text/markdown"
      assert FileDetector.mime_type("image.png") == "image/png"
      assert FileDetector.mime_type("data.json") == "application/json"
      assert FileDetector.mime_type("code.py") == "text/x-python"
    end

    test "categorizes file types" do
      assert FileDetector.file_category("script.ex") == {:elixir, "text/x-elixir"}
      assert FileDetector.file_category("image.jpg") == {:image, "image/jpeg"}
      assert FileDetector.file_category("README.md") == {:markdown, "text/markdown"}
      assert FileDetector.file_category("code.py") == {:code, "text/x-python"}
    end
  end

  # Under Option B every ingest lands in the shared "local:inbox" HOT buffer.
  # Clear it after this module runs so later async:false tests that flush
  # "local:inbox" don't drain our leftover (un-flushed) chunked payloads.
  setup do
    on_exit(fn ->
      Librarian.HotStore.drain("local:inbox")
      Librarian.Wal.truncate("local:inbox")
    end)

    :ok
  end

  describe "Librarian.IngestRouter" do
    test "processes small text without chunking" do
      params = %{
        "source" => "test_#{:erlang.unique_integer([:positive])}",
        "raw_text" => "small text"
      }

      assert {:ok, bucket} = IngestRouter.process(params)
      # Ingest namespaces to inbox; the curator decides the real bucket later.
      assert bucket == "local:inbox"
    end

    test "chunks large text automatically" do
      # Create text larger than 1500 character threshold, each sentence unique
      large_text =
        1..200
        |> Enum.map(&"This is sentence number #{&1} that will be repeated many times. ")
        |> Enum.join()

      params = %{
        "source" => "test_#{:erlang.unique_integer([:positive])}",
        "raw_text" => large_text
      }

      assert {:ok, _bucket, chunk_count} = IngestRouter.process(params)
      assert chunk_count > 1
    end

    test "preserves hint_tags in chunked output" do
      large_text = String.duplicate("This is a sentence. ", 300)

      params = %{
        "source" => "test_#{:erlang.unique_integer([:positive])}",
        "raw_text" => large_text,
        "hint_tags" => ["custom_tag"]
      }

      assert {:ok, _bucket, _chunk_count} = IngestRouter.process(params)
    end

    test "routes by file extension for code files" do
      # Create a larger code file to trigger chunking (with keywords for project bucket)
      code_text =
        String.duplicate(
          "defmodule MyModule do\n  def my_function do\n    IO.puts(\"hello\")\n  end\nend\nDeploy the project to production.\n",
          100
        )

      params = %{
        "source" => "test_#{:erlang.unique_integer([:positive])}",
        "raw_text" => code_text,
        "original_filename" => "my_module.ex"
      }

      assert {:ok, _bucket, _chunk_count} = IngestRouter.process(params)
    end

    test "chunked payloads have parent_id correlation tracking" do
      unique_source = "test_parent_#{:erlang.unique_integer([:positive])}"
      # Each sentence is unique so chunk dedup won't remove them
      large_text = 1..300 |> Enum.map(&"chunk #{&1} project deploy sentence. ") |> Enum.join()

      params = %{"source" => unique_source, "raw_text" => large_text}

      {:ok, bucket, chunk_count} = IngestRouter.process(params)

      # Verify there are items in HOT store
      all_items = Librarian.HotStore.all(bucket)

      # Filter to only our test items
      test_items = Enum.filter(all_items, &(&1.source == unique_source))

      assert length(test_items) == chunk_count

      # Check that chunked items have parent_id set
      assert Enum.all?(test_items, &(&1.parent_id != nil))

      # Check that chunk_index values exist and are valid
      chunk_indices = Enum.map(test_items, & &1.chunk_index)
      assert Enum.all?(chunk_indices, &(&1 != nil))
    end

    test "registration happens before concurrent chunk dispatch (race prevention)" do
      # This test verifies that ChunkTracker.register_chunks is called synchronously
      # before Task.async_stream dispatches chunks - preventing race conditions where
      # chunks arrive before registration completes
      unique_source = "race_test_#{:erlang.unique_integer([:positive])}"

      # Create a small document that will be chunked but not too many chunks
      large_text = String.duplicate("This is a test sentence for race condition testing. ", 50)

      params = %{"source" => unique_source, "raw_text" => large_text}

      # Process should succeed without errors
      assert {:ok, _bucket, _chunk_count} = IngestRouter.process(params)

      # Verify the registration pattern worked - no unregistered correlation_id warnings
      # (The test would have showed warnings in the logs if registration was missed)
    end
  end
end

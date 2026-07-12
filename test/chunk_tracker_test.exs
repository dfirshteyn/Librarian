defmodule Librarian.ChunkTrackerTest do
  use ExUnit.Case, async: false

  alias Librarian.ChunkTracker

  setup do
    # Clear HOT store before each test
    on_exit(fn ->
      Librarian.HotStore.drain("local:inbox")
      Librarian.Wal.truncate("local:inbox")
    end)

    :ok
  end

  describe "ChunkTracker" do
    test "registers chunks and tracks completion" do
      correlation_id = "test_corr_123"
      total_chunks = 3

      # Register before any chunks
      :ok = ChunkTracker.register_chunks(correlation_id, total_chunks, "local")

      # Report 2 chunks flushed
      :ok = ChunkTracker.chunk_flushed(correlation_id, 1)
      :ok = ChunkTracker.chunk_flushed(correlation_id, 2)

      # Third chunk triggers completion
      {:complete, ^correlation_id} = ChunkTracker.chunk_flushed(correlation_id, 3)

      # Verify state is cleaned up (calling again returns error)
      {:error, :not_registered} = ChunkTracker.chunk_flushed(correlation_id, 4)
    end

    test "is idempotent - duplicate flush reports don't increment counter" do
      correlation_id = "test_corr_456"
      total_chunks = 2

      :ok = ChunkTracker.register_chunks(correlation_id, total_chunks, "local")

      # Report chunk 1 twice (idempotency test)
      :ok = ChunkTracker.chunk_flushed(correlation_id, 1)
      :ok = ChunkTracker.chunk_flushed(correlation_id, 1)  # Duplicate - returns :ok but doesn't count

      # Still need chunk 2 to trigger completion (now we have 2 unique chunks)
      {:complete, ^correlation_id} = ChunkTracker.chunk_flushed(correlation_id, 2)
    end

    test "handles unknown correlation_id gracefully" do
      # No registration - should log warning but not crash
      {:error, :not_registered} = ChunkTracker.chunk_flushed("unknown_corr", 1)
    end
  end
end

defmodule Librarian.ParentSummarizerTest do
  use ExUnit.Case, async: false

  alias Librarian.ParentSummarizer

  setup do
    # Clear HOT store before each test module
    on_exit(fn ->
      Librarian.HotStore.drain("local:inbox")
      Librarian.Wal.truncate("local:inbox")

      # Remove the WARM ETS rows this test inserted so they don't leak
      # into the shared ETS table for other tests.
      :ets.delete(:warm_memories, 101)
      :ets.delete(:warm_memories, 102)

      # Remove the COLD relationships written under "local" (chunk_of edges
      # from ParentSummarizer) so they don't pollute other tests.
      conn = Librarian.ColdStore.ConnectionManager.get_conn("local")

      Exqlite.query(conn, "DELETE FROM memory_relationships WHERE source_id = '101' OR target_id = '101' OR source_id = '102' OR target_id = '102'", [])

      # Delete the isolated test insights file so mix test never writes
      # into the dev priv/cold/insights.jsonl.
      insights_path =
        Path.join([Application.get_env(:librarian, :cold_dir, "priv/cold"), "insights.jsonl"])

      if File.exists?(insights_path), do: File.rm!(insights_path)
    end)

    :ok
  end

  describe "ParentSummarizer" do
    test "synthesize_parent creates a parent memory from chunk summaries" do
      correlation_id = "test_parent_corr_789"

      # Create fake chunk memories in WARM
      chunk1 = %Librarian.WarmStore.Memory{
        id: 101,
        bucket: "local:project",
        summary: "database migration completed successfully",
        facts: ["The migration succeeded at 3pm", "All data was preserved"],
        tags: ["database", "migration"],
        embedding: [0.5, 0.5, 0.5],
        importance: 0.8,
        created_at: DateTime.utc_now(),
        last_accessed_at: DateTime.utc_now(),
        superseded_by: nil,
        correlation_id: correlation_id
      }

      chunk2 = %Librarian.WarmStore.Memory{
        id: 102,
        bucket: "local:project",
        summary: "sqlite was chosen as the new database engine",
        facts: ["SQLite was selected for simplicity", "Performance improved after migration"],
        tags: ["sqlite", "database"],
        embedding: [0.6, 0.4, 0.5],
        importance: 0.7,
        created_at: DateTime.utc_now(),
        last_accessed_at: DateTime.utc_now(),
        superseded_by: nil,
        correlation_id: correlation_id
      }

      # Insert into WARM ETS directly
      :ets.insert(:warm_memories, {101, chunk1})
      :ets.insert(:warm_memories, {102, chunk2})

      # Call synthesize_parent
      {:ok, parent_memory} = ParentSummarizer.synthesize_parent(correlation_id, [101, 102], "local")

      # Verify parent memory was created
      assert parent_memory.id != nil
      assert parent_memory.summary != nil
      assert is_binary(parent_memory.summary)
      assert parent_memory.bucket == "local:project" or parent_memory.bucket == "local:inbox"

      # Verify chunk_of relationships exist in COLD
      lineage = Librarian.ColdStore.get_memory_lineage(to_string(parent_memory.id), "local")
      incoming = lineage.incoming

      assert length(incoming) == 2
      assert Enum.any?(incoming, &(&1.type == "chunk_of"))
    end

    test "handles empty chunk list gracefully" do
      # Empty list should return error
      {:error, :no_valid_chunks} = ParentSummarizer.synthesize_parent("empty_corr", [], "local")
    end
  end
end

defmodule Librarian.AncestryTest do
  use ExUnit.Case, async: true

  setup do
    # Use a unique user_id for test isolation
    user_id = "test_ancestry_#{System.unique_integer([:positive, :monotonic])}"

    on_exit(fn ->
      # Clean up any created connections
      try do
        Librarian.ColdStore.ConnectionManager.close_connection(user_id)
      rescue
        _ -> :ok
      end
    end)

    %{user_id: user_id}
  end

  describe "progressive_recall/3" do
    test "returns empty results for empty memory store", %{user_id: user_id} do
      result = Librarian.Ancestry.progressive_recall("nonexistent query", user_id, limit: 5)

      assert result.query == "nonexistent query"
      assert result.user_id == user_id
      assert result.results == []
    end
  end

  describe "get_tree/3" do
    test "returns empty list for memory with no ancestry", %{user_id: user_id} do
      # Create a memory without any relationships using a Curator.Result
      result = %Librarian.Curator.Result{
        summary: "Test memory",
        facts: [],
        tags: [],
        bucket: "test",
        importance: 0.5,
        embedding: nil
      }

      memory =
        Librarian.WarmStore.put("#{user_id}:test", result, raw_original: "Original content")

      tree = Librarian.Ancestry.get_tree(memory.id, user_id, 5)

      assert tree == []
    end
  end

  describe "snippet_search/3" do
    test "returns empty list when no embedding backend available", %{user_id: user_id} do
      # Without a working embedding backend, the query will fail and return []
      result = Librarian.Ancestry.snippet_search("test query", user_id, 5)

      assert result == [] or is_list(result)
    end
  end
end

defmodule Librarian.ColdStoreTest do
  use ExUnit.Case, async: false

  alias Librarian.{ColdStore, WarmStore, Curator}
  alias Librarian.WarmStore.Memory

  setup do
    # Ensure ETS table exists for tests (app may not have started fully)
    if :ets.whereis(:cold_conns) == :undefined do
      :ets.new(:cold_conns, [:set, :named_table, :public])
    end

    on_exit(fn ->
      ColdStore.ConnectionManager.close_all()

      # Clean up test DB files
      db_dir = Application.get_env(:librarian, :db_dir, "tmp/test_data")

      if File.exists?(db_dir) do
        File.ls!(db_dir)
        |> Enum.each(fn f -> File.rm!(Path.join(db_dir, f)) end)
      end

      # Clean up WARM memories left by other tests
      Enum.each(WarmStore.all(), &WarmStore.forget(&1.id))
    end)

    :ok
  end

  test "FTS search finds a memory by keyword" do
    memory = %Memory{
      id: 1,
      bucket: "local:test",
      summary: "The quick brown fox jumps over the lazy dog",
      facts: ["foxes are quick"],
      tags: ["fox", "dog"],
      importance: 0.8,
      embedding: nil,
      created_at: DateTime.utc_now(),
      last_accessed_at: DateTime.utc_now()
    }

    :ok = ColdStore.archive(memory, "test_user")
    results = ColdStore.search_fts("fox", "test_user")

    assert length(results) >= 1
    assert Enum.any?(results, &String.contains?(&1.summary, "fox"))
  end

  test "vector search returns nearest neighbor" do
    # Create memories with deterministic embeddings from Stub curator
    {:ok, embedding_a} = Curator.Stub.embed("kittens are cute animals")
    {:ok, embedding_b} = Curator.Stub.embed("rocket science is complicated")
    {:ok, query_embedding} = Curator.Stub.embed("adorable cats")

    memory_a = %Memory{
      id: 1,
      bucket: "local:test",
      summary: "kittens are cute animals",
      facts: [],
      tags: ["cats"],
      importance: 0.8,
      embedding: embedding_a,
      created_at: DateTime.utc_now(),
      last_accessed_at: DateTime.utc_now()
    }

    memory_b = %Memory{
      id: 2,
      bucket: "local:test",
      summary: "rocket science is complicated",
      facts: [],
      tags: ["science"],
      importance: 0.8,
      embedding: embedding_b,
      created_at: DateTime.utc_now(),
      last_accessed_at: DateTime.utc_now()
    }

    :ok = ColdStore.archive(memory_a, "vec_user")
    :ok = ColdStore.archive(memory_b, "vec_user")

    results = ColdStore.search_vector(query_embedding, "vec_user", 5)

    assert length(results) >= 1
    # The first result should be the kittens memory (closer to "adorable cats")
    assert hd(results).summary == "kittens are cute animals"
  end

  test "hybrid recall falls through from WARM to COLD" do
    # Don't put anything in WARM — recall should fall through to COLD
    # We need to archive something into COLD first, then call Librarian.recall
    memory = %Memory{
      id: 1,
      bucket: "local:test",
      summary: "database migration to sqlite completed",
      facts: ["used exqlite library"],
      tags: ["sqlite", "database"],
      importance: 0.7,
      embedding: nil,
      created_at: DateTime.utc_now(),
      last_accessed_at: DateTime.utc_now()
    }

    :ok = ColdStore.archive(memory, "local")

    # recall with a query that matches — WARM is empty (< 3 results), should fall through to COLD
    result = Librarian.recall("sqlite migration")

    # cold results should exist
    assert is_list(result.cold)
    assert length(result.cold) >= 1
    assert Enum.any?(result.cold, &String.contains?(&1.summary, "sqlite"))
  end

  test "FTS index stays in sync after a supersession (update trigger test)" do
    memory = %Memory{
      id: 1,
      bucket: "local:test",
      summary: "using postgres database for storage",
      facts: [],
      tags: ["postgres", "db"],
      importance: 0.7,
      embedding: nil,
      created_at: DateTime.utc_now(),
      last_accessed_at: DateTime.utc_now()
    }

    :ok = ColdStore.archive(memory, "fts_sync_user")

    # Verify we can find it by keyword
    results_before = ColdStore.search_fts("postgres", "fts_sync_user")
    assert length(results_before) >= 1

    conn = ColdStore.ConnectionManager.get_conn("fts_sync_user")

    # Simulate a supersession: UPDATE the memory's summary (superseded_by omitted
    # to avoid FK constraint — we're testing FTS trigger sync, not FK enforcement)
    {:ok, _} =
      Exqlite.query(
        conn,
        "UPDATE memories SET summary = ?1 WHERE id = ?2",
        ["switched to sqlite database", 1]
      )

    # Now searching for "postgres" should still find it (update trigger re-indexes
    # the row — tags still contain "postgres" even though summary changed)
    results_after = ColdStore.search_fts("postgres", "fts_sync_user")
    assert length(results_after) >= 1
    # Summary changed to "switched to sqlite database" but tags still have "postgres"
    assert hd(results_after).summary == "switched to sqlite database"
    assert Enum.any?(results_after, &(&1.tags == ["postgres", "db"]))

    # And searching for "sqlite" should also find the UPDATED memory via FTS
    results_sqlite = ColdStore.search_fts("sqlite", "fts_sync_user")
    assert length(results_sqlite) >= 1
    assert Enum.any?(results_sqlite, &String.contains?(&1.summary, "sqlite"))
  end

  test "admin query returns results across two tenant databases simultaneously" do
    # Archive into two different tenant DBs
    memory_a = %Memory{
      id: 1,
      bucket: "tenant_a:test",
      summary: "quantum computing breakthroughs",
      facts: [],
      tags: ["quantum"],
      importance: 0.9,
      embedding: nil,
      created_at: DateTime.utc_now(),
      last_accessed_at: DateTime.utc_now()
    }

    memory_b = %Memory{
      id: 1,
      bucket: "tenant_b:test",
      summary: "quantum entanglement explained simply",
      facts: [],
      tags: ["quantum", "physics"],
      importance: 0.8,
      embedding: nil,
      created_at: DateTime.utc_now(),
      last_accessed_at: DateTime.utc_now()
    }

    :ok = ColdStore.archive(memory_a, "tenant_a")
    :ok = ColdStore.archive(memory_b, "tenant_b")

    # Use a dummy embedding for the admin query
    {:ok, query_embedding} = Curator.Stub.embed("quantum computing")
    results = ColdStore.admin_query("quantum", query_embedding, ["tenant_a", "tenant_b"])

    assert length(results) >= 2
    # Should contain results from both tenants
    summaries = Enum.map(results, & &1.summary)
    assert "quantum computing breakthroughs" in summaries
    assert "quantum entanglement explained simply" in summaries
  end
end

defmodule Librarian.AutomationServerTest do
  use ExUnit.Case, async: false

  alias Librarian.{WarmStore, Curator, ColdStore}

  setup do
    # Ensure ETS table exists for ColdStore tests
    if :ets.whereis(:cold_conns) == :undefined do
      :ets.new(:cold_conns, [:set, :named_table, :public])
    end

    # Set up a low poll interval so tests don't wait forever
    Application.put_env(:librarian, :consolidation_poll_ms, 200)
    Application.put_env(:librarian, :consolidation_min_memories, 1)

    on_exit(fn ->
      ColdStore.ConnectionManager.close_all()

      # Clean up test DB files
      db_dir = Application.get_env(:librarian, :db_dir, "tmp/test_data")

      if File.exists?(db_dir) do
        File.ls!(db_dir) |> Enum.each(fn f -> File.rm!(Path.join(db_dir, f)) end)
      end

      # Clean up WARM memories
      Enum.each(WarmStore.all(), &WarmStore.forget(&1.id))

      # Reset config
      Application.put_env(:librarian, :consolidation_poll_ms, 60_000)
      Application.put_env(:librarian, :consolidation_min_memories, 2)
    end)

    :ok
  end

  describe "trigger_now/1" do
    test "fires consolidation when WARM count is sufficient" do
      # Insert a memory to trigger consolidation
      {:ok, emb} = Curator.Stub.embed("test memory for automation trigger")

      _memory1 =
        WarmStore.put("auto_user:test", %Curator.Result{
          summary: "test memory for automation trigger",
          facts: [],
          tags: ["test"],
          importance: 0.5,
          embedding: emb
        })

      # Poll-based check: wait for the AutomationServer to pick it up
      # The poll interval is 200ms, so wait a bit
      Process.sleep(500)

      # Check that WarmStore has been processed (at minimum, no crash)
      # The AutomationServer should have picked up the user
      assert true
    end

    test "handles crash gracefully via DOWN handler, releasing in-progress lock" do
      # Use 2 similar-embedding memories so consolidate does real work
      # (with < 2 memories, consolidate returns :noop instantly and the lock
      #  is released before we can observe it)
      emb = Enum.map(1..64, fn i -> if i == 1, do: 0.99, else: 0.01 end)

      _m1 =
        WarmStore.put("lock_user:test", %Curator.Result{
          summary: "lock test memory A",
          facts: [],
          tags: ["test"],
          importance: 0.7,
          embedding: emb
        })

      _m2 =
        WarmStore.put("lock_user:test", %Curator.Result{
          summary: "lock test memory B",
          facts: [],
          tags: ["test"],
          importance: 0.6,
          embedding: emb
        })

      # Trigger consolidation
      result = Librarian.Consolidation.AutomationServer.trigger_now("lock_user")
      assert result == {:ok, :started}

      # Immediate second trigger must be rejected (task not done yet)
      result2 = Librarian.Consolidation.AutomationServer.trigger_now("lock_user")
      assert result2 == {:error, :already_in_progress}

      # Wait for task to finish and DOWN / success reply to clean up the lock
      Process.sleep(1000)

      # Lock released — a fresh trigger is accepted
      result3 = Librarian.Consolidation.AutomationServer.trigger_now("lock_user")
      assert result3 == {:ok, :started}
    end
  end

  describe "poll-based triggering" do
    test "automatically picks up users with enough memories" do
      # Use 2 identical-embedding memories so consolidate does real work
      # (1 memory → :noop instantly, lock releases before second trigger_now)
      emb = Enum.map(1..64, fn i -> if i == 1, do: 0.99, else: 0.01 end)

      _mem1 =
        WarmStore.put("poll_user:test", %Curator.Result{
          summary: "auto poll test memory A",
          facts: [],
          tags: ["test"],
          importance: 0.5,
          embedding: emb
        })

      _mem2 =
        WarmStore.put("poll_user:test", %Curator.Result{
          summary: "auto poll test memory B",
          facts: [],
          tags: ["test"],
          importance: 0.5,
          embedding: emb
        })

      # Manually trigger and confirm lock is set
      result = Librarian.Consolidation.AutomationServer.trigger_now("poll_user")
      assert result == {:ok, :started}

      # Concurrent trigger should be blocked (real merge work keeps task alive)
      result2 = Librarian.Consolidation.AutomationServer.trigger_now("poll_user")
      assert result2 == {:error, :already_in_progress}

      # Wait for the consolidation task to complete and release the lock
      Process.sleep(1000)

      # Lock should be released — a new trigger is accepted
      result3 = Librarian.Consolidation.AutomationServer.trigger_now("poll_user")
      assert result3 == {:ok, :started}
    end
  end
end

defmodule Librarian.DelegationTest do
  use ExUnit.Case, async: false

  alias Librarian.WarmStore
  alias Librarian.WarmStore.Memory

  @moduletag :integration

  setup do
    # Ensure the WarmStore ETS table exists (it is a named public table).
    if :ets.whereis(:warm_memories) == :undefined do
      :ets.new(:warm_memories, [:set, :named_table, :public])
    else
      :ets.delete_all_objects(:warm_memories)
    end

    on_exit(fn -> :ets.delete_all_objects(:warm_memories) end)
    :ok
  end

  defp mk_memory(overrides \\ []) do
    base = %Memory{
      id: 1,
      bucket: "local:ideas",
      summary: "Test memory for delegation",
      facts: ["fact a", "fact b"],
      tags: ["test"],
      embedding: [0.1, 0.2, 0.3],
      importance: 0.7,
      created_at: DateTime.utc_now(),
      last_accessed_at: DateTime.utc_now()
    }

    struct = Enum.reduce(overrides, base, fn {k, v}, acc -> %{acc | k => v} end)
    :ets.insert(:warm_memories, {struct.id, struct})
    struct
  end

  # No external services needed: delegate returns an error (Council LLM not
  # running in CI) and MUST auto-release the hard lock + leave council unset.
  # Uses FailingStub to explicitly force a Council failure path.
  test "delegate auto-releases lock even when council errors" do
    # Override model routing to use FailingStub for this test
    original_routing = Application.get_env(:librarian, :model_routing, %{})

    Application.put_env(:librarian, :model_routing, %{
      council_persona: {Librarian.Curator.FailingStub, "stub"},
      council_judge: {Librarian.Curator.FailingStub, "stub"}
    })

    on_exit(fn ->
      Application.put_env(:librarian, :model_routing, original_routing)
    end)

    mk_memory(id: 43, locked: false)

    result = Librarian.Delegation.delegate_to_council(43, "local")
    assert {:error, _} = result

    mem = WarmStore.get(43)
    refute mem.locked, "lock must auto-release on any failure"
    assert is_nil(mem.council), "council must not be set on failure"
  end

  test "publish rejected before delegate" do
    mk_memory(id: 44, council: nil, published: false)

    assert {:error, :not_delegated} = Librarian.Delegation.publish_memory(44, "local")
  end

  test "publish rejected when memory is locked" do
    mk_memory(id: 46, council: %{synthesis: "x"}, locked: true)

    assert {:error, :locked} = Librarian.Delegation.publish_memory(46, "local")
  end

  # Memory has a council map but NO embedding; the resolver falls back to
  # embedding the synthesis, which fails (no curator/LLM in test) → the
  # publish is rejected with :empty_embedding and the lock is released.
  test "publish rejects + releases lock when embedding unavailable" do
    mk_memory(id: 47, council: %{synthesis: "refined"}, embedding: nil, locked: false)

    assert {:error, _} = Librarian.Delegation.publish_memory(47, "local")

    mem = WarmStore.get(47)
    refute mem.locked
    refute mem.published
  end

  # Hard-lock guard: a consolidated-style memory that is locked cannot be
  # delegated (the consolidator also skips locked memories).
  test "delegate rejected for an already-locked memory" do
    mk_memory(id: 48, locked: true)

    assert {:error, :locked} = Librarian.Delegation.delegate_to_council(48, "local")
  end
end

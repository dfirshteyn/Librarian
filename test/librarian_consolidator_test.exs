defmodule Librarian.ConsolidatorTest do
  use ExUnit.Case, async: false

  alias Librarian.{Consolidator, WarmStore, ColdStore}
  alias Librarian.Curator.Result
  alias Librarian.WarmStore.Memory

  setup do
    # Ensure ETS table exists for ColdStore tests
    if :ets.whereis(:cold_conns) == :undefined do
      :ets.new(:cold_conns, [:set, :named_table, :public])
    end

    on_exit(fn ->
      ColdStore.ConnectionManager.close_all()

      # Clean up test DB files
      db_dir = Application.get_env(:librarian, :db_dir, "tmp/test_data")

      if File.exists?(db_dir) do
        File.ls!(db_dir) |> Enum.each(fn f -> File.rm!(Path.join(db_dir, f)) end)
      end

      # Clean up WARM memories
      Enum.each(WarmStore.all(), &WarmStore.forget(&1.id))
    end)

    :ok
  end

  describe "can_merge?/2" do
    test "blocks cross-project merge" do
      a = %Memory{id: 1, bucket: "u:test", tags: ["project-alpha", "bug"]}
      b = %Memory{id: 2, bucket: "u:test", tags: ["project-beta", "bug"]}
      refute Consolidator.can_merge?(a, b)
    end

    test "allows same-project merge" do
      a = %Memory{id: 1, bucket: "u:test", tags: ["project-alpha", "bug"]}
      b = %Memory{id: 2, bucket: "u:test", tags: ["project-alpha", "feature"]}
      assert Consolidator.can_merge?(a, b)
    end

    test "allows when one has no project tag" do
      a = %Memory{id: 1, bucket: "u:test", tags: ["project-alpha", "bug"]}
      b = %Memory{id: 2, bucket: "u:test", tags: ["bug"]}
      assert Consolidator.can_merge?(a, b)
    end

    test "allows when neither has a project tag" do
      a = %Memory{id: 1, bucket: "u:test", tags: ["bug"]}
      b = %Memory{id: 2, bucket: "u:test", tags: ["feature"]}
      assert Consolidator.can_merge?(a, b)
    end
  end

  describe "weighted_mean_embedding/4" do
    test "produces correct element-wise output" do
      a = [1.0, 2.0, 3.0]
      b = [2.0, 3.0, 4.0]
      result = Consolidator.weighted_mean_embedding(a, 0.8, b, 0.2)

      expected = [
        (0.8 * 1.0 + 0.2 * 2.0) / 1.0,
        (0.8 * 2.0 + 0.2 * 3.0) / 1.0,
        (0.8 * 3.0 + 0.2 * 4.0) / 1.0
      ]

      assert result == expected
    end

    test "returns vec_b when vec_a is nil" do
      assert Consolidator.weighted_mean_embedding(nil, 0.5, [1.0, 2.0], 0.5) == [1.0, 2.0]
    end

    test "returns vec_a when vec_b is nil" do
      assert Consolidator.weighted_mean_embedding([1.0, 2.0], 0.5, nil, 0.5) == [1.0, 2.0]
    end

    test "uses simple average when total importance is zero" do
      result = Consolidator.weighted_mean_embedding([1.0, 2.0], 0.0, [3.0, 4.0], 0.0)
      assert result == [2.0, 3.0]
    end
  end

  # Build a deterministic unit vector with a controlled "hot" dimension
  defp unit_vec(hot_idx, dim \\ 64) do
    base = List.duplicate(0.1 / (dim - 1), dim)
    vec = List.replace_at(base, hot_idx, 0.9)
    norm = :math.sqrt(Enum.reduce(vec, 0.0, fn x, acc -> acc + x * x end))
    Enum.map(vec, &(&1 / norm))
  end

  describe "consolidate/1" do
    test "emits correct PubSub event sequence" do
      # Subscribe to consolidation events for test user
      Phoenix.PubSub.subscribe(Librarian.PubSub, "consolidation:test_cons")

      # Near-identical unit vectors (cosine similarity ~0.999)
      emb = unit_vec(0)
      emb2 = unit_vec(0)

      _memory1 =
        WarmStore.put("test_cons:project", %Result{
          summary: "database migration to sqlite completed successfully",
          facts: [],
          tags: ["sqlite"],
          importance: 0.7,
          embedding: emb
        })

      _memory2 =
        WarmStore.put("test_cons:project", %Result{
          summary: "database migration to sqlite was successful today",
          facts: [],
          tags: ["sqlite"],
          importance: 0.8,
          embedding: emb2
        })

      {:ok, survivors} = Consolidator.consolidate("test_cons")

      # Should have received :spawned and :complete
      assert_received {:spawned, 2}
      assert_received {:complete, _final_count}

      # Should have at least 1 survivor (merged or not)
      assert length(survivors) >= 1
    end

    test "merges similar memories" do
      # Use explicit near-identical unit vectors to guarantee cosine sim > 0.75
      # (same hot dimension 5 → cosine similarity ~1.0)
      emb = unit_vec(5)
      emb2 = unit_vec(5)

      _memory1 =
        WarmStore.put("test_merge:project", %Result{
          summary: "stripe webhook payment processing failure issue",
          facts: ["payment failed"],
          tags: ["stripe"],
          importance: 0.7,
          embedding: emb
        })

      _memory2 =
        WarmStore.put("test_merge:project", %Result{
          summary: "stripe webhook payment failed to process correctly",
          facts: ["webhook error"],
          tags: ["stripe"],
          importance: 0.8,
          embedding: emb2
        })

      {:ok, survivors} = Consolidator.consolidate("test_merge")

      # With cosine sim ~1.0 they must merge into exactly 1 survivor
      assert length(survivors) < 2
    end

    test "returns :noop when fewer than 2 memories" do
      assert Consolidator.consolidate("empty_user") == :noop
    end
  end
end

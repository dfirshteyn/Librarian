defmodule Librarian.LlamaPoolTest do
  use ExUnit.Case, async: true

  setup do
    # Start a fresh pool for each test with a unique name
    pool_name = Module.concat(__MODULE__, :"Pool_#{:erlang.unique_integer([:positive])}")
    {:ok, _pid} = GenServer.start_link(Librarian.LlamaPool, :ok, name: pool_name)
    %{pool: pool_name}
  end

  describe "checkout/checkin basic" do
    test "checkout returns :ok when slots are available", %{pool: pool} do
      assert :ok = Librarian.LlamaPool.checkout("http://localhost:1234/v1", pool)
      assert :ok = Librarian.LlamaPool.checkin("http://localhost:1234/v1", pool)
    end

    test "multiple checkouts on the same URL are allowed up to max concurrency", %{pool: pool} do
      url = "http://localhost:9999/v1"

      # With default max 4, 4 checkouts should all succeed
      for _i <- 1..4 do
        assert :ok = Librarian.LlamaPool.checkout(url, pool)
      end

      # All 4 returned, now check them in
      for _i <- 1..4 do
        assert :ok = Librarian.LlamaPool.checkin(url, pool)
      end
    end

    test "different URLs have independent pools", %{pool: pool} do
      url_a = "http://localhost:9001/v1"
      url_b = "http://localhost:9002/v1"

      # Use all slots on URL A
      for _i <- 1..4 do
        assert :ok = Librarian.LlamaPool.checkout(url_a, pool)
      end

      # URL B should still be fully available
      assert :ok = Librarian.LlamaPool.checkout(url_b, pool)

      # Cleanup
      for _i <- 1..4 do
        Librarian.LlamaPool.checkin(url_a, pool)
      end

      Librarian.LlamaPool.checkin(url_b, pool)
    end
  end

  describe "status" do
    test "status shows pre-configured URLs initially", %{pool: pool} do
      status = Librarian.LlamaPool.status(pool)
      assert is_map(status)
      # The configured URLs from config should appear
      assert %{available: 4, waiting: 0} = Map.get(status, "http://localhost:1234/v1")
      assert %{available: 2, waiting: 0} = Map.get(status, "http://localhost:1235/v1")
      assert %{available: 4, waiting: 0} = Map.get(status, "http://localhost:1236/v1")
    end

    test "status shows checkouts for dynamically-created URLs", %{pool: pool} do
      url = "http://localhost:5001/v1"

      # Unconfigured URL doesn't appear in status until first checkout
      status_before = Librarian.LlamaPool.status(pool)
      refute Map.has_key?(status_before, url)

      # After checkout, it should appear with reduced availability
      assert :ok = Librarian.LlamaPool.checkout(url, pool)
      status = Librarian.LlamaPool.status(pool)
      assert %{available: 3, waiting: 0} = Map.get(status, url)

      # After checkin, back to full
      Librarian.LlamaPool.checkin(url, pool)
      status = Librarian.LlamaPool.status(pool)
      assert %{available: 4, waiting: 0} = Map.get(status, url)
    end
  end

  describe "concurrency limiting" do
    test "checkout blocks when all slots are taken, and unblocks when a slot is freed", %{
      pool: pool
    } do
      url = "http://localhost:6000/v1"

      # Take all 4 slots
      for _i <- 1..4 do
        assert :ok = Librarian.LlamaPool.checkout(url, pool)
      end

      # Spawn a task that tries to checkout (will block)
      waiter =
        Task.async(fn ->
          # This should block until a slot is freed
          Librarian.LlamaPool.checkout(url, pool)
          :got_slot
        end)

      # Give the task time to start and block
      Process.sleep(50)

      # The task should still be running (blocked on checkout)
      refute Task.yield(waiter, 10) == {:ok, :got_slot}

      # Free one slot
      Librarian.LlamaPool.checkin(url, pool)

      # Now the waiter should get the slot
      assert {:ok, :got_slot} = Task.yield(waiter, 1000)

      # Cleanup: release remaining checkouts
      for _i <- 1..3 do
        Librarian.LlamaPool.checkin(url, pool)
      end
    end

    test "checkout respects order (FIFO)", %{pool: pool} do
      url = "http://localhost:6001/v1"

      # Take all 4 slots
      for _i <- 1..4 do
        assert :ok = Librarian.LlamaPool.checkout(url, pool)
      end

      # Spawn two waiters that record their order
      waiter1 =
        Task.async(fn ->
          Librarian.LlamaPool.checkout(url, pool)
          :first
        end)

      waiter2 =
        Task.async(fn ->
          Librarian.LlamaPool.checkout(url, pool)
          :second
        end)

      # Give tasks time to start and block on checkout
      Process.sleep(200)

      # Verify both are blocked by checking status
      status = Librarian.LlamaPool.status(pool)
      assert %{waiting: 2} = Map.get(status, url)

      # Free one slot — waiter1 should get it
      Librarian.LlamaPool.checkin(url, pool)
      assert {:ok, :first} = Task.yield(waiter1, 1000)

      # Free another slot — waiter2 should get it
      Librarian.LlamaPool.checkin(url, pool)
      assert {:ok, :second} = Task.yield(waiter2, 1000)

      # Cleanup: release remaining checkouts
      for _i <- 1..3 do
        Librarian.LlamaPool.checkin(url, pool)
      end
    end
  end
end

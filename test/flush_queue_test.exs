defmodule Librarian.FlushQueueTest do
  use ExUnit.Case, async: false

  alias Librarian.FlushQueue
  alias Librarian.TenantConfig

  setup do
    # Start fresh tenant DB for test user
    user_id = "test_user_#{:erlang.unique_integer([:positive])}"
    Librarian.ColdStore.ConnectionManager.get_conn(user_id)

    on_exit(fn ->
      Librarian.ColdStore.ConnectionManager.close_connection(user_id)
    end)

    %{user_id: user_id}
  end

  describe "enabled?/1" do
    test "returns true by default", %{user_id: user_id} do
      assert FlushQueue.enabled?(user_id) == true
    end

    test "returns false after being disabled", %{user_id: user_id} do
      FlushQueue.set_enabled(user_id, false)
      assert FlushQueue.enabled?(user_id) == false

      FlushQueue.set_enabled(user_id, true)
      assert FlushQueue.enabled?(user_id) == true
    end
  end

  describe "payload_added/2" do
    test "clears timer when auto-flush disabled", %{user_id: user_id} do
      # Disable auto-flush
      FlushQueue.set_enabled(user_id, false)

      # Add payload - should not trigger flush
      assert :ok = FlushQueue.payload_added(user_id, "#{user_id}:inbox")
    end
  end

  describe "TenantConfig" do
    test "get/set for auto_flush_enabled", %{user_id: user_id} do
      # Should default to true
      assert TenantConfig.get(user_id, :auto_flush_enabled) == true

      # Set to false
      TenantConfig.set(user_id, :auto_flush_enabled, false)
      assert TenantConfig.get(user_id, :auto_flush_enabled) == false

      # Set back to true
      TenantConfig.set(user_id, :auto_flush_enabled, true)
      assert TenantConfig.get(user_id, :auto_flush_enabled) == true
    end

    test "get/set for flush_threshold", %{user_id: user_id} do
      # Default threshold
      assert TenantConfig.flush_threshold(user_id) == 5

      # Set custom threshold
      TenantConfig.set(user_id, :flush_threshold, 10)
      assert TenantConfig.flush_threshold(user_id) == 10
    end

    test "get/set for flush_timeout_sec", %{user_id: user_id} do
      # Default timeout
      assert TenantConfig.flush_timeout_sec(user_id) == 30

      # Set custom timeout
      TenantConfig.set(user_id, :flush_timeout_sec, 60)
      assert TenantConfig.flush_timeout_sec(user_id) == 60
    end
  end
end

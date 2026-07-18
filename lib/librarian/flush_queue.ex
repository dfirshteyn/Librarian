defmodule Librarian.FlushQueue do
  @moduledoc """
  Auto-flush queue: watches HOT bucket counts per user and triggers flush
  when threshold reached or timeout elapsed.

  Uses TenantConfig for per-user settings (enabled, threshold, timeout).
  Broadcasts flush progress events incrementally as payloads complete.
  """

  use GenServer

  alias Librarian.{HotStore, Flusher, TenantConfig}

  # Default threshold and timeout (used if not configured per-user)
  # Default threshold and timeout are handled by TenantConfig

  # ── Public API ───────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Check if auto-flush is enabled for a user."
  def enabled?(user_id) when is_binary(user_id) do
    TenantConfig.auto_flush_enabled?(user_id)
  end

  @doc "Set auto-flush enabled/disabled for a user."
  def set_enabled(user_id, enabled) when is_binary(user_id) and is_boolean(enabled) do
    TenantConfig.set(user_id, :auto_flush_enabled, enabled)
    GenServer.cast(__MODULE__, {:user_updated, user_id})
  end

  @doc "Record that a payload was added to HOT for auto-flush tracking."
  def payload_added(user_id, bucket) when is_binary(user_id) and is_binary(bucket) do
    GenServer.cast(__MODULE__, {:payload_added, user_id, bucket})
  end

  # ── GenServer Callbacks ──────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{timers: %{}, last_counts: %{}}}
  end

  @impl true
  def handle_cast({:payload_added, user_id, _bucket}, state) do
    # Check if user has auto-flush disabled
    if not enabled?(user_id) do
      # Clean up any existing timer
      state = cancel_timer_for(state, user_id)
      {:noreply, state}
    else
      # Get current HOT count for user across all buckets
      total_hot = hot_count_for_user(user_id)

      # If no items, just acknowledge and return
      if total_hot == 0 do
        {:noreply, state}
      else
        threshold = TenantConfig.flush_threshold(user_id)
        timeout_sec = TenantConfig.flush_timeout_sec(user_id)

        # Update last activity
        last_counts = Map.put(state.last_counts, user_id, total_hot)

        cond do
          total_hot >= threshold ->
            # Threshold reached - trigger immediate flush
            Task.Supervisor.async_nolink(Librarian.TaskSupervisor, fn ->
              flush_user_buckets(user_id)
            end)

            {:noreply, %{state | last_counts: last_counts} |> cancel_timer_for(user_id)}

          true ->
            # Check if we need to start a timeout timer
            case Map.get(state.timers, user_id) do
              nil ->
                # Start timer for time-based flush
                timer_ref =
                  Process.send_after(self(), {:timeout_flush, user_id}, timeout_sec * 1000)

                {:noreply,
                 %{
                   state
                   | timers: Map.put(state.timers, user_id, timer_ref),
                     last_counts: last_counts
                 }}

              _timer_ref ->
                # Timer already running, just update counts
                {:noreply, %{state | last_counts: last_counts}}
            end
        end
      end
    end
  end

  @impl true
  def handle_cast({:user_updated, user_id}, state) do
    # Reset timer and counts when user toggles settings
    state = cancel_timer_for(state, user_id) |> reset_counts(user_id)
    {:noreply, state}
  end

  @impl true
  def handle_info({:timeout_flush, user_id}, state) do
    # Check if user still has items and auto-flush is still enabled
    if enabled?(user_id) and hot_count_for_user(user_id) > 0 do
      Task.Supervisor.async_nolink(Librarian.TaskSupervisor, fn ->
        flush_user_buckets(user_id)
      end)
    end

    {:noreply, cancel_timer_for(state, user_id)}
  end

  # Catch-all for any unexpected messages
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ────────────────────────────────────────────────────────────

  defp hot_count_for_user(user_id) do
    prefix = user_id <> ":"

    HotStore.buckets()
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.reduce(0, fn bucket, acc -> acc + HotStore.count(bucket) end)
  end

  defp cancel_timer_for(state, user_id) do
    case Map.get(state.timers, user_id) do
      nil -> state
      timer_ref -> Process.cancel_timer(timer_ref)
    end
    |> then(fn s -> %{s | timers: Map.delete(s.timers, user_id)} end)
  end

  defp reset_counts(state, user_id) do
    %{state | last_counts: Map.delete(state.last_counts, user_id)}
  end

  defp flush_user_buckets(user_id) do
    # Flush all buckets for this user - progress broadcast happens via FlushProgressAgent
    Flusher.flush_all(user_id, 1,
      progress_callback: &Librarian.FlushProgressAgent.report_progress/4
    )
  end
end

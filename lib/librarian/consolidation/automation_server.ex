defmodule Librarian.Consolidation.AutomationServer do
  @moduledoc """
  GenServer that periodically polls the WarmStore and triggers consolidation
  for tenants with enough active memories.

  Tracks in-progress consolidations in a MapSet to prevent concurrent runs
  on the same tenant. Uses `Task.Supervisor.async_nolink/3` for safe,
  monitored task execution — the built-in monitor ref is used to clean up
  the in-progress lock on both success and crash.
  """

  use GenServer

  # Configurable via application env for testing
  @default_poll_ms 60_000
  @default_min_memories 2
  # 24 hours
  @default_sweep_ms 86_400_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_poll()
    schedule_daily_sweep()
    {:ok, %{in_progress: MapSet.new(), monitors: %{}, enabled: true}}
  end

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Enable or disable auto-consolidation.
  """
  def set_enabled(enabled) when is_boolean(enabled) do
    GenServer.call(__MODULE__, {:set_enabled, enabled})
  end

  @doc """
  Check if auto-consolidation is enabled.
  """
  def enabled? do
    GenServer.call(__MODULE__, :enabled?)
  end

  @doc """
  Trigger an immediate consolidation for a specific user_id.
  Returns `{:ok, :started}` or `{:error, :already_in_progress}`.
  """
  def trigger_now(user_id) do
    GenServer.call(__MODULE__, {:trigger, user_id})
  end

  # ── Call handlers ──────────────────────────────────────────────────

  @impl true
  def handle_call({:set_enabled, enabled}, _from, state) do
    {:reply, :ok, Map.put(state, :enabled, enabled)}
  end

  @impl true
  def handle_call(:enabled?, _from, state) do
    {:reply, Map.get(state, :enabled, true), state}
  end

  @impl true
  def handle_call({:trigger, user_id}, _from, %{in_progress: in_progress} = state) do
    if MapSet.member?(in_progress, user_id) do
      {:reply, {:error, :already_in_progress}, state}
    else
      {state, _task} = spawn_consolidation(user_id, state)
      {:reply, {:ok, :started}, state}
    end
  end

  # ── Message handlers ───────────────────────────────────────────────

  @impl true
  def handle_info(:poll, state) do
    state =
      if Map.get(state, :enabled, true) do
        check_and_spawn(state)
      else
        state
      end
    schedule_poll()
    {:noreply, state}
  end

  @impl true
  def handle_info(:daily_sweep, state) do
    run_daily_sweep()
    schedule_daily_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{monitors: monitors, in_progress: in_progress} = state
      ) do
    case Map.pop(monitors, ref) do
      {nil, _} ->
        # Not one of ours — ignore
        {:noreply, state}

      {user_id, updated_monitors} ->
        updated_in_progress = MapSet.delete(in_progress, user_id)
        {:noreply, %{state | monitors: updated_monitors, in_progress: updated_in_progress}}
    end
  end

  # Task.Supervisor.async_nolink sends {ref, result} to the caller when the task
  # completes successfully, *before* the :DOWN message. We must handle this to
  # prevent a FunctionClauseError crash. We also clean up the in_progress lock
  # here so users aren't blocked until the subsequent :DOWN arrives.
  @impl true
  def handle_info({ref, _result}, %{monitors: monitors, in_progress: in_progress} = state)
      when is_reference(ref) do
    case Map.pop(monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {user_id, updated_monitors} ->
        # Demonitor to suppress the upcoming :DOWN — we've already cleaned up
        Process.demonitor(ref, [:flush])
        updated_in_progress = MapSet.delete(in_progress, user_id)
        {:noreply, %{state | monitors: updated_monitors, in_progress: updated_in_progress}}
    end
  end

  # Catch-all for any other stray messages (e.g. late :DOWN after flush above)
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ────────────────────────────────────────────────────────

  defp schedule_poll do
    poll_ms = Application.get_env(:librarian, :consolidation_poll_ms, @default_poll_ms)
    Process.send_after(self(), :poll, poll_ms)
  end

  defp schedule_daily_sweep do
    sweep_ms = Application.get_env(:librarian, :daily_sweep_ms, @default_sweep_ms)
    Process.send_after(self(), :daily_sweep, sweep_ms)
  end

  # Users that should never be auto-consolidated (dev/iex leftovers)
  @skip_user_ids ~w(local)

  defp check_and_spawn(state) do
    min_memories =
      Application.get_env(:librarian, :consolidation_min_memories, @default_min_memories)

    all_memories = Librarian.WarmStore.all()

    # Find all unique user_ids with enough active (non-superseded) memories.
    # Skip the "local" default user — it accumulates leftover iex/dev session
    # data and would trigger spurious sweeps during demos.
    user_ids =
      all_memories
      |> Enum.map(fn m -> m.bucket |> String.split(":") |> hd() end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in @skip_user_ids))
      |> Enum.filter(fn uid ->
        not MapSet.member?(state.in_progress, uid) and
          Enum.count(all_memories, fn m ->
            String.starts_with?(m.bucket, uid <> ":") and is_nil(m.superseded_by)
          end) >= min_memories
      end)

    Enum.reduce(user_ids, state, fn uid, acc ->
      {new_state, _task} = spawn_consolidation(uid, acc)
      new_state
    end)
  end

  defp spawn_consolidation(user_id, %{in_progress: in_progress, monitors: monitors} = state) do
    in_progress = MapSet.put(in_progress, user_id)

    task =
      Task.Supervisor.async_nolink(Librarian.TaskSupervisor, fn ->
        Librarian.Consolidator.consolidate(user_id)
      end)

    monitors = Map.put(monitors, task.ref, user_id)
    {%{state | in_progress: in_progress, monitors: monitors}, task}
  end

  # ── Daily Sweep ──────────────────────────────────────────────────────

  @doc false
  def run_daily_sweep do
    require Logger

    stale_ids = Librarian.Auth.Manifest.stale_sandbox_ids()

    if stale_ids == [] do
      Logger.info("Daily sweep: no stale sandboxes found")
      :ok
    else
      Logger.info("Daily sweep: found #{length(stale_ids)} stale sandbox(es)")

      Enum.each(stale_ids, fn sandbox_id ->
        # Skip judge accounts — their data should persist
        if Librarian.Auth.gc_whitelisted?(sandbox_id) do
          Logger.info("Daily sweep: skipping judge account #{sandbox_id}")
        else
          Logger.info("Daily sweep: cleaning up stale sandbox #{sandbox_id}")
          Librarian.ColdStore.ConnectionManager.close_connection(sandbox_id)
          Librarian.Auth.Manifest.delete(sandbox_id)
        end
      end)

      :ok
    end
  end
end

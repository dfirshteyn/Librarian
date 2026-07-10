defmodule Librarian.Auth.Manifest do
  @moduledoc """
  ETS-based sandbox manifest ledger.

  Tracks per-sandbox activity and token budgets in a lightweight in-memory
  table. This is the runtime control plane — the durable state lives in the
  per-tenant `.db` files on disk.

  ## Schema

  Each row in the `:sandbox_manifests` ETS table:

      {sandbox_id, last_active_at, token_count_budget, request_count_today, budget_date}

  - `sandbox_id`          — unique opaque identifier (e.g. `anon_<hex>`)
  - `last_active_at`      — `System.monotonic_time(:second)` of last request
  - `token_count_budget`  — daily request cap (1000 anon, 10000 judge)
  - `request_count_today` — requests used today (reset on date change)
  - `budget_date`         — the date (date tuple) the counter applies to
  """

  @table :sandbox_manifests
  @seven_days_seconds 7 * 24 * 60 * 60

  @doc """
  Initialize the ETS table. Called from `Application.start`.
  Safe to call multiple times — returns `:ok` if already exists.
  """
  def init do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Upsert the `last_active_at` timestamp for a sandbox_id.

  Should be called on every authenticated request (from the Plug).
  If the sandbox is not yet in the table, it is inserted with the
  appropriate default budget.
  """
  def touch(sandbox_id) when is_binary(sandbox_id) do
    now = System.monotonic_time(:second)
    default_budget = Librarian.Auth.default_budget(sandbox_id)
    today = :erlang.date()

    case :ets.lookup(@table, sandbox_id) do
      [{^sandbox_id, _last_active, existing_budget, count, date}] ->
        # Reset counter if the date rolled over
        {count_reset, date_reset} =
          if date == today, do: {count, date}, else: {0, today}

        :ets.insert(@table, {sandbox_id, now, existing_budget, count_reset, date_reset})

      [] ->
        :ets.insert(@table, {sandbox_id, now, default_budget, 0, today})
    end

    :ok
  end

  @doc """
  Record a request for this sandbox_id and check budget.

  Returns:
    - `{:ok, remaining}` — request counted, `remaining` is how many requests left today
    - `{:error, :budget_exhausted}` — sandbox has hit its daily cap

  The counter is scoped to the current date — it resets at midnight UTC.
  """
  def record_request(sandbox_id) when is_binary(sandbox_id) do
    today = :erlang.date()

    case :ets.lookup(@table, sandbox_id) do
      [{^sandbox_id, _last_active, existing_budget, count, date}] ->
        # Reset if date rolled over
        {effective_count, effective_date} =
          if date == today, do: {count, date}, else: {0, today}

        if effective_count >= existing_budget do
          {:error, :budget_exhausted}
        else
          new_count = effective_count + 1
          now = System.monotonic_time(:second)
          :ets.insert(@table, {sandbox_id, now, existing_budget, new_count, effective_date})
          {:ok, existing_budget - new_count}
        end

      [] ->
        # Auto-touch if we don't have an entry yet
        touch(sandbox_id)
        default_budget = Librarian.Auth.default_budget(sandbox_id)
        now = System.monotonic_time(:second)
        :ets.insert(@table, {sandbox_id, now, default_budget, 1, today})
        {:ok, default_budget - 1}
    end
  end

  @doc """
  Get the remaining request budget for a sandbox_id today.

  Returns an integer (0 if exhausted or unknown).
  """
  def budget_remaining(sandbox_id) when is_binary(sandbox_id) do
    today = :erlang.date()

    case :ets.lookup(@table, sandbox_id) do
      [{^sandbox_id, _last_active, budget, count, date}] ->
        effective_count = if date == today, do: count, else: 0
        max(0, budget - effective_count)

      [] ->
        0
    end
  end

  @doc """
  Return a list of sandbox_ids that have been inactive for >= 7 days.

  These are candidates for the daily sweep — close the SQLite connections,
  delete the `.db` files, and remove from the manifest.
  """
  def stale_sandbox_ids do
    cutoff = System.monotonic_time(:second) - @seven_days_seconds

    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {_sid, last_active, _budget, _count, _date} ->
      last_active < cutoff
    end)
    |> Enum.map(fn {sid, _last_active, _budget, _count, _date} -> sid end)
  end

  @doc """
  Remove a sandbox from the manifest (after sweep or explicit deletion).
  """
  def delete(sandbox_id) when is_binary(sandbox_id) do
    :ets.delete(@table, sandbox_id)
    :ok
  end

  @doc """
  Get the raw row for a sandbox (for dashboard / diagnostics).
  Returns `nil` if not found.
  """
  def get(sandbox_id) when is_binary(sandbox_id) do
    case :ets.lookup(@table, sandbox_id) do
      [{^sandbox_id, last_active, budget, count, date}] ->
        %{
          sandbox_id: sandbox_id,
          last_active_at: last_active,
          token_count_budget: budget,
          request_count_today: count,
          budget_date: date
        }

      [] ->
        nil
    end
  end

  @doc """
  Get all active sandboxes (for dashboard / diagnostics).
  Returns a list of maps.
  """
  def all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {sid, last_active, budget, count, date} ->
      %{
        sandbox_id: sid,
        last_active_at: last_active,
        token_count_budget: budget,
        request_count_today: count,
        budget_date: date
      }
    end)
  end

  @doc """
  Clear the entire manifest (for testing).
  """
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end
end

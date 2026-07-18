defmodule Librarian.LlamaPool do
  @moduledoc """
  Per-server concurrency limiter for llama.cpp model servers.

  Provides a semaphore per server URL so that callers across different
  features (Council, Flusher, ParentSummarizer, Consolidator) never exceed
  a server's physical slot count simultaneously.

  ## Usage

      # Before making a request to a local model server:
      LlamaPool.checkout("http://localhost:1234/v1")

      # After the request completes (in an `after`/`ensure` block):
      LlamaPool.checkin("http://localhost:1234/v1")

  ## Configuration

  Default max concurrency per server is 4. Override per URL in config:

      config :librarian, :llama_pool_defaults, %{
        "http://localhost:1234/v1" => 4,   # 0.6B chat/summarize
        "http://localhost:1235/v1" => 2,   # BGE-M3 embedding
        "http://localhost:1236/v1" => 4,   # 1.7B council
      }
  """

  use GenServer

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Acquire a slot for the given server URL. Blocks the caller until a slot
  is available. Uses `:infinity` timeout — the caller is responsible for
  its own overall timeout around the work that holds the slot.

  If the pool is not running (e.g. in tests), returns `:ok` immediately
  so callers can proceed without the pool.
  """
  @spec checkout(url :: String.t(), server :: GenServer.name()) :: :ok
  def checkout(url, server \\ __MODULE__) when is_binary(url) do
    if Process.whereis(server) do
      GenServer.call(server, {:checkout, url}, :infinity)
    else
      :ok
    end
  end

  @doc """
  Release a slot for the given server URL. If callers are waiting, the
  longest-waiting caller is unblocked immediately.

  If the pool is not running (e.g. in tests), this is a no-op.
  """
  @spec checkin(url :: String.t(), server :: GenServer.name()) :: :ok
  def checkin(url, server \\ __MODULE__) when is_binary(url) do
    if Process.whereis(server) do
      GenServer.cast(server, {:checkin, url})
    else
      :ok
    end
  end

  @doc """
  Returns the current state of all pools — useful for dashboard display
  of real-time slot usage.
  """
  @spec status(server :: GenServer.name()) :: %{
          required(String.t()) => %{available: non_neg_integer(), waiting: non_neg_integer()}
        }
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  # ── Start / Supervision ────────────────────────────────────────────

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────

  @impl true
  def init(:ok) do
    defaults = Application.get_env(:librarian, :llama_pool_defaults, %{})

    # Build initial state: one pool entry per known URL, plus a catch-all
    # for any unconfigured URL (defaults to 4).
    pools =
      Map.new(defaults, fn {url, max} ->
        {url, %{max: max, available: max, waiting: :queue.new()}}
      end)

    {:ok, %{pools: pools, catch_all_max: 4}}
  end

  @impl true
  def handle_call({:checkout, url}, from, state) do
    pool = get_or_create_pool(state, url)

    if pool.available > 0 do
      updated_pool = %{pool | available: pool.available - 1}
      {:reply, :ok, put_pool(state, url, updated_pool)}
    else
      updated_pool = %{pool | waiting: :queue.in(from, pool.waiting)}
      {:noreply, put_pool(state, url, updated_pool)}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status_map =
      state.pools
      |> Enum.map(fn {url, pool} ->
        {url, %{available: pool.available, waiting: :queue.len(pool.waiting)}}
      end)
      |> Map.new()

    {:reply, status_map, state}
  end

  @impl true
  def handle_cast({:checkin, url}, state) do
    pool = get_or_create_pool(state, url)

    case :queue.out(pool.waiting) do
      {{:value, from}, rest} ->
        # There's a waiter — hand the slot directly to them without
        # incrementing available count
        GenServer.reply(from, :ok)
        updated_pool = %{pool | waiting: rest}
        {:noreply, put_pool(state, url, updated_pool)}

      {:empty, _} ->
        # No waiters — return the slot to the pool
        updated_pool = %{pool | available: pool.available + 1}
        {:noreply, put_pool(state, url, updated_pool)}
    end
  end

  # ── Private Helpers ─────────────────────────────────────────────────

  defp get_or_create_pool(%{pools: pools, catch_all_max: max}, url) do
    case Map.get(pools, url) do
      nil ->
        %{max: max, available: max, waiting: :queue.new()}

      pool ->
        pool
    end
  end

  defp put_pool(%{pools: pools} = state, url, pool) do
    %{state | pools: Map.put(pools, url, pool)}
  end
end

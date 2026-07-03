defmodule Librarian.HotStore do
  @moduledoc """
  The HOT tier: one GenServer + one ETS table per bucket, holding raw
  payloads in memory. No embeddings here — just storage and the kind of
  pattern-match lookups that should never wait on a model.

  Each bucket is its own process under a DynamicSupervisor, so if
  curation crashes mid-flush for "project", "research" and "ideas" keep
  running untouched — this is the actual point of doing this in Elixir
  instead of a flat Python dict.
  """

  use GenServer

  @registry Librarian.BucketRegistry

  # --- public API ---

  def put(bucket, %Librarian.Capture.Payload{} = payload) do
    ensure_started(bucket)
    GenServer.cast(via(bucket), {:put, payload})
  end

  def all(bucket) do
    case Registry.lookup(@registry, bucket) do
      [{pid, _}] -> GenServer.call(pid, :all)
      [] -> []
    end
  end

  def drain(bucket) do
    case Registry.lookup(@registry, bucket) do
      [{pid, _}] -> GenServer.call(pid, :drain)
      [] -> []
    end
  end

  def buckets do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  def count(bucket) do
    case Registry.lookup(@registry, bucket) do
      [{pid, _}] -> GenServer.call(pid, :count)
      [] -> 0
    end
  end

  def ensure_started(bucket) do
    case Registry.lookup(@registry, bucket) do
      [{_pid, _}] ->
        :ok

      [] ->
        case DynamicSupervisor.start_child(
               Librarian.BucketSupervisor,
               {__MODULE__, bucket}
             ) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
    end
  end

  defp via(bucket), do: {:via, Registry, {@registry, bucket}}

  # --- GenServer ---

  def child_spec(bucket) do
    %{
      id: {__MODULE__, bucket},
      start: {__MODULE__, :start_link, [bucket]},
      restart: :transient
    }
  end

  def start_link(bucket) do
    GenServer.start_link(__MODULE__, bucket, name: via(bucket))
  end

  @impl true
  def init(bucket) do
    table = :ets.new(:"hot_#{bucket}", [:ordered_set, :private])
    seq = replay_wal(bucket, table)
    {:ok, %{bucket: bucket, table: table, seq: seq}}
  end

  # Replay any WAL entries that survived the crash/restart.
  # This is what closes the "HOT crash loses unflushed data" gap:
  # on restart we stream the WAL back in before accepting new writes.
  defp replay_wal(bucket, table) do
    Librarian.Wal.replay(bucket)
    |> Enum.reduce(0, fn payload, seq ->
      :ets.insert(table, {seq, payload})
      seq + 1
    end)
  end

  @impl true
  def handle_cast({:put, payload}, %{bucket: bucket, table: table, seq: seq} = state) do
    # WAL write happens first — this is what makes it write-ahead.
    # If we crash between the WAL write and the ETS insert, the next
    # init/1 will replay the WAL and get the payload back.
    Librarian.Wal.append(bucket, payload)
    :ets.insert(table, {seq, payload})
    {:noreply, %{state | seq: seq + 1}}
  end

  @impl true
  def handle_call(:all, _from, %{table: table} = state) do
    items = table |> :ets.tab2list() |> Enum.map(fn {_seq, payload} -> payload end)
    {:reply, items, state}
  end

  @impl true
  def handle_call(:drain, _from, %{table: table} = state) do
    items = table |> :ets.tab2list() |> Enum.map(fn {_seq, payload} -> payload end)
    :ets.delete_all_objects(table)
    {:reply, items, state}
  end

  @impl true
  def handle_call(:count, _from, %{table: table} = state) do
    {:reply, :ets.info(table, :size), state}
  end
end

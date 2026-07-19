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

  @doc """
  Put a payload only if an identical raw_text isn't already in HOT.
  Returns `{:ok, :stored}` or `{:ok, :duplicate}`.
  """
  def put_unless_duplicate(bucket, %Librarian.Capture.Payload{} = payload) do
    ensure_started(bucket)
    GenServer.call(via(bucket), {:put_unless_duplicate, payload})
  end

  @doc """
  Store a payload deterministically - skips the raw_text duplicate check.
  Used for file chunks which are uniquely identified by their source + index.
  Returns `{:ok, :stored}` - never returns duplicate.
  """
  def put_deterministic(bucket, %Librarian.Capture.Payload{} = payload) do
    ensure_started(bucket)
    GenServer.call(via(bucket), {:put_deterministic, payload})
  end

  @doc "Check if a payload with the same raw_text already exists in this HOT bucket."
  def contains_text?(bucket, text) do
    case Registry.lookup(@registry, bucket) do
      [{pid, _}] -> GenServer.call(pid, {:contains_text?, text})
      [] -> false
    end
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

  @doc """
  Return all payloads across all buckets for a given user,
  each paired with its bucket name.
  Used to populate the ingest feed on mount and refresh.
  """
  def all_for_user(user_id) do
    buckets()
    |> Enum.filter(&String.starts_with?(&1, "#{user_id}:"))
    |> Enum.flat_map(fn bucket ->
      Enum.map(all(bucket), fn payload -> {bucket, payload} end)
    end)
  end

  @doc """
  Return payloads for user's buckets, converted to feed entry format.
  Each entry has: id, bucket, source, preview, user_id, at
  """
  def feed_entries_for_user(user_id) do
    all_for_user(user_id)
    |> Enum.with_index()
    |> Enum.map(fn {{bucket, payload}, idx} ->
      %{
        id: System.unique_integer([:positive, :monotonic]) + idx,
        bucket: bucket,
        source: payload.source,
        preview: String.slice(payload.raw_text || "", 0, 80),
        user_id: user_id,
        at: payload.occurred_at
      }
    end)
  end

  @doc """
  Rename a HOT bucket: drain old name and re-put under new name.
  If the old bucket has no data, this is a no-op.
  """
  def rename(old_bucket, new_bucket) do
    payloads = drain(old_bucket)

    case payloads do
      [] ->
        :ok

      _ ->
        ensure_started(new_bucket)

        Enum.each(payloads, fn payload ->
          Librarian.Wal.append(new_bucket, payload)
          GenServer.cast(via(new_bucket), {:put, payload})
        end)

        # Terminate the old bucket's GenServer
        case Registry.lookup(@registry, old_bucket) do
          [{pid, _}] ->
            DynamicSupervisor.terminate_child(Librarian.BucketSupervisor, pid)
            Librarian.Wal.truncate(old_bucket)

          [] ->
            :ok
        end

        :ok
    end
  end

  @doc """
  Terminate a HOT bucket's GenServer and drop its WAL.
  Called during bucket deletion.
  """
  def terminate_bucket(bucket) do
    # Drain first (discard data on explicit delete)
    _ = drain(bucket)

    case Registry.lookup(@registry, bucket) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(Librarian.BucketSupervisor, pid)
        Librarian.Wal.truncate(bucket)
        :ok

      [] ->
        :ok
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

  # Scan the ordered_set ETS table for an existing payload with the same raw_text.
  # ETS is :ordered_set keyed by {seq}, so we must scan — but HOT is small
  # (hundreds of items max), so this is fast.
  defp exists_raw_text?(table, text) do
    :ets.foldl(
      fn {_seq, payload}, acc ->
        if payload.raw_text == text, do: true, else: acc
      end,
      false,
      table
    )
  end

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
    user_id = bucket |> String.split(":") |> hd()

    Librarian.Wal.replay(bucket)
    |> Enum.reduce(0, fn payload, seq ->
      :ets.insert(table, {seq, payload})
      # Notify FlushQueue that payloads were restored from WAL (for auto-flush)
      Librarian.FlushQueue.payload_added(user_id, bucket)
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
  def handle_call(
        {:put_unless_duplicate, payload},
        _from,
        %{bucket: bucket, table: table, seq: seq} = state
      ) do
    if exists_raw_text?(table, payload.raw_text) do
      {:reply, {:ok, :duplicate}, state}
    else
      Librarian.Wal.append(bucket, payload)
      :ets.insert(table, {seq, payload})
      {:reply, {:ok, :stored}, %{state | seq: seq + 1}}
    end
  end

  @impl true
  def handle_call(
        {:put_deterministic, payload},
        _from,
        %{bucket: bucket, table: table, seq: seq} = state
      ) do
    # Skip the duplicate check - chunks are uniquely identified by source+index
    Librarian.Wal.append(bucket, payload)
    :ets.insert(table, {seq, payload})
    {:reply, {:ok, :stored}, %{state | seq: seq + 1}}
  end

  @impl true
  def handle_call({:contains_text?, text}, _from, %{table: table} = state) do
    {:reply, exists_raw_text?(table, text), state}
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

defmodule Librarian.ChunkTracker do
  @moduledoc """
  Tracks chunked document completion across concurrent chunk ingestion.

  Ensures parent summarization only fires after all chunks from a document
  have been successfully flushed to WARM. Uses synchronous registration to
  prevent race conditions where chunks could arrive before registration.

  State schema: %{correlation_id => %{expected: N, received_ids: MapSet{}, user_id: "uid"}}
  """

  use GenServer

  @doc "Start the ChunkTracker GenServer."
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Register a chunked document before dispatching ingestion.

  MUST be called synchronously before any `chunk_flushed/2` calls can happen.
  Returns `:ok` once the tracking entry is guaranteed to exist.
  """
  def register_chunks(correlation_id, total_count, user_id)
      when is_binary(correlation_id) and is_integer(total_count) and is_binary(user_id) do
    GenServer.call(__MODULE__, {:register, correlation_id, total_count, user_id})
  end

  @doc """
  Record a chunk's successful flush. Idempotent - safely handles retries.

  When all chunks have been received, broadcasts `{:parent_needed, correlation_id, chunk_ids, user_id}`
  on Phoenix.PubSub and cleans up the tracking entry.
  """
  def chunk_flushed(correlation_id, memory_id)
      when is_binary(correlation_id) and is_integer(memory_id) do
    GenServer.call(__MODULE__, {:flushed, correlation_id, memory_id})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, correlation_id, total_count, user_id}, _from, state) do
    # Pre-populate with expected count, empty received set
    new_entry = %{expected: total_count, received_ids: MapSet.new(), user_id: user_id}
    {:reply, :ok, Map.put(state, correlation_id, new_entry)}
  end

  @impl true
  def handle_call({:flushed, correlation_id, memory_id}, _from, state) do
    case Map.fetch(state, correlation_id) do
      {:ok, entry} ->
        # Idempotency: only count each chunk_id once
        if MapSet.member?(entry.received_ids, memory_id) do
          {:reply, :ok, state}
        else
          new_received = MapSet.put(entry.received_ids, memory_id)
          new_entry = %{entry | received_ids: new_received}
          new_state = Map.put(state, correlation_id, new_entry)

          # Check if we've received all chunks
          if MapSet.size(new_received) >= new_entry.expected do
            # Get all chunk IDs as a list
            chunk_ids = MapSet.to_list(new_received)
            user_id = new_entry.user_id

            # Broadcast completion event
            Phoenix.PubSub.broadcast(
              Librarian.PubSub,
              "chunk_tracking",
              {:parent_needed, correlation_id, chunk_ids, user_id}
            )

            # Clean up tracking entry to prevent memory leak
            cleaned_state = Map.delete(new_state, correlation_id)

            {:reply, {:complete, correlation_id}, cleaned_state}
          else
            {:reply, :ok, new_state}
          end
        end

      :error ->
        # Unknown correlation_id - this shouldn't happen with proper registration
        # Log warning but don't crash
        require Logger
        Logger.warning("[ChunkTracker] Received flush for unregistered correlation_id: #{correlation_id}")
        {:reply, {:error, :not_registered}, state}
    end
  end
end

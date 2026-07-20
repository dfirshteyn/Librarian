defmodule Librarian.FlushProgressAgent do
  @moduledoc """
  Agent for tracking flush progress across processes.

  Stores progress state as:
  %{
    user_id => %{
      bucket => %{processed: N, total: M, memories: [list of completed memory ids]}
    }
  }
  """

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc "Initialize progress tracking for a user's flush."
  def init_progress(user_id, bucket, total) do
    Agent.update(__MODULE__, fn state ->
      user_state = Map.get(state, user_id, %{})

      updated_user_state =
        Map.put(user_state, bucket, %{processed: 0, total: total, memories: []})

      Map.put(state, user_id, updated_user_state)
    end)
  end

  @doc "Increment progress and broadcast. Signature: report_progress(user_id, bucket, memory)."
  def report_progress(user_id, bucket, memory) do
    Agent.get_and_update(__MODULE__, fn state ->
      user_state = Map.get(state, user_id, %{})
      bucket_state = Map.get(user_state, bucket, %{processed: 0, total: 0, memories: []})

      new_processed = bucket_state.processed + 1
      new_memories = [memory | bucket_state.memories]
      new_bucket_state = %{bucket_state | processed: new_processed, memories: new_memories}
      new_user_state = Map.put(user_state, bucket, new_bucket_state)
      new_state = Map.put(state, user_id, new_user_state)

      {{memory, new_processed, bucket_state.total}, new_state}
    end)
    |> case do
      {memory, processed, total} when is_map(memory) ->
        # Broadcast to all dashboards (includes memory for animation)
        Phoenix.PubSub.broadcast(
          Librarian.PubSub,
          "flush_progress",
          {:flush_progress, user_id, bucket, processed, total, memory}
        )

      {_memory, _processed, _total} ->
        :ok
    end
  end

  @doc "Report progress - alias for backward compatibility with callback-style usage."
  def report_progress(user_id, bucket, memory, _unused_callback) do
    report_progress(user_id, bucket, memory)
  end

  @doc "Get current progress for a user."
  def get_progress(user_id) do
    Agent.get(__MODULE__, &Map.get(&1, user_id))
  end

  @doc "Clear progress tracking for a user after flush completes."
  def clear_progress(user_id) do
    Agent.update(__MODULE__, fn state ->
      Map.delete(state, user_id)
    end)
  end

  @doc "Reset progress for a specific bucket."
  def reset_bucket(user_id, bucket) do
    Agent.update(__MODULE__, fn state ->
      user_state = Map.get(state, user_id, %{})
      Map.put(state, user_id, Map.delete(user_state, bucket))
    end)
  end
end

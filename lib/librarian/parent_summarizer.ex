defmodule Librarian.ParentSummarizer do
  @moduledoc """
  Creates parent memories from chunked document summaries.

  Subscribes to PubSub "chunk_tracking" and responds to {:parent_needed, ...}
  events by synthesizing a coherent parent memory from all chunks.
  """

  use GenServer

  @doc "Start the ParentSummarizer and subscribe to chunk tracking events."
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # --- Public API ---

  @doc """
  Manually trigger parent summarization for a correlation_id.
  Useful for testing or recovery.
  """
  def synthesize_parent(correlation_id, chunk_ids, user_id)
      when is_binary(correlation_id) and is_list(chunk_ids) and is_binary(user_id) do
    GenServer.call(__MODULE__, {:synthesize, correlation_id, chunk_ids, user_id})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Librarian.PubSub, "chunk_tracking")
    {:ok, :ok}
  end

  @impl true
  def handle_call({:synthesize, correlation_id, chunk_ids, user_id}, _from, :ok) do
    result = do_synthesize_parent(correlation_id, chunk_ids, user_id)
    {:reply, result, :ok}
  end

  @impl true
  def handle_info({:parent_needed, correlation_id, chunk_ids, user_id}, :ok) do
    # Fire-and-forget - don't block the PubSub handler
    Task.Supervisor.async_nolink(Librarian.TaskSupervisor, fn ->
      result = do_synthesize_parent(correlation_id, chunk_ids, user_id)

      # Log failures for visibility - this runs in the task process
      case result do
        {:error, reason} ->
          require Logger
          Logger.warning("[ParentSummarizer] Synthesis failed for correlation_id=#{correlation_id}: #{inspect(reason)}")

          Librarian.ColdStore.log_insight(%{
            "kind" => "parent_synthesis_failed",
            "correlation_id" => correlation_id,
            "chunk_ids" => chunk_ids,
            "error" => inspect(reason)
          })

        _ ->
          :ok
      end

      result
    end)

    {:noreply, :ok}
  end

  # Handle task replies from async_nolink (they send {ref, result} messages)
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, :ok) do
    {:noreply, :ok}
  end

  @impl true
  def handle_info({_ref, _result}, :ok) do
    {:noreply, :ok}
  end

  # --- Private Implementation ---

  defp do_synthesize_parent(correlation_id, chunk_ids, user_id) do
    # 1. Fetch all chunk memories
    chunk_memories = Enum.map(chunk_ids, &Librarian.WarmStore.get/1)

    # Filter out any nil (deleted/expired) memories
    valid_memories = Enum.reject(chunk_memories, &is_nil/1)

    if length(valid_memories) == 0 do
      {:error, :no_valid_chunks}
    else
      # 2. Combine summaries + facts into synthesis input
      combined_text = build_combined_text(valid_memories)

      # 3. Create synthesis payload
      payload = %Librarian.Capture.Payload{
        source: "parent_summarizer",
        raw_text: combined_text
      }

      # 4. Run through curator
      curator_impl = Librarian.Curator.resolve_curator(user_id, [])

      result =
        case Librarian.Curator.summarize([payload], curator_impl) do
          {:ok, curated} ->
            # 5. Generate embedding
            with {:ok, vec} <- Librarian.Curator.embed(curated.summary, curator_impl) do
              {:ok, %{curated | embedding: vec}}
            else
              _ -> {:ok, curated}
            end

          {:error, reason} ->
            {:error, reason}
        end

      case result do
        {:ok, curated_result} ->
          # 6. Normalize bucket and create WARM memory
          normalized = Librarian.Router.normalize_bucket(curated_result.bucket || "inbox", user_id)
          warm_bucket = "#{user_id}:#{normalized}"

          # Store in WARM with the correlation_id pointing to itself (self-referential)
          parent_memory = Librarian.WarmStore.put(warm_bucket, curated_result, correlation_id: correlation_id)

          # 7. Create chunk_of edges from each chunk to parent
          Enum.each(chunk_ids, fn chunk_id ->
            Librarian.ColdStore.log_relationship(
              to_string(chunk_id),
              to_string(parent_memory.id),
              "chunk_of",
              user_id,
              %{}
            )
          end)

          # 8. Archive to COLD
          Librarian.ColdStore.archive(parent_memory, user_id)

          # Log the synthesis event
          Librarian.ColdStore.log_insight(%{
            "kind" => "parent_synthesized",
            "correlation_id" => correlation_id,
            "parent_id" => parent_memory.id,
            "chunk_count" => length(chunk_ids)
          })

          {:ok, parent_memory}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_combined_text(memories) do
    memories
    |> Enum.map(fn m ->
      summary_part = m.summary || ""
      facts_part = Enum.join(m.facts || [], ". ")
      """
      Summary: #{summary_part}
      Facts: #{facts_part}
      """
    end)
    |> Enum.join("\n---\n")
  end
end

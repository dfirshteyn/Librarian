defmodule Librarian.Council do
  @moduledoc """
  Multi-agent Knowledge Council orchestrator.

  Runs Stage 1 (independent persona perspectives) on content.
  Results are then fed to Judge.synthesize/2 for final output.
  """

  alias Librarian.Council.Persona
  alias Librarian.Council.Judge

  @default_timeout 60_000

  @doc """
  Run the full Council process on content.

  Stage 1: Each persona independently analyzes the content (in parallel)
  Stage 3: Judge synthesizes successful takes only

  Returns {:ok, final_result} or {:error, reason}
  """
  @spec deliberate(String.t()) ::
          {:ok,
           %{
             synthesis: String.t(),
             persona_takes: %{optional(atom()) => String.t()},
             failures: list()
           }}
          | {:error, term()}
  def deliberate(content) when is_binary(content) do
    personas = Persona.available_personas()

    # Stage 1: Get all persona takes in parallel
    raw_results =
      Task.async_stream(
        personas,
        fn persona -> get_persona_take(persona, content) end,
        timeout: @default_timeout,
        max_concurrency: 4,
        on_timeout: :kill_task
      )
      |> Enum.zip(personas)
      |> Enum.map(fn
        {{:ok, {:ok, take}}, persona} -> {persona, take}
        {{:ok, {:error, reason}}, persona} -> {persona, {:error, reason}}
        {{:exit, reason}, persona} -> {persona, {:error, {:timeout, reason}}}
      end)

    # Filter: only binary takes are successes
    {successes, failures} =
      raw_results
      |> Enum.map(fn {p, take} ->
        if is_binary(take) do
          {:ok, {p, take}}
        else
          {:error, {p, take}}
        end
      end)
      |> Enum.split_with(&match?({:ok, _}, &1))
      |> then(fn {successes, failures} ->
        {Enum.map(successes, &elem(&1, 1)), Enum.map(failures, &elem(&1, 1))}
      end)

    # Log failures for visibility (same pattern as ParentSummarizer)
    if length(failures) > 0 do
      require Logger

      Enum.each(failures, fn {persona, error} ->
        Logger.warning("[Council] #{persona} failed: #{inspect(error)}")
      end)
    end

    # Stage 3: Judge synthesizes only successful takes
    # Detect specific error patterns for better diagnostics
    if successes == [] do
      if all_connection_errors?(failures) do
        {:error, :local_model_server_unreachable}
      else
        {:error, :all_personas_failed}
      end
    else
      case Judge.synthesize(content, successes) do
        {:ok, synthesis} ->
          {:ok,
           %{
             persona_takes: persona_takes_by_name(successes),
             failures: failures,
             synthesis: synthesis
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Run only Stage 1 - get independent persona perspectives.
  Useful for debugging or when you want to inspect individual takes.
  """
  @spec stage_one(String.t()) :: [{Persona.persona_type(), String.t() | {:error, term()}}]
  def stage_one(content) when is_binary(content) do
    personas = Persona.available_personas()

    Task.async_stream(
      personas,
      fn persona -> get_persona_take(persona, content) end,
      timeout: @default_timeout,
      max_concurrency: 4,
      on_timeout: :kill_task
    )
    |> Enum.zip(personas)
    |> Enum.map(fn
      {{:ok, {:ok, take}}, persona} -> {persona, take}
      {{:ok, {:error, reason}}, persona} -> {persona, {:error, reason}}
      {{:exit, reason}, persona} -> {persona, {:error, {:timeout, reason}}}
    end)
  end

  @doc """
  Run Council on a memory ID - fetches the memory and runs deliberation.
  """
  @spec deliberate_on_memory(integer()) ::
          {:ok,
           %{
             synthesis: String.t(),
             persona_takes: %{optional(atom()) => String.t()},
             failures: list()
           }}
          | {:error, term()}
  def deliberate_on_memory(memory_id) when is_integer(memory_id) do
    case Librarian.WarmStore.get(memory_id) do
      nil ->
        {:error, :memory_not_found}

      memory ->
        content = build_context_from_memory(memory)
        deliberate(content)
    end
  end

  # --- Private Implementation ---

  # Public entry point with retry support for connection-level errors
  defp get_persona_take(persona, content, retries \\ 1) do
    case get_persona_take_impl(persona, content) do
      {:error, {:api_error, {:http_error, reason}}} when retries > 0 ->
        # Connection-level failure - retry once with backoff
        if is_connection_reason?(reason) do
          Process.sleep(500)
          get_persona_take(persona, content, retries - 1)
        else
          {:error, {:api_error, {:http_error, reason}}}
        end

      {:error, {:api_error, {:api_error, status, _}}} when retries > 0 ->
        # Server error (502/503/504) - retry once with backoff
        if status in [502, 503, 504] do
          Process.sleep(500)
          get_persona_take(persona, content, retries - 1)
        else
          {:error, {:api_error, {:api_error, status, nil}}}
        end

      result ->
        result
    end
  end

  # Internal implementation without retry
  defp get_persona_take_impl(persona, content) do
    cfg = Persona.config(persona)

    prompt = "Analyze the following context block:\n\n#{content}"
    {scrubbed_prompt, _} = Librarian.LeakGuard.scrub(prompt)

    # Stage 1: Personas routed via ModelRouting (Qwen Turbo by default)
    {mod, model} = Librarian.ModelRouting.for(:council_persona)

    case mod.chat(scrubbed_prompt,
           system_prompt: cfg.system_prompt,
           temperature: cfg.temperature,
           model: model
         ) do
      {:ok, body} ->
        parse_take(body)

      {:error, reason} ->
        {:error, {:api_error, reason}}
    end
  end

  defp build_context_from_memory(memory) do
    user_id = memory.bucket |> String.split(":", parts: 2) |> List.first()

    # Parent section: the memory's own summary and facts (the compressed view)
    parent_section = """
    #{memory.summary || ""}

    Facts: #{Enum.join(memory.facts || [], ". ")}
    """

    # Children grounding section: raw chunk summaries from 1-hop graph neighbors
    children_section = build_children_context(memory, user_id)

    if children_section == "" do
      parent_section
    else
      """
      #{parent_section}

      ### DETAILED SOURCE MATERIAL FROM CHILD CHUNKS:
      #{children_section}
      """
    end
  end

  defp build_children_context(memory, user_id) when is_binary(user_id) do
    memory_id_str = to_string(memory.id)

    %{incoming: incoming} = Librarian.ColdStore.get_memory_lineage(memory_id_str, user_id)

    child_ids =
      incoming
      |> Enum.filter(fn r -> r.type == "chunk_of" end)
      |> Enum.map(fn r -> r.source_id end)

    child_ids
    |> Enum.map(fn id_str ->
      case Integer.parse(id_str) do
        {int_id, ""} -> Librarian.WarmStore.get(int_id)
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {chunk, idx} ->
      """
      --- Source Chunk ##{idx} ---
      #{chunk.summary || ""}
      Facts: #{Enum.join(chunk.facts || [], ". ")}
      """
    end)
    |> Enum.join("\n")
  end

  defp build_children_context(_memory, _user_id), do: ""

  defp parse_take(body) do
    with content when is_binary(content) <-
           get_in(body, ["choices", Access.at(0), "message", "content"]) do
      {:ok, String.trim(content)}
    else
      _ -> {:error, :missing_content}
    end
  end

  # Convert [{persona_atom, take}] to %{"persona_name" => take} for readable output
  defp persona_takes_by_name(persona_takes) do
    Enum.map(persona_takes, fn {persona, take} ->
      {Librarian.Council.Persona.config(persona).name, take}
    end)
    |> Map.new()
  end

  # Check if all failures were connection-level errors (server unreachable pattern)
  defp all_connection_errors?(failures) do
    Enum.all?(failures, fn {_persona, error} ->
      connection_error?(error)
    end)
  end

  # Detect connection-level errors that are worth retrying
  defp connection_error?(error) do
    case error do
      # Direct connection refused/reset from HTTP client
      {:api_error, {:http_error, reason}} ->
        is_connection_reason?(reason)

      # Server returned 502/503/504 - server may be restarting
      {:api_error, {:api_error, status, _}} ->
        status in [502, 503, 504]

      # Timeout from Task.async_stream (server hung)
      {:timeout, _} ->
        true

      _ ->
        false
    end
  end

  defp is_connection_reason?(reason) do
    case reason do
      :econnrefused -> true
      :econnreset -> true
      :ehostdown -> true
      %Mint.TransportError{} -> true
      _ -> false
    end
  end
end

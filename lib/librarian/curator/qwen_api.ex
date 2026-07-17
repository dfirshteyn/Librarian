defmodule Librarian.Curator.QwenApi do
  @moduledoc """
  Curator backend that calls Alibaba Cloud DashScope (Qwen) for the
  heavy, asynchronous nightly curation pass.

  LeakGuard scrubbing happens in `Librarian.Curator.summarize/1` before
  this module is ever called — the chunk arriving here is already clean.
  We scrub again on the assembled prompt string as a belt-and-suspenders
  check, since the prompt template itself could theoretically surface
  something the per-payload scrub missed.

  Configure via:
      config :librarian, curator: Librarian.Curator.QwenApi
  API key via env:
      export DASHSCOPE_API_KEY=sk-...
  """

  @behaviour Librarian.Curator

  @base_url "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
  @model "qwen3.7-max-preview"

  @impl true
  def describe_image(image_data, opts \\ []) do
    prompt =
      Keyword.get(
        opts,
        :prompt,
        "Describe this image in detail, including any text, objects, people, and the overall scene."
      )

    model = vision_model()

    api_key =
      Application.get_env(:librarian, :dashscope_api_key) ||
        raise "DASHSCOPE_API_KEY not set — export it or add to runtime.exs"

    # Base64-encode if raw binary
    b64_data =
      case image_data do
        "data:image" <> _ -> image_data
        _ -> "data:image/png;base64,#{Base.encode64(image_data)}"
      end

    messages = [
      %{
        "role" => "user",
        "content" => [
          %{"type" => "image_url", "image_url" => %{"url" => b64_data}},
          %{"type" => "text", "text" => prompt}
        ]
      }
    ]

    body = %{
      "model" => model,
      "messages" => messages
    }

    case Req.post(req(),
           url: "#{@base_url}/chat/completions",
           json: body,
           headers: [{"authorization", "Bearer #{api_key}"}],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        case get_in(resp_body, ["choices", Access.at(0), "message", "content"]) do
          content when is_binary(content) -> {:ok, content}
          nil -> {:error, :missing_content}
        end

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:api_error, status, resp_body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @impl true
  @spec summarize(maybe_improper_list()) :: {:error, any()} | {:ok, Librarian.Curator.Result.t()}
  def summarize(chunk) when is_list(chunk) do
    text = chunk |> Enum.map(& &1.raw_text) |> Enum.join("\n---\n")
    {prompt, _} = Librarian.LeakGuard.scrub(build_prompt(text))

    with {:ok, body} <- chat(prompt),
         {:ok, result} <- parse_result(body) do
      {:ok, result}
    end
  end

  @impl true
  def embed(_text) do
    # DashScope has an embeddings endpoint but we don't need it for the
    # hackathon — Stub's hashed bag-of-words is used for local recall,
    # and Qwen is only called for the nightly deep-reasoning pass.
    # Wire this up when you add Bumblebee or want cloud embeddings.
    {:error, :not_implemented}
  end

  @doc """
  Deep reasoning pass over all WARM memories. Called by the Hybrid
  curator on a schedule (not on the hot path). Asks Qwen to:
    - Re-rank importance scores
    - Detect contradictions between memories
    - Suggest cross-bucket connections the small model missed
    - Propose new tags for improved recall

  Returns a list of suggested actions (supersessions, tag updates,
  re-scoring) that the caller applies.
  """
  def deep_pass(memories) when is_list(memories) do
    text =
      memories
      |> Enum.with_index()
      |> Enum.map(fn {m, i} ->
        "#{i + 1}. [#{m.bucket}] #{m.summary} (tags: #{Enum.join(m.tags || [], ", ")}, importance: #{m.importance})"
      end)
      |> Enum.join("\n")

    {prompt, _} = Librarian.LeakGuard.scrub(build_deep_pass_prompt(text))

    with {:ok, body} <- chat(prompt),
         {:ok, actions} <- parse_deep_pass(body) do
      {:ok, actions}
    end
  end

  # --- internals ---

  defp build_prompt(text) do
    """
    You are a memory curator. Analyze the following captured notes and return a JSON object with exactly these keys:
    - "summary": a single concise sentence distilling the core idea
    - "facts": a JSON array of short atomic fact strings (max 5)
    - "tags": a JSON array of 3-6 lowercase keyword strings for associative linking
    - "importance": a float 0.0-1.0 reflecting how decision-critical this is
    - "bucket": one of "project", "research", "ideas", "thoughts", "finance", "inbox" — the single best semantic bucket for this memory. Use "inbox" only if it fits none of the others.

    Respond with ONLY the JSON object, no markdown, no explanation.

    Notes:
    #{text}
    """
  end

  @doc """
  Internal chat function with optional temperature and system prompt support.
  Used by Council modules for persona-based calls.
  """
  def chat(prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    api_key =
      Application.get_env(:librarian, :dashscope_api_key) ||
        raise "DASHSCOPE_API_KEY not set — export it or add to runtime.exs"

    messages =
      case Keyword.get(opts, :system_prompt) do
        nil ->
          [%{"role" => "user", "content" => prompt}]

        prompt_text ->
          [
            %{"role" => "system", "content" => prompt_text},
            %{"role" => "user", "content" => prompt}
          ]
      end

    temperature = Keyword.get(opts, :temperature)

    body =
      case temperature do
        nil ->
          %{
            "model" => @model,
            "messages" => messages,
            "response_format" => %{"type" => "json_object"}
          }

        _ ->
          %{
            "model" => @model,
            "messages" => messages,
            "response_format" => %{"type" => "json_object"},
            "temperature" => temperature
          }
      end

    case Req.post(req(),
           url: "#{@base_url}/chat/completions",
           json: body,
           headers: [{"authorization", "Bearer #{api_key}"}],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        {:ok, resp_body}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:api_error, status, resp_body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  # Returns the configured vision model, defaulting to "qwen-vl-max"
  defp vision_model do
    Application.get_env(:librarian, :dashscope, [])
    |> Keyword.get(:vision_model, "qwen-vl-max")
  end

  # Returns either a Req struct (test: pre-built with a plug adapter)
  # or a plain new Req struct (prod). Tests set :req_module to a
  # %Req.Request{} with a plug: plug already attached.
  defp req do
    case Application.get_env(:librarian, :req_module) do
      {:mock, mock_finch} -> Req.new() |> Map.put(:private, %{req_finch: mock_finch})
      nil -> Req.new()
      %Req.Request{} = r -> r
      _ -> Req.new()
    end
  end

  defp parse_result(body) do
    with content when is_binary(content) <-
           get_in(body, ["choices", Access.at(0), "message", "content"]),
         {:ok, map} <- Librarian.Json.decode(content) do
      {:ok,
       %Librarian.Curator.Result{
         summary: map["summary"] || "",
         facts: map["facts"] || [],
         tags: map["tags"] || [],
         importance: to_float(map["importance"]),
         bucket: Librarian.Router.normalize_bucket(map["bucket"]),
         embedding: nil
       }}
    else
      nil -> {:error, :missing_content}
      {:error, _} = err -> err
    end
  end

  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v / 1
  defp to_float(_), do: 0.5

  defp build_deep_pass_prompt(text) do
    """
    You are a senior memory curator performing a nightly deep-reasoning pass.
    Below are all current WARM memories with their bucket, summary, tags, and importance.

    Analyze them and return a JSON object with exactly these keys:
    - "supersessions": a JSON array of objects, each with "old_id" (integer) and "new_id" (integer) — memories where the later one clearly contradicts or replaces the earlier one in the same bucket
    - "re_scores": a JSON array of objects, each with "id" (integer) and "importance" (float 0.0-1.0) — memories whose importance you'd adjust based on how decision-critical they appear
    - "cross_connections": a JSON array of objects, each with "id_a" (integer), "id_b" (integer), and "note" (string) — cross-bucket connections the curator should log as synaptic jumps
    - "new_tags": a JSON array of objects, each with "id" (integer) and "tags" (array of strings) — suggested additional tags for better recall

    Be conservative. Only flag clear contradictions or strong connections.
    Respond with ONLY the JSON object, no markdown, no explanation.

    Memories:
    #{text}
    """
  end

  defp parse_deep_pass(body) do
    with content when is_binary(content) <-
           get_in(body, ["choices", Access.at(0), "message", "content"]),
         {:ok, map} <- Librarian.Json.decode(content) do
      {:ok,
       %{
         supersessions: map["supersessions"] || [],
         re_scores: map["re_scores"] || [],
         cross_connections: map["cross_connections"] || [],
         new_tags: map["new_tags"] || []
       }}
    else
      nil -> {:error, :missing_content}
      {:error, _} = err -> err
    end
  end
end

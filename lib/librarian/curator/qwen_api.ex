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
  @model "qwen-max"

  @impl true
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

  # --- internals ---

  defp build_prompt(text) do
    """
    You are a memory curator. Analyze the following captured notes and return a JSON object with exactly these keys:
    - "summary": a single concise sentence distilling the core idea
    - "facts": a JSON array of short atomic fact strings (max 5)
    - "tags": a JSON array of 3-6 lowercase keyword strings for associative linking
    - "importance": a float 0.0-1.0 reflecting how decision-critical this is

    Respond with ONLY the JSON object, no markdown, no explanation.

    Notes:
    #{text}
    """
  end

  defp chat(prompt) do
    api_key = Application.get_env(:librarian, :dashscope_api_key) ||
      raise "DASHSCOPE_API_KEY not set — export it or add to runtime.exs"

    body = %{
      "model" => @model,
      "messages" => [%{"role" => "user", "content" => prompt}],
      "response_format" => %{"type" => "json_object"}
    }

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

  # Returns either a Req struct (test: pre-built with a plug adapter)
  # or a plain new Req struct (prod). Tests set :req_module to a
  # %Req.Request{} with a plug: plug already attached.
  defp req do
    case Application.get_env(:librarian, :req_module) do
      nil -> Req.new()
      %Req.Request{} = r -> r
      _ -> Req.new()
    end
  end

  defp parse_result(body) do
    with content when is_binary(content) <- get_in(body, ["choices", Access.at(0), "message", "content"]),
         {:ok, map} <- Librarian.Json.decode(content) do
      {:ok, %Librarian.Curator.Result{
        summary: map["summary"] || "",
        facts: map["facts"] || [],
        tags: map["tags"] || [],
        importance: to_float(map["importance"]),
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
end

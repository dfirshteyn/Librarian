defmodule Librarian.Curator.LlamaCpp do
  @moduledoc """
  Curator backend that calls a local llama.cpp / Ollama server for
  real-time summarization and embedding.

  Supports separate URLs for chat and embedding, so you can run a large
  reasoning model on one port (e.g., 35B Qwen on :1234) and a dedicated
  embedding model on another (e.g., BGE-M3 on :1235). The embed function
  accepts an optional URL override — see `Librarian.Curator.Hybrid` for
  the wiring.

  Configure via:
      config :librarian, curator: Librarian.Curator.LlamaCpp

  Server URL (defaults to http://localhost:1234/v1):
      config :librarian, llama_cpp_url: "http://thinkpad.local:1234/v1"

  Embed URL (defaults to llama_cpp_url if not set):
      config :librarian, embed_url: "http://localhost:1235/v1"

  Model override (defaults to whatever llama.cpp has loaded):
      config :librarian, llama_cpp_model: "qwen2.5-1.5b-instruct"

  LeakGuard scrubbing happens in `Librarian.Curator.summarize/1` before
  this module is ever called — the chunk arriving here is already clean.
  """

  @behaviour Librarian.Curator

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
  def embed(text) when is_binary(text) do
    embed(text, [])
  end

  @doc """
  Embed text, optionally targeting a different URL than the default
  llama.cpp server. This allows using a dedicated embedding model
  (e.g., BGE-M3) running on a separate port.
  """
  def embed(text, opts) when is_binary(text) and is_list(opts) do
    {scrubbed, _} = Librarian.LeakGuard.scrub(text)
    url = Keyword.get(opts, :url, embed_url())

    body = %{
      "input" => scrubbed,
      "model" => model_name()
    }

    case Req.post(req(),
           url: "#{url}/embeddings",
           json: body,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        case get_in(resp_body, ["data", Access.at(0), "embedding"]) do
          vec when is_list(vec) ->
            {:ok, vec}

          _ ->
            {:error, :missing_embedding}
        end

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:api_error, status, resp_body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
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

    Respond with ONLY the JSON object, no markdown, no explanation.

    Notes:
    #{text}
    """
  end

  defp chat(prompt) do
    body = %{
      "model" => model_name(),
      "messages" => [%{"role" => "user", "content" => prompt}],
      "response_format" => %{"type" => "json_object"},
      "temperature" => 0.1,
      "max_tokens" => 512
    }

    case Req.post(req(),
           url: "#{base_url()}/chat/completions",
           json: body,
           receive_timeout: 120_000
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        {:ok, resp_body}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:api_error, status, resp_body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp base_url do
    Application.get_env(:librarian, :llama_cpp_url, "http://localhost:1234/v1")
  end

  defp embed_url do
    Application.get_env(:librarian, :embed_url, base_url())
  end

  defp model_name do
    Application.get_env(:librarian, :llama_cpp_model, "")
  end

  defp req do
    case Application.get_env(:librarian, :req_module) do
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

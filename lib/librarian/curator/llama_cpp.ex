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
      bucket = fallback_bucket(result.bucket, text)
      cleaned = %{result | facts: deduplicate_facts(result.facts, result.summary), bucket: bucket}
      {:ok, cleaned}
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
    You are a structural memory extraction daemon. Respond ONLY with a raw JSON object. Do not wrap the response in markdown, backticks, or markdown code fences (e.g. do not use ```json).

    <example>
    Input: The production database thrashed because the disk filled up to 100%. We need to set up Grafana metrics alerts before Friday.
    Output: {"summary": "Production database thrashed due to a saturated disk, requiring immediate alerts.", "facts": ["The database experienced a critical storage thrashing event.", "The root cause was the disk capacity reaching 100%.", "Grafana metrics alerts must be configured before Friday."], "tags": ["database", "storage", "alerts", "grafana"], "importance": 0.8, "bucket": "project"}
    </example>

    Rules:
    - summary: Exactly one sentence capturing the core technical decision, event, or observation.
    - facts: An array of 3-5 distinct, complete atomic sentences. Each fact MUST convey different information — never rephrase the same fact in different words. Do not invent facts not present in the input. Do not use placeholders.
    - tags: An array of 3-6 specific lowercase keywords. Strictly single words only, no spaces.
    - importance: A float between 0.0 and 1.0 based on operational priority.
    - bucket: Strictly choose one string from this list: ["project", "research", "ideas", "thoughts", "finance", "inbox"]. Use "inbox" only if no other category matches.

    CRITICAL: facts must each express a DIFFERENT piece of information. If the input only supports 2-3 distinct facts, return 2-3 — do not pad with rephrased duplicates.

    Input: #{text}
    Output:
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

  # When the model returns "inbox" (fallback) or an empty bucket, use
  # keyword-based classification as a safety net. The model's bucket is
  # trusted when valid; this only catches failures.
  defp fallback_bucket("inbox", text), do: Librarian.Router.classify_bucket(text)
  defp fallback_bucket("", text), do: Librarian.Router.classify_bucket(text)
  defp fallback_bucket(bucket, _text) when is_binary(bucket), do: bucket

  # Remove near-duplicate facts and any fact that merely rephrases the summary.
  # Small models tend to restate the same information 2-3 ways; this keeps
  # only the most informative distinct version of each fact.
  defp deduplicate_facts(facts, summary) when is_list(facts) and is_binary(summary) do
    facts
    |> Enum.reject(&(&1 == ""))
    |> Enum.reject(&similar_to_summary?(&1, summary))
    |> deduplicate_similar()
  end

  defp deduplicate_facts(other, _), do: other || []

  # Reject any fact that is essentially the summary restated.
  defp similar_to_summary?(fact, summary) do
    fact_words = tokenize(fact)
    summary_words = tokenize(summary)
    overlap = jaccard_similarity(fact_words, summary_words)
    overlap > 0.5
  end

  # Remove facts that are near-duplicates of each other (Jaccard > 0.6).
  # Keeps the longest (most informative) version of each cluster.
  defp deduplicate_similar(facts) do
    facts
    |> Enum.sort_by(&(-String.length(&1)))
    |> Enum.reduce([], fn fact, kept ->
      if Enum.any?(kept, &(jaccard_similarity(tokenize(&1), tokenize(fact)) > 0.6)) do
        kept
      else
        [fact | kept]
      end
    end)
    |> Enum.reverse()
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/u, " ")
    |> String.split()
    |> Enum.reject(&(&1 in ~w(the a an is was were be been to of in on at for with)))
  end

  defp jaccard_similarity(a, b) do
    set_a = MapSet.new(a)
    set_b = MapSet.new(b)
    intersection = MapSet.intersection(set_a, set_b) |> MapSet.size()
    union = MapSet.union(set_a, set_b) |> MapSet.size()
    if union == 0, do: 0.0, else: intersection / union
  end
end

defmodule Librarian.Council.Judge do
  @moduledoc """
  Council Judge - synthesizes persona perspectives into final structured output.

  This is a separate module from the deep-pass logic, allowing independent evolution
  and potential swapping to different models/providers.

  Note: The bucket in the output is advisory only - it does NOT automatically
  re-file memories. The original curator placement remains; bucket suggestions
  are purely informational.
  """

  @doc """
  Synthesize all persona perspectives into a final structured artifact.

  Takes the original content plus all persona takes and produces:
  - summary: distilled synthesis
  - facts: key facts from any perspective
  - tags: combined and deduplicated tags
  - importance: judged importance
  - bucket: advisory suggestion only (does NOT move files)
  - persona_perspectives: map of persona_name => take
  """
  @spec synthesize(String.t(), [{Librarian.Council.Persona.persona_type(), String.t()}]) ::
          {:ok, map()} | {:error, term()}
  def synthesize(content, persona_takes) when is_binary(content) and is_list(persona_takes) do
    # Build synthesis prompt
    takes_text =
      persona_takes
      |> Enum.map(fn {persona, take} ->
        "#{Librarian.Council.Persona.config(persona).name}:\n#{take}"
      end)
      |> Enum.join("\n\n---\n\n")

    prompt = """
    You are the Council Judge, synthesizing multiple analytical perspectives into a final, high-fidelity memory artifact.

    CRITICAL SAFETY & GROUNDING INSTRUCTIONS:
    1. STRICT FACTUAL ISOLATION: Evaluate all provided perspectives against the "Original context". If any perspective has fabricated external names, dates, historical origins, or proper nouns NOT explicitly found in the original context, you must completely reject and drop those fabrications.
    2. DISCOVERY OVER REPETITION: Do not simply echo the original text back. Highlight the structural tension or insights found by the analytical agents (e.g., if a contradiction was spotted by the Skeptic, or a literal parameter extracted by the Literalist).
    3. NO META-COMMENTARY: Do not include language like "Based on the perspectives provided..." or "The agents suggest...". Synthesize the analysis directly into absolute statements.

    Original context (for absolute grounding):
    #{content}

    Perspectives:
    #{takes_text}

    Return a JSON object with exactly this schema:
    {
      "summary": "A single concise sentence distilling the core structural synthesis, fully grounded in the original context.",
      "facts": ["Array of up to 8 atomic fact strings. Every fact MUST be explicitly verifiable against the original context alone."],
      "tags": ["3-6 lowercase semantic keyword strings covering the core themes."],
      "importance": 0.5, // float between 0.0 and 1.0 representing structural density
      "bucket": "inbox", // advisory suggestion matching exactly one of: "project", "research", "ideas", "thoughts", "finance", "inbox"
      "persona_perspectives": {
        "skeptic": "distilled take from the skeptic perspective",
        "structural_analyst": "distilled take from the structural_analyst perspective",
        "connector": "distilled take from the connector perspective",
        "literalist": "distilled take from the literalist perspective"
      }
    }

    Respond with ONLY the raw JSON object. Do not wrap in markdown blocks like ```json.
    """

    # Use ModelRouting for judge synthesis (Qwen Plus by default)
    {mod, model} = Librarian.ModelRouting.for(:council_judge)
    {scrubbed_prompt, _} = Librarian.LeakGuard.scrub(prompt)

    case mod.chat(scrubbed_prompt, temperature: 0.5, model: model, response_format: %{"type" => "json_object"}) do
      {:ok, body} ->
        parse_synthesis(body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_synthesis(body) do
    with content when is_binary(content) <-
           get_in(body, ["choices", Access.at(0), "message", "content"]),
         {:ok, map} <- Librarian.Json.decode(content) do
      {:ok,
       %{
         summary: map["summary"] || "",
         facts: map["facts"] || [],
         tags: map["tags"] || [],
         importance: to_float(map["importance"]),
         bucket: Librarian.Router.normalize_bucket(map["bucket"]),
         persona_perspectives: map["persona_perspectives"] || %{}
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

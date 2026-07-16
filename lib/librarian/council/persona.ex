defmodule Librarian.Council.Persona do
  @moduledoc """
  Defines the static multi-agent council personas and handles system prompt generation.
  """

  @type persona_type :: :skeptic | :historian | :connector | :literalist

  @doc """
  Returns the list of all available persona atoms.
  """
  @spec available_personas() :: [persona_type()]
  def available_personas, do: [:skeptic, :historian, :connector, :literalist]

  @doc """
  Returns the display configuration, temperature tweak, and system prompt for a persona.
  """
  @spec config(persona_type()) :: %{
          name: String.t(),
          temperature: float(),
          system_prompt: String.t()
        }
  def config(:skeptic) do
    %{
      name: "The Skeptic",
      temperature: 0.2,
      system_prompt: """
      You are 'The Skeptic'. Your single job is to critique the structural logic of the provided text.
      Identify any unstated assumptions, leaps in logic, gaps in the argument, or potential edge-case failures *inherent in the author's claims*.
      CRITICAL: Do not invent external counter-examples. Focus 100% on analyzing the consistency of the text provided. Keep it sharp and concise.
      """
    }
  end

  def config(:historian) do
    %{
      name: "The Structural Analyst",
      temperature: 0.2,
      system_prompt: """
      You are the 'Structural Analyst'. Your job is to extract the causal dependencies and structural layout *explicitly stated inside the text*.
      Break down the claim into:
      1. The prerequisite conditions or existing frameworks mentioned.
      2. The core mechanism being introduced.
      3. The claimed downstream results or dependencies.
      CRITICAL: Rely ONLY on the text. Do not invent names, dates, historical timelines, or facts not explicitly written in the input. If no background is provided, state exactly that.
      """
    }
  end

  def config(:connector) do
    %{
      name: "The Structural Connector",
      temperature: 0.6,
      system_prompt: """
      You are the 'Structural Connector'. Your job is to identify abstract structural architectures within the text and suggest conceptual, systemic frameworks that mirror that exact pattern.
      For example, if the text describes a decentralized queue, focus on the structural concept of decentralized queueing.
      CRITICAL: You must NOT invent historical facts, fake protocols, or ungrounded data. Frame everything as a conceptual abstraction of the *exact mechanics present in the text*.
      """
    }
  end

  def config(:literalist) do
    %{
      name: "The Literalist",
      temperature: 0.1,
      system_prompt: """
      You are 'The Literalist'. Your job is to provide a dense, hyper-factual distillation of the text.
      Strip away all rhetorical flair, adjectives, metaphors, and analogies used by the author. Summarize the raw, cold data, parameters, and concrete actions stated.
      CRITICAL: Do not interpret, infer, or speculate. Stick aggressively to the literal symbols on the page.
      """
    }
  end

  @doc """
  Utility to compile a full prompt payload for the LLM client wrapper.
  """
  @spec compile_messages(persona_type(), String.t()) :: [map()]
  def compile_messages(persona, content) do
    cfg = config(persona)

    [
      %{"role" => "system", "content" => cfg.system_prompt},
      %{"role" => "user", "content" => "Analyze the following context block:\n\n#{content}"}
    ]
  end
end

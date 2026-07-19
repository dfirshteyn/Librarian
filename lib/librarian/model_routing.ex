defmodule Librarian.ModelRouting do
  @moduledoc """
  Single source of truth mapping each app role to its backend module and model.

  This is the one place to look (and the one place to change) when you want to
  swap which model powers which part of the system. Every call site that needs
  a model reads from here — nothing else hardcodes a backend or model string.

  ## Hackathon demo pattern

  The HOT→WARM extraction path (`.6B` local model) is left untouched — it's
  governed by `Librarian.Curator.resolve_curator/2` for cost reasons. Everything
  else that previously ran on the 1.7B local model is routed here to Qwen's API
  so you can use your free 1M tokens and get better quality for the judges.

  To switch any role to a different backend, change only the tuple below:

      {Librarian.Curator.QwenApi, "qwen-turbo"}   → cloud, cheap, fast
      {Librarian.Curator.QwenApi, "qwen-plus"}     → cloud, bigger, better
      {Librarian.Curator.LlamaCpp, "qwen3.5-0.6b"} → local, free, limited
  """

  @doc """
  Returns `{module, model_identifier}` for the given role.

  The module implements `Librarian.Curator` behaviour (or at least provides
  `chat/2` and `summarize/1`). The model identifier is passed as the `:model`
  option to the module's functions.
  """
  @spec for(atom()) :: {module(), String.t()}
  def for(:council_persona), do: {Librarian.Curator.QwenApi, "qwen-turbo"}
  def for(:council_judge), do: {Librarian.Curator.QwenApi, "qwen-plus"}
  def for(:consolidation), do: {Librarian.Curator.QwenApi, "qwen-turbo"}
  def for(:deep_pass), do: {Librarian.Curator.QwenApi, "qwen-plus"}
end

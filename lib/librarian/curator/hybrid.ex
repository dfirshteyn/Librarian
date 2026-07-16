defmodule Librarian.Curator.Hybrid do
  @moduledoc """
  A meta-curator that dispatches to different backends depending on the
  operation:

    - `summarize/1` → `Librarian.Curator.LlamaCpp` (local, fast, free)
    - `embed/1`     → `Librarian.Curator.LlamaCpp` targeting a dedicated
                       embedding model (e.g., BGE-M3 on port 1235)
    - `deep_pass/1` → `Librarian.Curator.QwenApi`  (cloud, thorough, costs credits)

  This gives you the best of both worlds: real-time operations stay on
  your own hardware, while the scheduled nightly deep pass uses Qwen's
  full reasoning capacity for re-ranking, contradiction detection, and
  cross-memory "dreaming."

  Configure via:
      config :librarian, curator: Librarian.Curator.Hybrid

  Embed URL (defaults to llama_cpp_url if not set):
      config :librarian, embed_url: "http://localhost:1235/v1"

  The individual backends are configured separately — see their docs for
  URL, API key, and model settings.
  """

  @behaviour Librarian.Curator

  @doc """
  Summarize a chunk of payloads using the local LlamaCpp server.
  Fast, free, runs on your own hardware.
  """
  @impl true
  def summarize(chunk) when is_list(chunk) do
    Librarian.Curator.LlamaCpp.summarize(chunk)
  end

  @doc """
  Describe an image using the vision model endpoint.
  """
  @impl true
  def describe_image(image_data, opts) when is_binary(image_data) do
    Librarian.Curator.LlamaCpp.describe_image(image_data, opts)
  end

  @doc """
  Embed text using a dedicated embedding model server (e.g., BGE-M3).
  Configured via `config :librarian, embed_url:` — defaults to the
  same URL as llama_cpp_url if not set separately.
  """
  @impl true
  def embed(text) when is_binary(text) do
    embed_url = Application.get_env(:librarian, :embed_url)
    opts = if embed_url, do: [url: embed_url], else: []
    Librarian.Curator.LlamaCpp.embed(text, opts)
  end

  @doc """
  Deep reasoning pass — re-analyze all WARM memories using Qwen's full
  reasoning capacity. This is the "dreaming" phase: find connections the
  small model missed, re-classify borderline memories, detect latent
  contradictions, and suggest new tags or supersessions.

  Called by `Flusher.nightly_pass/1` on a schedule (not on the hot path).
  """
  def deep_pass(memories) do
    Librarian.Curator.QwenApi.deep_pass(memories)
  end
end

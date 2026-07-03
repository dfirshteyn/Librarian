defmodule Librarian.Curator.Result do
  @moduledoc "What a curator hands back after looking at a chunk of HOT payloads."

  defstruct [
    :summary,
    :facts,
    :tags,
    :importance,
    :embedding
  ]

  @type t :: %__MODULE__{
          # short distilled summary of the chunk
          summary: String.t(),
          # list of atomic extracted facts, e.g. ["User switched Project X from Postgres to SQLite"]
          facts: [String.t()],
          # tags for associative linking across buckets
          tags: [String.t()],
          # 0.0 - 1.0, used for decay/forgetting later
          importance: float(),
          # optional vector; nil if this curator backend doesn't do embeddings
          embedding: [float()] | nil
        }
end

defmodule Librarian.Curator do
  @moduledoc """
  The pluggable "model" boundary. This is the single seam where you swap:

    - `Librarian.Curator.Stub`      — zero-dependency heuristic curator (default, runs anywhere)
    - `Librarian.Curator.LlamaCpp`  — shells out to a local llama.cpp / Ollama server
    - `Librarian.Curator.QwenApi`   — hits Qwen's API for the nightly curation pass
    - `Librarian.Curator.Bumblebee` — in-BEAM embeddings via Bumblebee/EXLA

  Nothing else in the app should know which backend is active. Pick the
  backend via config:

      config :librarian, curator: Librarian.Curator.Stub

  and call `Librarian.Curator.summarize/1` / `embed/1`, which dispatch to
  whichever module is configured.
  """

  @callback summarize(chunk :: [Librarian.Capture.Payload.t()]) ::
              {:ok, Librarian.Curator.Result.t()} | {:error, term()}
  @callback embed(text :: String.t()) :: {:ok, [float()]} | {:error, term()}

  def summarize(chunk) do
    scrubbed_chunk = scrub_chunk(chunk)
    impl().summarize(scrubbed_chunk)
  end

  def embed(text) do
    {scrubbed, count} = Librarian.LeakGuard.scrub(text)
    if count > 0 do
      require Logger
      Logger.warning("LeakGuard: redacted #{count} secret(s) before embedding")
    end
    impl().embed(scrubbed)
  end

  # Scrub each payload's raw_text before handing the chunk to any backend.
  # The original text in HOT/WARM/COLD is untouched — redaction only
  # applies to what the curator (potentially a remote API) receives.
  defp scrub_chunk(chunk) do
    Enum.map(chunk, fn payload ->
      {scrubbed, count} = Librarian.LeakGuard.scrub(payload.raw_text)
      if count > 0 do
        require Logger
        Logger.warning("LeakGuard: redacted #{count} secret(s) from #{payload.source} payload before curator")
      end
      %{payload | raw_text: scrubbed}
    end)
  end

  defp impl, do: Application.get_env(:librarian, :curator, Librarian.Curator.Stub)
end

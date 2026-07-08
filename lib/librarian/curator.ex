defmodule Librarian.Curator.Result do
  @moduledoc "What a curator hands back after looking at a chunk of HOT payloads."

  defstruct [
    :summary,
    :facts,
    :tags,
    :importance,
    :bucket,
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
          # bare bucket name (e.g. "project") the curator assigned. The Flusher
          # namespaces this as "user_id:bucket" when writing to WARM. Defaults
          # to "inbox" in every backend.
          bucket: String.t(),
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

  def summarize(chunk, curator_impl \\ nil) do
    impl = curator_impl || impl()
    scrubbed_chunk = scrub_chunk(chunk)
    impl.summarize(scrubbed_chunk)
  end

  def embed(text, curator_impl \\ nil) do
    impl = curator_impl || impl()
    {scrubbed, count} = Librarian.LeakGuard.scrub(text)

    if count > 0 do
      require Logger
      Logger.warning("LeakGuard: redacted #{count} secret(s) before embedding")
    end

    impl.embed(scrubbed)
  end

  # Scrub each payload's raw_text before handing the chunk to any backend.
  # The original text in HOT/WARM/COLD is untouched — redaction only
  # applies to what the curator (potentially a remote API) receives.
  defp scrub_chunk(chunk) do
    Enum.map(chunk, fn payload ->
      {scrubbed, count} = Librarian.LeakGuard.scrub(payload.raw_text)

      if count > 0 do
        require Logger

        Logger.warning(
          "LeakGuard: redacted #{count} secret(s) from #{payload.source} payload before curator"
        )
      end

      %{payload | raw_text: scrubbed}
    end)
  end

  defp impl, do: Application.get_env(:librarian, :curator, Librarian.Curator.Stub)

  @doc """
  Resolve which curator backend to use for a given user_id.

  Implements the hackathon "judge account" pattern:
    - Any user_id prefixed with `judge_` is routed to the premium Alibaba
      Cloud Qwen API (the real deep-reasoning model).
    - Everyone else (anon_, free tier) is routed to the local model so
      the cloud bill stays near zero.

  A dashboard toggle (`force_local: true`) lets anyone opt into the local
  model even if they'd otherwise qualify for cloud — mostly for demos that
  want to show the speed/clarity difference side-by-side.

  This is the single seam for tier routing. Both the flusher/recall path
  and the consolidator's re-curation pass call through here so judges and
  free users get materially different quality without any duplicated logic.
  """
  @judge_prefix "judge_"

  def resolve_curator(user_id, opts \\ []) when is_binary(user_id) do
    cond do
      opts[:force_local] == true ->
        Librarian.Curator.LlamaCpp

      String.starts_with?(user_id, @judge_prefix) ->
        Librarian.Curator.QwenApi

      true ->
        Application.get_env(:librarian, :free_tier_curator, Librarian.Curator.LlamaCpp)
    end
  end

  @doc "True if the user_id is a reserved judge account (premium cloud tier)."
  def judge?(user_id) when is_binary(user_id), do: String.starts_with?(user_id, @judge_prefix)
end

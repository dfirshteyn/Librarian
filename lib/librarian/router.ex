defmodule Librarian.Router do
  @moduledoc """
  The "gating" layer for ingest-time namespacing.

  HOT is a staging buffer, not a classifier: `route/2` now assigns every
  payload to `"user_id:inbox"` so the HOT bucket name is purely a per-user
  namespace. The *semantic* bucket decision happens later, at flush time,
  when the configured curator (a real model in production, a deterministic
  keyword fallback in tests) returns a `bucket` field on its `Curator.Result`.

  This avoids the old bug where a keyword matched at ingest baked the wrong
  bucket into the ETS key and the curator's semantic decision was silently
  discarded.

  The keyword classifier is still available as `classify_bucket/1` for the
  Stub curator (fast, deterministic, no network) — production backends ask
  the model to decide the bucket instead of reusing keywords.
  """

  @default_rules [
    {"project", ~w(project repo codebase deploy deployment elixir genserver
                    bug refactor feature shipped pullrequest wal daemon
                    leakguard hotstore warmstore flusher websocket extension)},
    {"research", ~w(paper research study benchmark architecture comparison
                      survey arxiv ebbinghaus spaced retrieval transformer
                      embedding cosine vector rag beam llama)},
    {"ideas", ~w(idea brainstorm concept hackathon what if could)},
    {"thoughts", ~w(feeling thinking wonder wondering honestly)},
    {"finance", ~w(invoice billing payment subscription budget finance
                    cost price cloud alibaba qwen coupon token spend)}
  ]

  @doc """
  Ingest-time namespacing only. Returns `{bucket, hint_tags}` where bucket
  is either `"user_id:target_bucket"` (if explicitly specified) or
  `"user_id:inbox"` (default staging buffer). Classification to the
  semantic bucket is deferred to the curator at flush time, unless
  target_bucket is pre-assigned.
  """
  def route(%Librarian.Capture.Payload{} = payload, user_id \\ "local") do
    hints = Enum.map(payload.hint_tags, &String.downcase/1)

    bucket =
      if payload.target_bucket do
        normalized = normalize_bucket(payload.target_bucket, user_id)
        "#{user_id}:#{normalized}"
      else
        "#{user_id}:inbox"
      end

    {bucket, hints}
  end

  @doc """
  Deterministic keyword classifier used by the Stub curator (tests, no
  network). Returns a bare bucket name from the default set, defaulting to
  `"inbox"` when nothing matches. Word-boundary matching only — "we" must
  not match inside "weather" (a real bug we fixed long ago).
  """
  def classify_bucket(text) when is_binary(text) do
    lowered = String.downcase(text)

    scored =
      rules()
      |> Enum.map(fn {bucket, keywords} ->
        matched = Enum.filter(keywords, &word_match?(lowered, &1))
        {bucket, length(matched)}
      end)
      |> Enum.reject(fn {_bucket, n} -> n == 0 end)
      |> Enum.sort_by(fn {_bucket, n} -> -n end)

    case scored do
      [{bucket, _} | _] -> bucket
      [] -> "inbox"
    end
  end

  @doc """
  Validate/normalize a curator-provided bucket name against the user's
  active bucket list. Unknown values fall back to "inbox".
  """
  def normalize_bucket(name, user_id \\ "local")

  def normalize_bucket(name, user_id) when is_binary(name) do
    bare = name |> String.downcase() |> String.trim()

    if bare in Librarian.ColdStore.valid_bucket_names(user_id) do
      bare
    else
      "inbox"
    end
  end

  def normalize_bucket(_, _user_id), do: "inbox"

  # Word-boundary match, not raw substring — "we" must not match inside
  # "weather", "i" must not match inside "nothing". This was a real bug
  # caught by the test suite, not a hypothetical one.
  defp word_match?(text, keyword) do
    Regex.match?(~r/\b#{Regex.escape(keyword)}\b/, text)
  end

  defp rules, do: Application.get_env(:librarian, :router_rules, @default_rules)
end

defmodule Librarian.Router do
  @moduledoc """
  The "gating" layer. Cheap keyword/pattern rules decide which bucket a
  payload likely belongs to *before* any embedding work happens — same
  idea as MoE routing, just deterministic instead of learned, because
  deterministic is free and instant.

  Buckets are configurable; falls back to `"inbox"` (the random/uncategorized
  bucket) when nothing matches, rather than ever blocking on classification.
  """

  @default_rules [
    {"project", ~w(project repo codebase deploy deployment elixir genserver
                    bug refactor feature shipped pullrequest wal daemon
                    leakguard hotstore warmstore flusher websocket extension)},
    {"research", ~w(paper research study benchmark architecture comparison
                     survey arxiv ebbinghaus spaced retrieval transformer
                     embedding cosine vector rag beam bumblebee llama)},
    {"ideas", ~w(idea brainstorm concept hackathon what if could)},
    {"thoughts", ~w(feeling thinking wonder wondering honestly)},
    {"finance", ~w(invoice billing payment subscription budget finance
                    cost price cloud alibaba qwen coupon token spend)}
  ]

  @doc """
  Returns `{bucket, matched_tags}` where bucket is namespaced as
  "user_id:bucket_name" — different users' processes never collide in
  the Registry or DynamicSupervisor.
  """
  def route(%Librarian.Capture.Payload{} = payload, user_id \\ "local") do
    text = String.downcase(payload.raw_text)
    hints = Enum.map(payload.hint_tags, &String.downcase/1)

    scored =
      rules()
      |> Enum.map(fn {bucket, keywords} ->
        matched = Enum.filter(keywords, &word_match?(text, &1))
        {bucket, matched}
      end)
      |> Enum.reject(fn {_bucket, matched} -> matched == [] end)
      |> Enum.sort_by(fn {_bucket, matched} -> -length(matched) end)

    {raw_bucket, tags} =
      case scored do
        [{bucket, matched} | _] -> {bucket, Enum.uniq(matched ++ hints)}
        [] -> {"inbox", hints}
      end

    {"#{user_id}:#{raw_bucket}", tags}
  end

  # Word-boundary match, not raw substring — "we" must not match inside
  # "weather", "i" must not match inside "nothing". This was a real bug
  # caught by the test suite, not a hypothetical one.
  defp word_match?(text, keyword) do
    Regex.match?(~r/\b#{Regex.escape(keyword)}\b/, text)
  end

  defp rules, do: Application.get_env(:librarian, :router_rules, @default_rules)
end

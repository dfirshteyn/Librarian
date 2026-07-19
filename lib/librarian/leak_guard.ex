defmodule Librarian.LeakGuard do
  @moduledoc """
  Scrubs high-confidence secrets from payload text before it ever crosses
  a network boundary (i.e., before `Curator.QwenApi` or any other remote
  backend touches it), AND before it's persisted to the HOT tier WAL.

  The WAL is the event-sourcing / audit-trail layer — scrubbing happens
  there so the persisted canonical record is clean, while the transient
  HOT ETS copy stays unscrubbed for in-memory performance. On crash
  recovery, WAL replay reconstructs ETS from the scrubbed copy, so
  ancestry and downstream tiers (WARM, COLD, council, public graph)
  all inherit the clean version.

  Deliberately zero-dependency and synchronous — no process overhead for
  something that runs on every outbound payload. The regex list covers
  the patterns that show up most often in raw AI chat exports (API keys,
  bearer tokens, DB connection strings, private keys, env-var assignments
  containing secrets). It is NOT comprehensive — a dedicated secrets
  scanner (trufflehog, gitleaks) would catch more — but it covers the
  common cases a judge will think to test and that a real user will
  accidentally paste.

  Each pattern emits a labelled `[REDACTED_<TYPE>]` placeholder so the
  model still knows *something* was there (e.g., a bearer token was
  present in a curl command) without receiving the value.
  """

  @patterns [
    # OpenAI / Anthropic / generic sk- keys
    {:api_key, ~r/\b(sk-[a-zA-Z0-9]{20,})/},
    # AWS access key IDs
    {:aws_access_key, ~r/\b(AKIA[0-9A-Z]{16})\b/},
    # AWS secret access keys (40 hex/base64 chars after known context words)
    {:aws_secret, ~r/(aws_secret_access_key\s*[=:]\s*)([A-Za-z0-9+\/]{40})/i},
    # Generic bearer tokens
    {:bearer_token, ~r/\b(Bearer\s+[A-Za-z0-9\-._~+\/]+=*)/i},
    # Database connection URLs
    {:db_url, ~r/((?:postgres|mysql|mongodb|redis|sqlite):\/\/[^\s"'<>\]]+)/i},
    # Private key blocks (PEM format)
    {:private_key,
     ~r/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----.*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/s},
    # GitHub personal access tokens
    {:github_token, ~r/\b(gh[pousr]_[A-Za-z0-9]{36,})\b/},
    # Generic password= / token= / secret= / api_key= assignments in env/config
    {:env_secret,
     ~r/\b(password|token|secret|api_key|apikey|auth_token)\s*[=:]\s*["']?([^\s"'<>\n]{8,})["']?/i}
  ]

  @doc """
  Returns `{scrubbed_text, redaction_count}`. If `redaction_count` is
  zero, the text was clean and you can skip logging the scrub event.

  Called internally by `Librarian.Wal.append/2` before writing to disk,
  and by curator backends before sending to remote APIs. The transient
  HOT ETS copy intentionally stays unscrubbed for performance.
  """
  def scrub(nil), do: {nil, 0}
  def scrub(text) when is_binary(text) do
    Enum.reduce(@patterns, {text, 0}, fn {type, pattern}, {acc_text, count} ->
      label = "[REDACTED_#{type |> Atom.to_string() |> String.upcase()}]"

      # Patterns with a capture group for a prefix (e.g. aws_secret, env_secret)
      # only replace the captured secret value, not the key name — so the
      # model still knows "aws_secret_access_key was set to something."
      {new_text, matches} = do_replace(pattern, acc_text, label, type)
      {new_text, count + matches}
    end)
  end

  @doc "Convenience wrapper: returns just the scrubbed string."
  def scrub!(text), do: scrub(text) |> elem(0)

  @doc "True if the text contains any pattern we'd redact."
  def contains_secret?(nil), do: false
  def contains_secret?(text) do
    Enum.any?(@patterns, fn {_type, pattern} -> Regex.match?(pattern, text) end)
  end

  # Patterns with two capture groups: keep group 1, redact group 2.
  defp do_replace(pattern, text, label, type) when type in [:aws_secret, :env_secret] do
    matches =
      Regex.scan(pattern, text)
      |> length()

    replaced = Regex.replace(pattern, text, fn _, prefix, _secret -> prefix <> label end)
    {replaced, matches}
  end

  # All other patterns: replace the whole match.
  defp do_replace(pattern, text, label, _type) do
    matches = Regex.scan(pattern, text) |> length()
    replaced = Regex.replace(pattern, text, label)
    {replaced, matches}
  end
end

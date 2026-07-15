defmodule Librarian.Auth do
  @moduledoc """
  Stateless sandbox authentication using `Phoenix.Token` HMAC signing.

  Every request resolves to a *verified claim*:
    - `%{sid: sandbox_id, tier: tier}`

  Where `sandbox_id` is the plaintext identifier and `tier` is one of
  `:anon` (free, local model) or `:judge` (premium cloud model). The tier
  is part of the signed payload, so it cannot be spoofed by a client — a
  user can never upgrade themselves to the paid tier just by editing a URL.

  Sandbox IDs:
    - **Anonymous users** get `anon_<random_hex>` — ephemeral, no registration
    - **Judge accounts** get `judge_<random_hex>` — premium tier, GC-whitelisted,
      minted *only* server-side (see `generate_judge_id/0`). Never derivable
      from user-supplied input.

  Tokens are `Phoenix.Token` HMAC-SHA256 signed blobs. They're stateless,
  impossible to forge, and can travel via cookie or Bearer header.
  """

  @salt "sandbox"
  @anon_prefix "anon_"
  @judge_prefix "judge_"
  @default_budget 1000
  @judge_budget 10_000

  # ── Token signing / verification ─────────────────────────────────────

  @doc """
  Sign a `%{sid: sandbox_id, tier: tier}` claim into an opaque HMAC token.

  Returns a signed binary string. Uses `Phoenix.Token.sign/4` under the hood
  with the configured endpoint's secret_key_base.
  """
  def sign(claim, opts \\ []) when is_map(claim) do
    max_age = Access.get(opts, :max_age, 86_400) # 24 hours default
    Phoenix.Token.sign(LibrarianWeb.Endpoint, @salt, claim, max_age: max_age)
  end

  @doc """
  Verify a token and extract the claim map.

  Returns `{:ok, %{sid: sandbox_id, tier: tier}}` on success,
  `{:error, reason}` if the token is expired, malformed, or tampered with.
  """
  def verify(token, opts \\ []) when is_binary(token) do
    max_age = Access.get(opts, :max_age, 86_400)

    case Phoenix.Token.verify(LibrarianWeb.Endpoint, @salt, token, max_age: max_age) do
      {:ok, %{sid: sid, tier: tier} = claim} when is_binary(sid) and is_atom(tier) ->
        {:ok, claim}

      {:ok, other} ->
        # Reject legacy/ill-formed payloads — never trust an unsigned claim shape.
        {:error, {:invalid_claim, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Sandbox ID generation ────────────────────────────────────────────

  @doc """
  Generate a new anonymous sandbox ID.

  Format: `anon_` + 16 bytes of random hex (32 hex chars).
  Example: `anon_a1b2c3d4e5f6789012345678abcdef01`
  """
  def generate_anon_id do
    @anon_prefix <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  @doc """
  Generate a new judge sandbox ID. **Server-side only.**

  Format: `judge_` + 16 bytes of random hex. These are never derived from
  user input — only minted by the deploy seed / judge-link helper — so the
  premium tier is not self-serviceable.
  """
  def generate_judge_id do
    @judge_prefix <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  @doc """
  Build a fresh anon claim map (the default for new visitors).
  """
  def new_anon_claim do
    %{sid: generate_anon_id(), tier: :anon}
  end

  @doc """
  Generate a fresh judge claim map (premium tier). Server-side only.
  """
  def new_judge_claim do
    %{sid: generate_judge_id(), tier: :judge}
  end

  @doc """
  Mint a shareable judge "VIP" link token (server-side only).

  Returns a signed HMAC token that, when passed as `?tid=<token>` to the
  dashboard, verifies as a premium `:judge` claim. Because the tier lives
  *inside* the signed payload, a hand-edited `?tid=judge_xxx` (or any value
  that isn't a validly signed token) fails `verify/1` and silently falls back
  to an anonymous sandbox — so this is a safe, non-spoofable "if you know, you
  know" demo gate.

  Generate this at deploy time (e.g. in an IEx helper or a seed script) and
  hand the resulting `?tid=...` URL to judges. Never derive it from user input.
  """
  def sign_judge_link do
    sign(new_judge_claim())
  end

  # ── Sandbox classification ──────────────────────────────────────────

  @doc "Returns true if this sandbox_id is an anonymous (unregistered) user."
  def anon?(sandbox_id) when is_binary(sandbox_id) do
    String.starts_with?(sandbox_id, @anon_prefix)
  end

  @doc "Returns true if this sandbox_id is a judge account (premium cloud tier)."
  def judge?(sandbox_id) when is_binary(sandbox_id) do
    String.starts_with?(sandbox_id, @judge_prefix)
  end

  @doc """
  Returns true if this sandbox should be whitelisted from aggressive GC.

  Judge accounts are whitelisted — their .db files and connections are
  kept alive even during memory pressure or nightly GC sweeps.
  """
  def gc_whitelisted?(sandbox_id) when is_binary(sandbox_id) do
    judge?(sandbox_id)
  end

  # ── Budget helpers ──────────────────────────────────────────────────

  @doc "Default daily request budget for a given sandbox_id."
  def default_budget(sandbox_id) when is_binary(sandbox_id) do
    if judge?(sandbox_id), do: @judge_budget, else: @default_budget
  end

  # ── Plug-compatible extraction ───────────────────────────────────────

  @doc """
  Extract a verified claim from a token string (from cookie, header, or
  signed judge link).

  Returns `{claim, token}` on success, or generates a new anonymous claim
  with `{new_claim, new_token}` if the token was missing/invalid.

  `claim` is always a `%{sid: sandbox_id, tier: tier}` map — never a bare
  sandbox_id — so downstream code receives an authenticated tier.
  """
  def extract_or_generate(nil) do
    claim = new_anon_claim()
    token = sign(claim)
    {claim, token}
  end

  def extract_or_generate(token) when is_binary(token) do
    case verify(token) do
      {:ok, claim} ->
        {claim, token}

      {:error, _reason} ->
        claim = new_anon_claim()
        new_token = sign(claim)
        {claim, new_token}
    end
  end
end

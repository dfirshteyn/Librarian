defmodule Librarian.Auth do
  @moduledoc """
  Stateless sandbox authentication using `Phoenix.Token` HMAC signing.

  Every request gets an opaque `sandbox_id`:
    - **Anonymous users** get `anon_<random_hex>` — ephemeral, no registration
    - **Judge accounts** get `judge_devpost_<something>` — premium tier, GC-whitelisted

  Tokens are `Phoenix.Token` HMAC-SHA256 signed blobs. They're stateless,
  impossible to forge, and can travel via cookie or Bearer header.

  The `sandbox_id` is the *plaintext identifier*. The token is the signed
  credential that proves the bearer is authorized to use that sandbox_id.
  """

  @salt "sandbox"
  @anon_prefix "anon_"
  @judge_prefix "judge_devpost_"
  @default_budget 1000
  @judge_budget 10_000

  # ── Token signing / verification ─────────────────────────────────────

  @doc """
  Sign a `sandbox_id` into an opaque HMAC token.

  Returns a signed binary string. Uses `Phoenix.Token.sign/4` under the hood
  with the configured endpoint's secret_key_base.
  """
  def sign(sandbox_id, opts \\ []) when is_binary(sandbox_id) do
    max_age = Access.get(opts, :max_age, 86_400) # 24 hours default
    Phoenix.Token.sign(LibrarianWeb.Endpoint, @salt, sandbox_id, max_age: max_age)
  end

  @doc """
  Verify a token and extract the `sandbox_id`.

  Returns `{:ok, sandbox_id}` on success, `{:error, reason}` if the token
  is expired, malformed, or has been tampered with.
  """
  def verify(token, opts \\ []) when is_binary(token) do
    max_age = Access.get(opts, :max_age, 86_400)
    Phoenix.Token.verify(LibrarianWeb.Endpoint, @salt, token, max_age: max_age)
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

  # ── Sandbox classification ──────────────────────────────────────────

  @doc "Returns true if this sandbox_id is an anonymous (unregistered) user."
  def anon?(sandbox_id) when is_binary(sandbox_id) do
    String.starts_with?(sandbox_id, @anon_prefix)
  end

  @doc "Returns true if this sandbox_id is a judge Devpost account."
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
  Extract the sandbox_id from a token string (from cookie or header).

  Returns `{sandbox_id, token}` on success, or generates a new anonymous
  one with `{new_sandbox_id, new_token}` if the token was missing/invalid.
  """
  def extract_or_generate(nil) do
    sandbox_id = generate_anon_id()
    token = sign(sandbox_id)
    {sandbox_id, token}
  end

  def extract_or_generate(token) when is_binary(token) do
    case verify(token) do
      {:ok, sandbox_id} ->
        {sandbox_id, token}

      {:error, _reason} ->
        sandbox_id = generate_anon_id()
        new_token = sign(sandbox_id)
        {sandbox_id, new_token}
    end
  end
end

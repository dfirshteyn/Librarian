defmodule Librarian.Auth.Plug do
  @moduledoc """
  Plug for sandbox authentication via `Phoenix.Token`.

  ## Behaviour

  1. Look for a token in order:
     - `x-sandbox-token` HTTP header
     - `sandbox_token` cookie
     - `?tid=` query param — ONLY accepted if it verifies as a signed token
       (used for the shareable "judge link"; a hand-edited or forged value
       simply fails verification and falls back to an anonymous sandbox).
  2. If a valid token is found:
     - Extract the verified `%{sid: sandbox_id, tier: tier}` claim
     - Set `conn.assigns.sandbox_id` and `conn.assigns.tier`
  3. If no token or invalid token:
     - Generate a new anonymous claim via `Librarian.Auth.new_anon_claim/0`
     - Sign a new token
     - Set the token as a cookie
     - Set `conn.assigns.sandbox_id` / `conn.assigns.tier`
  4. In the browser pipeline, persist the claim to the session so the
     LiveView `mount/3` (which does not inherit `conn.assigns`) can read a
     stable, forge-proof identity across refreshes.
  5. Touch the manifest (`Librarian.Auth.Manifest.touch/1`) to track last_active_at

  ## Cookie Configuration

  Controlled by application env under `:librarian, :auth_plug`:

      config :librarian, :auth_plug,
        cookie_key: "sandbox_token",
        cookie_opts: [max_age: 86_400, http_only: true, same_site: :lax]

  Default cookie is `sandbox_token`, secure in prod, HTTP-only, Lax SameSite.

  The `?tid=` param is never trusted as a raw identity — it is only ever
  treated as a signed token. This closes the old hole where anyone could
  type `?tid=judge_xxx` and mint a privileged account or hijack another
  user's namespace.
  """

  @default_cookie_key "sandbox_token"
  @default_cookie_max_age 86_400 # 24 hours
  @query_param "tid"

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # 1. Extract token from header, cookie, or signed query param
    token = extract_token(conn)

    # 2. Resolve claim (validate or generate new)
    {claim, signed_token, is_new} = resolve_claim(token)

    sandbox_id = claim.sid
    tier = claim.tier

    # 3. Set assigns
    conn =
      conn
      |> assign(:sandbox_id, sandbox_id)
      |> assign(:tier, tier)
      |> assign(:gc_whitelisted, Librarian.Auth.gc_whitelisted?(sandbox_id))

    # 4. If a new token was generated, set the cookie
    conn =
      if is_new do
        cookie_key = cookie_config(:cookie_key, @default_cookie_key)
        cookie_opts = cookie_opts(sandbox_id)
        put_resp_cookie(conn, cookie_key, signed_token, cookie_opts)
      else
        conn
      end

    # 5. Persist the verified claim to the session for browser/LiveView use.
    #    (LiveView mount/3 receives the session, not conn.assigns.)
    conn =
      if fetch_session?(conn) do
        conn
        |> put_session(:sandbox_id, sandbox_id)
        |> put_session(:tier, tier)
      else
        conn
      end

    # 6. Touch the manifest regardless
    Librarian.Auth.Manifest.touch(sandbox_id)

    conn
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp extract_token(conn) do
    # Check header first
    case get_req_header(conn, "x-sandbox-token") do
      [token | _] when byte_size(token) > 0 ->
        token

      _ ->
        # Fall back to cookie
        cookie_key = cookie_config(:cookie_key, @default_cookie_key)

        case fetch_cookies(conn).req_cookies[cookie_key] do
          nil -> nil
          cookie_val when byte_size(cookie_val) > 0 -> cookie_val
          _ -> nil
        end
    end
    # NOTE: ?tid= is intentionally NOT treated as a raw identity. The browser
    # pipeline lets the signed token also arrive as ?tid=, but it still must
    # pass Librarian.Auth.verify/1 — handled in resolve_claim/1 below. Here we
    # only pull a token-shaped ?tid= value; verification is what matters.
    |> then(fn
      nil ->
        case fetch_query_params(conn) do
          %{query_params: %{@query_param => tid}} when is_binary(tid) and byte_size(tid) > 0 ->
            tid

          _ ->
            nil
        end

      tok ->
        tok
    end)
  end

  # Returns {claim, signed_token, is_new_token}
  defp resolve_claim(nil) do
    claim = Librarian.Auth.new_anon_claim()
    token = Librarian.Auth.sign(claim)
    {claim, token, true}
  end

  defp resolve_claim(token) when is_binary(token) do
    case Librarian.Auth.verify(token) do
      {:ok, claim} ->
        {claim, token, false}

      {:error, _reason} ->
        claim = Librarian.Auth.new_anon_claim()
        new_token = Librarian.Auth.sign(claim)
        {claim, new_token, true}
    end
  end

  # Whether the connection has a session fetched (browser pipeline only).
  # The :browser pipeline plugs :fetch_session before this plug, so put_session
  # is safe there. The :api pipeline does NOT fetch a session, so attempting
  # put_session would raise — guard with a try/rescue to stay pipeline-agnostic.
  defp fetch_session?(conn) do
    try do
      get_session(conn, :sandbox_probe_unused)
      true
    rescue
      _ -> false
    end
  end

  defp cookie_opts(_sandbox_id) do
    base = [
      max_age: cookie_config(:max_age, @default_cookie_max_age),
      http_only: true,
      same_site: "lax"
    ]

    if Mix.env() == :prod do
      Keyword.put(base, :secure, true)
    else
      base
    end
  end

  defp cookie_config(key, default) do
    Application.get_env(:librarian, :auth_plug, %{})
    |> Map.get(key, default)
  end
end

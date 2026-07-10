defmodule Librarian.Auth.Plug do
  @moduledoc """
  Plug for sandbox authentication via `Phoenix.Token`.

  ## Behaviour

  1. Look for a token in order:
     - `x-sandbox-token` HTTP header
     - `sandbox_token` cookie
  2. If a valid token is found:
     - Extract the `sandbox_id` via `Librarian.Auth.verify/1`
     - Set `conn.assigns.sandbox_id`
     - Set `conn.assigns.gc_whitelisted` for judge accounts
  3. If no token or invalid token:
     - Generate a new anonymous sandbox_id via `Librarian.Auth.generate_anon_id/0`
     - Sign a new token
     - Set the token as a cookie
     - Set `conn.assigns.sandbox_id`
  4. Touch the manifest (`Librarian.Auth.Manifest.touch/1`) to track last_active_at

  ## Cookie Configuration

  Controlled by application env under `:librarian, :auth_plug`:

      config :librarian, :auth_plug,
        cookie_key: "sandbox_token",
        cookie_opts: [max_age: 86_400, http_only: true, same_site: :lax]

  Default cookie is `sandbox_token`, secure in prod, HTTP-only, Lax SameSite.
  """

  @default_cookie_key "sandbox_token"
  @default_cookie_max_age 86_400 # 24 hours

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # 1. Extract token from header or cookie
    token = extract_token(conn)

    # 2. Resolve sandbox_id (validate or generate new)
    {sandbox_id, signed_token, is_new} = resolve_sandbox(token)

    # 3. Set assigns
    conn =
      conn
      |> assign(:sandbox_id, sandbox_id)
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

    # 5. Touch the manifest regardless
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
  end

  # Returns {sandbox_id, signed_token, is_new_token}
  defp resolve_sandbox(nil) do
    sandbox_id = Librarian.Auth.generate_anon_id()
    token = Librarian.Auth.sign(sandbox_id)
    {sandbox_id, token, true}
  end

  defp resolve_sandbox(token) when is_binary(token) do
    case Librarian.Auth.verify(token) do
      {:ok, sandbox_id} ->
        {sandbox_id, token, false}

      {:error, _reason} ->
        sandbox_id = Librarian.Auth.generate_anon_id()
        new_token = Librarian.Auth.sign(sandbox_id)
        {sandbox_id, new_token, true}
    end
  end

  defp cookie_opts(_sandbox_id) do
    base = [
      max_age: cookie_config(:max_age, @default_cookie_max_age),
      http_only: true,
      same_site: :lax
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

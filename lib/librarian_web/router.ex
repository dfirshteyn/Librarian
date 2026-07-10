defmodule LibrarianWeb.Router do
  use LibrarianWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {LibrarianWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(Librarian.Auth.Plug)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(:check_rate)
    plug(Librarian.Auth.Plug)
  end

  # Rate limiter plug — 100 req/min per IP+tenant pair, burst to 200
  defp check_rate(conn, _opts) do
    user_id =
      case Plug.Conn.get_req_header(conn, "x-user-id") do
        [id | _] when byte_size(id) > 0 -> id
        _ -> "local"
      end

    key = "#{:inet.ntoa(conn.remote_ip)}:#{user_id}"

    case Librarian.RateLimiter.allow?(key) do
      :ok ->
        conn

      {:error, :rate_limited} ->
        conn
        |> send_resp(429, ~s/{"error":"rate limit exceeded","retry_after_ms":60000}/)
        |> halt()
    end
  end

  scope "/", LibrarianWeb do
    pipe_through(:browser)
    live("/", DashboardLive, :index)
  end

  scope "/api", LibrarianWeb do
    pipe_through(:api)
    post("/ingest", ApiController, :ingest)
    post("/flush", ApiController, :flush)
    get("/recall", ApiController, :recall)
    get("/status", ApiController, :status)
    get("/export", ApiController, :export)
    get("/health/curator", ApiController, :curator_health)
  end
end

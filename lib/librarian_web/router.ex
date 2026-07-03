defmodule LibrarianWeb.Router do
  use LibrarianWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LibrarianWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", LibrarianWeb do
    pipe_through :browser
    live "/", DashboardLive, :index
  end

  scope "/api", LibrarianWeb do
    pipe_through :api
    post "/ingest", ApiController, :ingest
    get  "/recall", ApiController, :recall
    get  "/status", ApiController, :status
  end
end

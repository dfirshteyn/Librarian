import Config

config :librarian,
  start_ws_server: Mix.env() != :test,
  ws_port: 4001,
  decay_policies: %{
    "project" => :supersede,
    "research" => :supersede,
    "finance" => :supersede
  },
  default_decay_policy: :decay

# Ecto repo
config :librarian, Librarian.Repo,
  database: "librarian_#{Mix.env()}"

config :librarian, ecto_repos: [Librarian.Repo]

# Phoenix endpoint
config :librarian, LibrarianWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LibrarianWeb.ErrorHTML, json: LibrarianWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Librarian.PubSub,
  live_view: [signing_salt: "librarian_lv"]

# Esbuild
config :esbuild,
  version: "0.17.11",
  librarian: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Tailwind
config :tailwind,
  version: "3.4.0",
  librarian: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

import_config "#{config_env()}.exs"

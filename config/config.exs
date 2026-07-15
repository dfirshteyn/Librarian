import Config

config :librarian,
   start_ws_server: Mix.env() != :test,
   ws_port: 4001,
   embedding_dimensions: 1024,
   decay_policies: %{
     "project" => :supersede,
     "research" => :supersede,
     "finance" => :supersede
   },
   default_decay_policy: :decay,
   db_dir: "priv/data",
   sqlite_vec_path: "/usr/lib/sqlite-vec/vec0.so",
   ingest: [
     chunk_size: 350,
     chunk_overlap: 50,
     large_text_threshold: 1500
   ],
   parallel_flush_max_concurrency: 1,
   max_buckets_per_user: 30,
   system_buckets: ["inbox"]

# Ecto repo
config :librarian, Librarian.Repo, database: "priv/data/librarian_#{Mix.env()}.db"

config :librarian, ecto_repos: [Librarian.Repo, Librarian.PublicRepo]

# PublicRepo uses a separate migrations path to avoid conflict with SQLite repo
config :librarian, Librarian.PublicRepo,
  migrations_path: "priv/public_repo/migrations"

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

# Force Nx to use EXLA as the global default backend
config :nx, :default_backend, EXLA.Backend

# Target the host machine's CPU architecture
config :exla, :default_client, :host

if File.exists?("config/#{config_env()}.exs") do
  import_config "#{config_env()}.exs"
end

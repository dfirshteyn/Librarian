import Config

config :librarian, Librarian.Repo,
  database: "priv/data/librarian_dev.db",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Postgres public graph — defaults to local PG on standard port
# Override via DATABASE_PUBLIC_URL env var in runtime.exs
config :librarian, Librarian.PublicRepo,
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  database: System.get_env("PGDATABASE", "librarian_public"),
  pool_size: 2

config :librarian, LibrarianWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev_secret_key_base_at_least_64_chars_long_replace_in_prod_xxxxxxxxxxx",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:librarian, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:librarian, ~w(--watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/librarian_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :librarian, :start_ws_server, false

# Local model backend — uncomment to use real models instead of Stub
config :librarian, curator: Librarian.Curator.Hybrid
config :librarian, llama_cpp_url: "http://localhost:1234/v1"
config :librarian, embed_url: "http://localhost:1235/v1"
config :librarian, :council_llama_cpp_url, "http://localhost:1236/v1"
config :librarian, llama_cpp_timeout_ms: 120_000

# Consolidation curator: use Stub in dev so we don't need API keys locally
config :librarian, consolidation_curator: Librarian.Curator.Stub

# Free/anon users get the local LlamaCpp model for flush & recall.
# Judges (user_id prefix "judge_") route to cloud Qwen API unless force_local is set.
config :librarian, free_tier_curator: Librarian.Curator.LlamaCpp

# Port 1236: dedicated Qwen 1.7B model for consolidation re-curation synthesis.
# Port 1234: 0.6B classifier (fast ingest/extraction, not used for consolidation).
# If 1236 is not up, falls back to port 1234 automatically.
config :librarian, consolidation_llama_cpp_url: "http://localhost:1236/v1"

# Demo: require at least 6 active memories before the background AutomationServer
# fires a consolidation sweep. This gives you time to SHOW the 6 warm memory cards
# before they collapse. Use ⚡ Force Consolidation for on-demand sweeps during demos.
config :librarian, consolidation_min_memories: 6

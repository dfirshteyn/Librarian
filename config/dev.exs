import Config

config :librarian, Librarian.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "librarian_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

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
config :librarian, llama_cpp_timeout_ms: 120_000

import Config

config :librarian, Librarian.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "librarian_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :librarian, LibrarianWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_at_least_64_chars_long_replace_in_prod_xxxxxxxxxx",
  server: false

config :librarian, :start_ws_server, false

config :librarian, :db_dir, "tmp/test_data"

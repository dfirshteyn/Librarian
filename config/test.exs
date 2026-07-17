import Config

config :librarian, Librarian.Repo,
  database: "tmp/test_data/librarian_test#{System.get_env("MIX_TEST_PARTITION")}.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :librarian, LibrarianWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_at_least_64_chars_long_replace_in_prod_xxxxxxxxxx",
  server: false

config :librarian, :start_ws_server, false

config :librarian, :db_dir, "tmp/test_data"

# Isolate the COLD insights.jsonl + SQLite dir so mix test never writes
# into the dev priv/cold file (and never polutes the morning briefing).
config :librarian, :cold_dir, "tmp/test_cold"

# Use Stub in test to avoid network calls and API keys
config :librarian, consolidation_curator: Librarian.Curator.Stub

# Free tier curator in test: Stub (no network). Judges still resolve to QwenApi
# but no test exercises that path with real network calls.
config :librarian, free_tier_curator: Librarian.Curator.Stub

# Mock Req module to force all LLM HTTP calls to fail in test mode.
# This ensures delegation tests verify lock auto-release on Council failure
# without requiring actual LLM servers or API keys.
config :librarian, :req_module, {:mock, Librarian.Test.MockReq}

# Provide a fake API key since QwenApi raises on missing key
config :librarian, :dashscope_api_key, "test_key_not_used_due_to_mock"

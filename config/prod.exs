import Config

# Curator backend - use Hybrid for real model inference
# Hybrid: local LlamaCpp for summarize/embed, QwenApi for deep_pass (nightly reasoning)
config :librarian, curator: Librarian.Curator.Hybrid

# Free/anon users get the local LlamaCpp model for flush & recall
config :librarian, free_tier_curator: Librarian.Curator.LlamaCpp

config :librarian, LibrarianWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  server: true

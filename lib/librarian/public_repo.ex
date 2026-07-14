# Define a custom Postgrex type module that includes the pgvector extension.
# This is required because Postgrex doesn't know about the `vector` type by default.
# Must be at the top level — Postgrex.Types.define/3 is a macro that calls Module.create.
Postgrex.Types.define(Librarian.PublicRepo.PostgrexTypes,
  [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
  library: Pgvector
)

defmodule Librarian.PublicRepo do
  @moduledoc """
  Postgres Ecto repo for the public graph network (nodes + edges).

  This is the "global superhighway" — immutable public nodes with
  SHA-256 content hashes, pgvector embeddings, and adjacency edges.
  Separate from the private SQLite sandbox (Librarian.Repo).
  """
  use Ecto.Repo,
    otp_app: :librarian,
    adapter: Ecto.Adapters.Postgres

  def init(_type, config) do
    {:ok, Keyword.put(config, :types, Librarian.PublicRepo.PostgrexTypes)}
  end
end

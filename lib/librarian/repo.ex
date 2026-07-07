defmodule Librarian.Repo do
  use Ecto.Repo,
    otp_app: :librarian,
    adapter: Ecto.Adapters.SQLite3
end

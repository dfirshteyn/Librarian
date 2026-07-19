defmodule Librarian.Repo.Migrations.AddTimestampDefaults do
  use Ecto.Migration

  def up do
    alter table(:public_nodes) do
      modify :inserted_at, :utc_datetime, null: false, default: fragment("now()")
      modify :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end

    alter table(:public_edges) do
      modify :inserted_at, :utc_datetime, null: false, default: fragment("now()")
      modify :updated_at, :utc_datetime, null: false, default: fragment("now()")
    end
  end

  def down do
    alter table(:public_nodes) do
      modify :inserted_at, :utc_datetime, null: false
      modify :updated_at, :utc_datetime, null: false
    end

    alter table(:public_edges) do
      modify :inserted_at, :utc_datetime, null: false
      modify :updated_at, :utc_datetime, null: false
    end
  end
end

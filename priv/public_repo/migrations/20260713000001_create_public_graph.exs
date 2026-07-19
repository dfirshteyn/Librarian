defmodule Librarian.Repo.Migrations.CreatePublicGraph do
  use Ecto.Migration

  def up do
    # Enable pgvector extension (idempotent)
    execute "CREATE EXTENSION IF NOT EXISTS vector"

     # Public nodes table — SHA-256 content-addressed, 1024-dim embeddings for BGE-M3
     # No HNSW index: for hackathon-scale (< 10k nodes), exact k-NN via linear scan
     # is faster and guarantees 100% accurate neighbor retrieval for the graph viz.
     create table(:public_nodes, primary_key: false) do
       add :id, :string, primary_key: true, size: 64
       # SHA-256 hex of the summary — immutable content hash
       add :summary, :text, null: false
       add :importance, :float, null: false
       add :bucket, :string, null: false, size: 64
       add :metadata, :map, null: false
       # JSONB: tags, facts, persona_perspectives, oss_url, publisher_hash
       add :embedding, :vector, size: 1024, null: false
       add :publisher_hash, :string, size: 64
       add :oss_url, :text
       timestamps()
     end

    # Public edges table — directed labeled edges between nodes
    create table(:public_edges) do
      add :source_id,
        references(:public_nodes, column: :id, type: :string, on_delete: :delete_all),
        null: false

      add :target_id,
        references(:public_nodes, column: :id, type: :string, on_delete: :delete_all),
        null: false

      add :edge_type, :string, null: false, size: 64
      add :weight, :float, default: 1.0
      timestamps()
    end

    create unique_index(:public_edges, [:source_id, :target_id, :edge_type],
             name: :public_edges_unique_pair
           )

    create index(:public_edges, [:target_id])
  end

  def down do
    drop table(:public_edges)
    drop table(:public_nodes)
  end
end

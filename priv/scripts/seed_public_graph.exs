# Seed script for the public graph network.
#
# Creates 12 pre-synthesized public nodes spanning "research", "ideas",
# "project", and "thoughts" buckets, with realistic summaries, facts,
# tags, and pre-computed 1024-dim embeddings (generated deterministically
# from text hashes for reproducibility).
#
# Run: mix run priv/scripts/seed_public_graph.exs
#
# Requires a running Postgres instance with the public_graph migration applied.
# Set DATABASE_PUBLIC_URL or use default dev config.

Mix.Task.run("app.start")

require Logger

Logger.info("Seeding public graph with demo nodes...")

# Deterministic 1024-dim embedding generator (reproducible across runs)
# Uses SHA-256 of text to seed a simple hash-based vector
defmodule SeedEmbedding do
  @dim 1024

  def from_text(text) do
    hash = :crypto.hash(:sha256, text)
    seed = :binary.decode_unsigned(hash)
    # Generate deterministic vector using the seed
    vector = for i <- 0..(@dim - 1), do: :math.sin(seed + i * 1.618) * 0.5 + 0.5
    # L2 normalize
    norm = :math.sqrt(Enum.reduce(vector, 0.0, fn x, acc -> acc + x * x end))
    Enum.map(vector, &(&1 / norm))
  end
end

demo_nodes = [
  %{
    summary: "Migrated production database from Postgres to SQLite for simplified single-binary deployment, reducing operational overhead by 60%",
    importance: 0.85,
    bucket: "project",
    facts: ["Production database migrated from Postgres to SQLite", "Deployment simplified to single-binary architecture", "Operational overhead reduced by 60%"],
    tags: ["database", "migration", "sqlite", "devops"],
    publisher_hash: "seed_demo"
  },
  %{
    summary: "Multi-agent knowledge council architecture enables decentralized memory curation through specialized persona perspectives",
    importance: 0.9,
    bucket: "research",
    facts: ["Council uses 4 specialized personas for content analysis", "Skeptic, Historian, Connector, and Literalist each provide unique perspectives", "Judge synthesizes successful takes into final output"],
    tags: ["multi-agent", "council", "ai", "architecture"],
    publisher_hash: "seed_demo"
  },
  %{
    summary: "Local-first tiered memory system with HOT/WARM/COLD storage provides privacy-preserving personal knowledge management",
    importance: 0.88,
    bucket: "ideas",
    facts: ["HOT tier captures raw text in real-time buffers", "WARM tier stores curated memories with embeddings and importance scores", "COLD tier archives to per-tenant SQLite databases with FTS5 search"],
    tags: ["memory", "tiered-storage", "privacy", "local-first"],
    publisher_hash: "seed_demo"
  },
  %{
    summary: "Graph-based RAG with dynamic subgraph evolution outperforms static knowledge graph approaches for deep reasoning tasks",
    importance: 0.82,
    bucket: "research",
    facts: ["Dynamic subgraph construction adapts to specific queries", "Multi-agent system iteratively refines evidence retrieval", "Outperforms static graph methods on deep reasoning benchmarks"],
    tags: ["rag", "graph", "reasoning", "multi-agent"],
    publisher_hash: "seed_demo"
  },
  %{
    summary: "Anonymous X-User-Id device tracking enables privacy-first personalization without cookies or user accounts",
    importance: 0.75,
    bucket: "ideas",
    facts: ["Each device gets a unique anonymous session hash", "No personal information required for full functionality", "User identity is cryptographically isolated from data"],
    tags: ["privacy", "anonymous", "session", "security"],
    publisher_hash: "seed_demo"
  },
  %{
    summary: "BGE-M3 embedding model running locally at 1024 dimensions provides fast semantic search without cloud dependencies",
    importance: 0.78,
    bucket: "project",
    facts: ["BGE-M3 produces 1024-dimension embeddings", "Local inference eliminates network latency", "pgvector enables vector search in Postgres"],
    tags: ["embeddings", "bge-m3", "vector-search", "local-ai"],
    publisher_hash: "seed_demo"
  },
  %{
    summary: "Consolidation engine automatically merges semantically similar memories using cosine similarity and swarm clustering",
    importance: 0.8,
    bucket: "project",
    facts: ["Similarity threshold of 0.85 triggers consolidation", "Swarm-based atomic take ensures consistency", "Superseded memories remain in audit trail"],
    tags: ["consolidation", "clustering", "similarity", "memory"],
    publisher_hash: "seed_demo"
  },
  %{
    summary: "LeakGuard system redacts sensitive patterns before any data reaches external AI models or embedding services",
    importance: 0.92,
    bucket: "project",
    facts: ["API keys and secrets are detected via regex patterns", "Redaction happens before curator or embedding calls", "Original data in storage remains untouched"],
    tags: ["security", "privacy", "redaction", "leak-guard"],
    publisher_hash: "seed_demo"
  },
  %{
    summary: "Think-on-Graph 3.0 introduces MACER mechanism for multi-agent context evolution in knowledge retrieval",
    importance: 0.7,
    bucket: "research",
    facts: ["MACER stands for Multi-Agent Context Evolution and Retrieval", "Chunk-Triplets-Community heterogeneous graph index", "Dual evolution of query and subgraph for precise retrieval"],
    tags: ["tog", "macer", "graph-rag", "research"],
    publisher_hash: "seed_demo"
  },
  %{
    summary: "ParentSummarizer creates hierarchical memory structures by synthesizing chunk summaries into coherent parent memories",
    importance: 0.76,
    bucket: "ideas",
    facts: ["Chunks are linked to parents via chunk_of graph edges", "Parent memory is a summary of summaries", "Original chunks remain live for detailed grounding"],
    tags: ["hierarchy", "summarization", "chunking", "graph"],
    publisher_hash: "seed_demo"
  },
  %{
    summary: "Rate limiter with token bucket algorithm prevents abuse while allowing burst traffic up to 200 requests per minute",
    importance: 0.65,
    bucket: "thoughts",
    facts: ["Token bucket refills at configurable rate", "Burst capacity of 200 requests per minute", "Per-IP and per-tenant rate limiting"],
    tags: ["rate-limiting", "scalability", "security", "infrastructure"],
    publisher_hash: "seed_demo"
  },
  %{
    summary: "Public graph network enables cross-user discovery of semantically related insights while preserving individual privacy",
    importance: 0.87,
    bucket: "ideas",
    facts: ["SHA-256 content hashes ensure tamper-evident nodes", "pgvector enables fast cosine similarity search", "Anonymous publisher hashes protect user identity"],
    tags: ["public-graph", "discovery", "network", "privacy"],
    publisher_hash: "seed_demo"
  }
]

inserted = 0

Enum.each(demo_nodes, fn node ->
  embedding = SeedEmbedding.from_text(node.summary)

  hash_id = :crypto.hash(:sha256, node.summary) |> Base.encode16(case: :lower)

  metadata = Jason.encode!(%{
    tags: node.tags,
    facts: node.facts,
    persona_perspectives: %{
      "skeptic" => "This represents a significant architectural decision with measurable outcomes",
      "historian" => "Builds on established patterns in the field",
      "connector" => "Related to other nodes in the knowledge graph",
      "literalist" => "Factual statement with verifiable claims"
    }
  })

  result =
    Ecto.Adapters.SQL.query!(
      Librarian.PublicRepo,
      """
      INSERT INTO public_nodes (id, summary, importance, bucket, metadata, embedding, publisher_hash)
      VALUES ($1, $2, $3, $4, $5, $6, $7)
      ON CONFLICT (id) DO NOTHING
      """,
      [hash_id, node.summary, node.importance, node.bucket, metadata, embedding, node.publisher_hash]
    )

  if result.num_rows == 1 do
    inserted = inserted + 1
  end
end)

# Create edges between semantically related nodes
Logger.info("Creating adjacency edges between related nodes...")

# Get all seeded nodes
nodes_result =
  Ecto.Adapters.SQL.query!(
    Librarian.PublicRepo,
    "SELECT id, embedding::text FROM public_nodes WHERE publisher_hash = 'seed_demo'",
    []
  )

seeded_nodes =
  case nodes_result do
    %{rows: rows} when is_list(rows) ->
      Enum.map(rows, fn [id, embedding_str] ->
        # Parse pgvector string back to list
        vec = embedding_str
              |> String.trim("{")
              |> String.trim("}")
              |> String.split(",")
              |> Enum.map(&String.trim/1)
              |> Enum.map(&Float.parse/1)
              |> Enum.map(fn
                {f, _} -> f
                _ -> 0.0
              end)
        {id, vec}
      end)
    _ -> []
  end

edge_count = 0

Enum.each(seeded_nodes, fn {source_id, source_vec} ->
  Enum.each(seeded_nodes, fn {target_id, target_vec} ->
    if source_id != target_id do
      # Cosine distance
      dot = Enum.zip(source_vec, target_vec)
            |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
      distance = 1.0 - dot

      if distance < 0.35 do
        weight = Float.round(1.0 - distance, 4)

        Ecto.Adapters.SQL.query!(
          Librarian.PublicRepo,
          """
          INSERT INTO public_edges (source_id, target_id, edge_type, weight)
          VALUES ($1, $2, 'adjacent_discovery', $3)
          ON CONFLICT (source_id, target_id, edge_type) DO NOTHING
          """,
          [source_id, target_id, weight]
        )

        edge_count = edge_count + 1
      end
    end
  end)
end)

Logger.info("Seed complete: #{inserted} nodes inserted, #{edge_count} edges created")

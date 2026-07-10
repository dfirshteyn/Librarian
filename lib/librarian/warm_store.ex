defmodule Librarian.WarmStore.Memory do
  @moduledoc "A single curated memory living in the WARM tier."

  defstruct [
    :id,
    :bucket,
    :summary,
    :facts,
    :tags,
    :embedding,
    :importance,
    :created_at,
    :last_accessed_at,
    :superseded_by,
    :correlation_id,
    access_count: 0
  ]
end

defmodule Librarian.WarmStore do
  @moduledoc """
  The WARM tier: curated, tagged, scored memories — what HOT becomes
  after a curator pass. Backed by a single GenServer/ETS table (not
  per-bucket, since cross-bucket associative lookup by tag is the whole
  point of this tier).

  Decay is explicit and inspectable, not automatic on a timer inside
  here — `Librarian.Curator.Scheduler` (or you, by hand) calls `decay/1`
  so you can watch scores drop and tune the curve instead of it
  happening invisibly.
  """

  use GenServer

  @table :warm_memories

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    # Trap exits so terminate/2 fires when the Supervisor shuts us down
    # (SIGTERM, `mix release stop`, normal supervisor shutdown — not SIGKILL)
    Process.flag(:trap_exit, true)

    table = :ets.new(@table, [:set, :named_table, :public])

    # Auto-snapshot every 5 minutes to bound data loss from hard crashes
    Process.send_after(self(), :auto_snapshot, 5 * 60 * 1_000)

    {:ok, %{table: table, next_id: 1}}
  end

  # --- public API ---

  def put(bucket, %Librarian.Curator.Result{} = result, opts \\ []) do
    correlation_id = Keyword.get(opts, :correlation_id)
    GenServer.call(__MODULE__, {:put, bucket, result, correlation_id})
  end

  def get(id) do
    case :ets.lookup(@table, id) do
      [{^id, memory}] -> bump_access(memory)
      [] -> nil
    end
  end

  def all do
    :ets.tab2list(@table) |> Enum.map(fn {_id, m} -> m end)
  end

  @doc """
  Return all active (non-superseded) memories for a given user.
  """
  def all_for_user(user_id) do
    prefix = user_id <> ":"

    all()
    |> Enum.filter(&String.starts_with?(&1.bucket, prefix))
    |> Enum.reject(& &1.superseded_by)
  end

  @doc """
  Count how many memories for a user have been superseded (merged into a
  newer consolidated memory). Used by the dashboard to show \"N merged\" so
  the consolidation history is visible without cluttering the active list.
  """
  def superseded_count_for_user(user_id) do
    prefix = user_id <> ":"

    all()
    |> Enum.filter(&String.starts_with?(&1.bucket, prefix))
    |> Enum.count(& &1.superseded_by)
  end

  def by_bucket(bucket) do
    all() |> Enum.filter(&(&1.bucket == bucket))
  end

  @doc """
  Find memories that share at least one tag — the associative-graph edge,
  cheaply computed on read. Pass `exclude_id` to omit a memory from its
  own results, and `other_bucket_only` to surface only cross-bucket hits
  (the "synaptic jump" — a connection your top recall result wouldn't
  show on its own, because it lives in a different bucket).
  """
  def related_by_tag(tags, opts \\ []) when is_list(tags) do
    tagset = MapSet.new(tags)
    exclude_id = Keyword.get(opts, :exclude_id)
    bucket_filter = Keyword.get(opts, :other_bucket_only)
    user_id = Keyword.get(opts, :user_id, "local")
    prefix = user_id <> ":"

    all()
    |> Enum.filter(&String.starts_with?(&1.bucket, prefix))
    |> Enum.filter(fn m -> is_nil(exclude_id) or m.id != exclude_id end)
    |> Enum.filter(fn m -> is_nil(bucket_filter) or m.bucket != bucket_filter end)
    |> Enum.filter(fn m ->
      MapSet.intersection(MapSet.new(m.tags), tagset) |> MapSet.size() > 0
    end)
  end

  @doc """
  Recall memories matching the query using 3-way Reciprocal Rank Fusion (RRF).

  Three independent ranked lists are generated:
    1. **Keyword score** — term frequency of query tokens in summary, facts, and tags
    2. **Vector score** — cosine similarity between query embedding and memory embedding
    3. **Importance score** — the memory's curated importance (with Ebbinghaus decay)

  These three lists are fused via RRF: `score = Σ 1/(k + rank)` for each list where
  the memory has a non-zero signal. The constant k=60 softens the ranking so a
  memory that's #1 in one signal and #50 in another still gets a meaningful
  combined score.

  This replaces the old hard keyword filter + weighted sum approach. The key
  improvement: memories that are semantically relevant (high vector score) but
  don't share query keywords are no longer excluded — they're ranked low but
  still findable. Meanwhile, importance ensures that critical, frequently-recalled
  memories surface even when keyword and vector signals are weak.
  """
  def recall(query, user_id \\ "local", opts \\ []) when is_binary(query) do
    query_tokens = String.downcase(query) |> String.split() |> Enum.reject(&(&1 == ""))
    include_superseded = Keyword.get(opts, :include_superseded, false)
    prefix = user_id <> ":"

    curator_impl = Librarian.Curator.resolve_curator(user_id, opts)

    query_embedding =
      case Librarian.Curator.embed(query, curator_impl) do
        {:ok, vec} -> vec
        _ -> nil
      end

    # 1. Gather all viable memory candidates (no hard keyword filter)
    candidates =
      all()
      |> Enum.filter(&String.starts_with?(&1.bucket, prefix))
      |> Enum.filter(fn m -> include_superseded or is_nil(m.superseded_by) end)

    # 2. Extract the three baseline metrics for each candidate
    scored =
      candidates
      |> Enum.map(fn m ->
        ks = keyword_score(m, query_tokens)
        vs = cosine_similarity_or_nil(m.embedding, query_embedding)
        imp = m.importance || 0.0
        {m, ks, vs, imp}
      end)

    # 3. Rank each category independently (descending)
    keyword_ranked =
      scored |> Enum.sort_by(fn {_m, ks, _vs, _imp} -> -ks end) |> Enum.with_index(1)

    vector_ranked =
      scored |> Enum.sort_by(fn {_m, _ks, vs, _imp} -> -(vs || 0.0) end) |> Enum.with_index(1)

    import_ranked =
      scored |> Enum.sort_by(fn {_m, _ks, _vs, imp} -> -imp end) |> Enum.with_index(1)

    # 4. Build instant rank lookups by memory id
    keyword_ranks = Map.new(keyword_ranked, fn {{m, _, _, _}, rank} -> {m.id, rank} end)
    vector_ranks = Map.new(vector_ranked, fn {{m, _, _, _}, rank} -> {m.id, rank} end)
    import_ranks = Map.new(import_ranked, fn {{m, _, _, _}, rank} -> {m.id, rank} end)

    # 5. Execute 3-way RRF fusion
    k = 60

    scored
    |> Enum.map(fn {m, ks, vs, _imp} ->
      kr = Map.get(keyword_ranks, m.id)
      vr = Map.get(vector_ranks, m.id)
      ir = Map.get(import_ranks, m.id)

      # If score is zero or nil, it contributes 0.0 to mimic omission from top-N
      rrf = if ks > 0, do: 1.0 / (k + kr), else: 0.0
      rrf = rrf + if not is_nil(vs), do: 1.0 / (k + vr), else: 0.0
      rrf = rrf + 1.0 / (k + ir)

      {m, rrf}
    end)
    |> Enum.sort_by(fn {_m, rrf} -> -rrf end)
    |> Enum.map(fn {m, _} -> m end)
  end

  # Term frequency score: count how many query tokens appear in this memory's
  # summary, facts, and tags. Simple but effective — BM25 is overkill for
  # per-tenant ETS tables with < 2,000 entries.
  defp keyword_score(_memory, []), do: 0

  defp keyword_score(memory, query_tokens) do
    text =
      String.downcase(
        "#{memory.summary || ""} #{Enum.join(memory.facts || [], " ")} #{Enum.join(memory.tags || [], " ")}"
      )

    words = String.split(text)

    Enum.reduce(query_tokens, 0, fn token, acc ->
      acc + Enum.count(words, &(&1 == token))
    end)
  end

  # Graceful cosine similarity that returns nil when either vector is absent.
  # This lets the RRF fusion skip the vector signal cleanly rather than
  # producing a meaningless 0.0 similarity score.
  defp cosine_similarity_or_nil(nil, _), do: nil
  defp cosine_similarity_or_nil(_, nil), do: nil
  defp cosine_similarity_or_nil(embedding, query_vec), do: cosine_similarity(embedding, query_vec)

  # True cosine similarity: A·B / (||A|| * ||B|| + epsilon).
  #
  # This handles both pre-normalized vectors (Stub's embed/1 already
  # L2-normalizes) and raw vectors (llama.cpp embeddings may not be).
  # The epsilon prevents division by zero on zero-vector inputs.
  #
  # Pure Elixir, no Nx dependency. Fast enough for hackathon scale
  # (thousands of 64-768 dim vectors = microseconds). Swap for Nx batch
  # ops in production when scanning 10k+ memories per recall.
  defp cosine_similarity(a, b) when length(a) == length(b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    norm_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    norm_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))
    dot / (norm_a * norm_b + 1.0e-8)
  end

  defp cosine_similarity(_, _), do: 0.0

  def forget(id) do
    GenServer.call(__MODULE__, {:forget, id})
  end

  @doc """
  Apply decay to every memory's importance, but NOT uniformly:

    - Buckets configured with `:decay` (the default — "ideas", "thoughts",
      anything ephemeral) get true exponential forgetting, R = e^(-t/S),
      where S ("retrieval strength") grows every time the memory is
      recalled. A memory you keep bringing back up decays slower than
      one nobody's touched — this is the actual answer to "rank by how
      often it's brought back up, not just noise."
    - Buckets configured with `:supersede` ("project", "research" by
      default — anything decision-like) are exempt from decay entirely.
      Old decisions don't go stale with time; they go stale when a NEW
      decision explicitly supersedes them (see `supersede/2`). A bug
      from six months ago is not less true today than it was then.

  This split exists because of a real critique of naive uniform decay:
  a numeric score quietly bleeding to zero is indistinguishable from
  "this stopped mattering" and "nobody happened to ask about it lately."
  Those are different things and deserve different handling.
  """
  def decay_all(base_half_life_seconds \\ 60 * 60 * 24 * 14) do
    GenServer.call(__MODULE__, {:decay_all, base_half_life_seconds})
  end

  @doc """
  Mark `old_id` as superseded by `new_id`. The old memory is NOT deleted —
  it stays, flagged, so the audit trail survives — but its importance
  drops sharply and `recall/1` excludes superseded memories by default
  (pass `include_superseded: true` to see them).
  """
  def supersede(old_id, new_id) do
    GenServer.call(__MODULE__, {:supersede, old_id, new_id})
  end

  @doc "Memories below the threshold — candidates for archiving to COLD or deleting."
  def low_relevance(threshold \\ 0.15) do
    all() |> Enum.filter(&(&1.importance < threshold and is_nil(&1.superseded_by)))
  end

  @doc """
  Dump all WARM memories to a JSONL snapshot file on disk.
  Called on shutdown so memories survive a restart.
  """
  def dump do
    path = snapshot_path()
    File.mkdir_p!(Path.dirname(path))

    lines =
      all()
      |> Enum.map(fn m ->
        Librarian.Json.encode(%{
          id: m.id,
          bucket: m.bucket,
          summary: m.summary,
          facts: m.facts,
          tags: m.tags,
          embedding: m.embedding,
          importance: m.importance,
          created_at: DateTime.to_iso8601(m.created_at),
          last_accessed_at: DateTime.to_iso8601(m.last_accessed_at),
          superseded_by: m.superseded_by,
          correlation_id: m.correlation_id,
          access_count: m.access_count
        }) <> "\n"
      end)
      |> IO.iodata_to_binary()

    File.write!(path, lines)
    :ok
  end

  @doc """
  Load WARM memories from a JSONL snapshot file on disk.
  Called on startup to restore memories from the last shutdown.
  """
  def load do
    path = snapshot_path()

    if File.exists?(path) do
      lines =
        path
        |> File.read!()
        |> String.split("\n", trim: true)

      Enum.each(lines, fn line ->
        case Librarian.Json.decode(line) do
          {:ok, map} ->
            created = parse_datetime(map["created_at"])
            accessed = parse_datetime(map["last_accessed_at"])

            memory = %__MODULE__.Memory{
              id: map["id"],
              bucket: map["bucket"],
              summary: map["summary"],
              facts: map["facts"] || [],
              tags: map["tags"] || [],
              embedding: map["embedding"],
              importance: map["importance"] || 0.5,
              created_at: created,
              last_accessed_at: accessed,
              superseded_by: map["superseded_by"],
              correlation_id: map["correlation_id"],
              access_count: map["access_count"] || 0
            }

            GenServer.call(__MODULE__, {:load, memory})

          _ ->
            :ok
        end
      end)

      :loaded
    else
      :no_snapshot
    end
  end

  defp snapshot_path do
    Path.join([Application.get_env(:librarian, :cold_dir, "priv/cold"), "warm_snapshot.jsonl"])
  end

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  # ── GenServer ────────────────────────────────────────────────────────

  @impl true
  def handle_info(:auto_snapshot, state) do
    dump()
    Process.send_after(self(), :auto_snapshot, 5 * 60 * 1_000)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    dump()
    :ok
  end

  @impl true
  def handle_call({:load, memory}, _from, %{table: table, next_id: id} = state) do
    next_id = max(id, (memory.id || 0) + 1)
    :ets.insert(table, {memory.id, memory})
    {:reply, :ok, %{state | next_id: next_id}}
  end

  @impl true
  def handle_call({:put, bucket, result, correlation_id}, _from, %{table: table, next_id: id} = state) do
    now = DateTime.utc_now()

    memory = %Librarian.WarmStore.Memory{
      id: id,
      bucket: bucket,
      summary: result.summary,
      facts: result.facts,
      tags: result.tags,
      embedding: result.embedding,
      importance: result.importance,
      correlation_id: correlation_id,
      created_at: now,
      last_accessed_at: now
    }

    :ets.insert(table, {id, memory})
    dump()
    {:reply, memory, %{state | next_id: id + 1}}
  end

  @impl true
  def handle_call({:forget, id}, _from, %{table: table} = state) do
    :ets.delete(table, id)
    dump()
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:decay_all, base_half_life}, _from, %{table: table} = state) do
    now = DateTime.utc_now()

    :ets.tab2list(table)
    |> Enum.each(fn {id, m} ->
      updated =
        case decay_policy(m.bucket) do
          :supersede ->
            # exempt from time-decay entirely; only supersede/2 lowers this
            m

          :decay ->
            seconds_idle = DateTime.diff(now, m.last_accessed_at)
            # retrieval strength S grows with access_count — each recall
            # makes the memory more durable, same idea as Ebbinghaus
            # reinforcement, just parameterized through our existing
            # half-life math instead of a raw exponential constant.
            effective_half_life = base_half_life * (1 + m.access_count * 0.5)
            decay_factor = :math.pow(0.5, seconds_idle / effective_half_life)
            %{m | importance: Float.round(m.importance * decay_factor, 4)}
        end

      :ets.insert(table, {id, updated})
    end)

    dump()
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:supersede, old_id, new_id}, _from, %{table: table} = state) do
    case :ets.lookup(table, old_id) do
      [{^old_id, old_memory}] ->
        updated = %{old_memory | superseded_by: new_id, importance: 0.05}
        :ets.insert(table, {old_id, updated})
        dump()
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp decay_policy(bucket) do
    policies = Application.get_env(:librarian, :decay_policies, %{})
    # bucket is "user_id:bucket_name" — check full key first, then bare name
    bare = bucket |> String.split(":") |> List.last()

    Map.get(
      policies,
      bucket,
      Map.get(policies, bare, Application.get_env(:librarian, :default_decay_policy, :decay))
    )
  end

  defp bump_access(memory) do
    updated = %{
      memory
      | access_count: memory.access_count + 1,
        last_accessed_at: DateTime.utc_now()
    }

    :ets.insert(@table, {memory.id, updated})
    dump()
    updated
  end
end

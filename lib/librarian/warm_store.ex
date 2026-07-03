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
    table = :ets.new(@table, [:set, :named_table, :public])
    {:ok, %{table: table, next_id: 1}}
  end

  # --- public API ---

  def put(bucket, %Librarian.Curator.Result{} = result) do
    GenServer.call(__MODULE__, {:put, bucket, result})
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
    |> Enum.filter(fn m -> MapSet.intersection(MapSet.new(m.tags), tagset) |> MapSet.size() > 0 end)
  end

  @doc """
  Recall memories matching the query. Candidates are found by keyword
  substring match (fast, no model needed), then re-ranked by a combined
  score of cosine similarity (when embeddings exist) and importance.

  Falls back to importance-only ranking when a memory has no embedding
  (e.g. from QwenApi, which returns nil for embed/1). This means the
  ranking degrades gracefully rather than breaking when backends are mixed.
  """
  def recall(query, user_id \\ "local", opts \\ []) when is_binary(query) do
    q = String.downcase(query)
    include_superseded = Keyword.get(opts, :include_superseded, false)
    prefix = user_id <> ":"

    query_embedding =
      case Librarian.Curator.embed(query) do
        {:ok, vec} -> vec
        _ -> nil
      end

    all()
    |> Enum.filter(&String.starts_with?(&1.bucket, prefix))
    |> Enum.filter(fn m -> include_superseded or is_nil(m.superseded_by) end)
    |> Enum.filter(fn m ->
      String.contains?(String.downcase(m.summary || ""), q) or
        Enum.any?(m.facts || [], &String.contains?(String.downcase(&1), q)) or
        Enum.any?(m.tags || [], &String.contains?(&1, q))
    end)
    |> Enum.sort_by(fn m -> -recall_score(m, query_embedding) end)
  end

  # Combined score: 60% cosine similarity (when available) + 40% importance.
  # The split is intentional — importance encodes how decision-critical the
  # memory is (set by the curator), while similarity encodes how relevant it
  # is to *this specific query*. Neither alone is sufficient.
  defp recall_score(memory, nil), do: memory.importance
  defp recall_score(%{embedding: nil} = memory, _query_vec), do: memory.importance
  defp recall_score(memory, query_vec) do
    sim = cosine_similarity(memory.embedding, query_vec)
    sim * 0.6 + memory.importance * 0.4
  end

  defp cosine_similarity(a, b) when length(a) == length(b) do
    Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
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

  # --- GenServer ---

  @impl true
  def handle_call({:put, bucket, result}, _from, %{table: table, next_id: id} = state) do
    now = DateTime.utc_now()

    memory = %Librarian.WarmStore.Memory{
      id: id,
      bucket: bucket,
      summary: result.summary,
      facts: result.facts,
      tags: result.tags,
      embedding: result.embedding,
      importance: result.importance,
      created_at: now,
      last_accessed_at: now
    }

    :ets.insert(table, {id, memory})
    {:reply, memory, %{state | next_id: id + 1}}
  end

  @impl true
  def handle_call({:forget, id}, _from, %{table: table} = state) do
    :ets.delete(table, id)
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

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:supersede, old_id, new_id}, _from, %{table: table} = state) do
    case :ets.lookup(table, old_id) do
      [{^old_id, old_memory}] ->
        updated = %{old_memory | superseded_by: new_id, importance: 0.05}
        :ets.insert(table, {old_id, updated})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp decay_policy(bucket) do
    policies = Application.get_env(:librarian, :decay_policies, %{})
    # bucket is "user_id:bucket_name" — check full key first, then bare name
    bare = bucket |> String.split(":") |> List.last()
    Map.get(policies, bucket,
      Map.get(policies, bare,
        Application.get_env(:librarian, :default_decay_policy, :decay)))
  end

  defp bump_access(memory) do
    updated = %{
      memory
      | access_count: memory.access_count + 1,
        last_accessed_at: DateTime.utc_now()
    }

    :ets.insert(@table, {memory.id, updated})
    updated
  end
end

defmodule Librarian.ColdStore.ConnectionManager do
  @moduledoc """
  Manages per-tenant SQLite connections for the COLD store.

  Each tenant (user_id) gets its own `Exqlite.Connection` GenServer process,
  supervised under `Librarian.ColdStore.ConnectionSupervisor`. Connections are
  registered in an ETS table (`:cold_conns`) keyed by user_id.

  On first access, the database file is created and the schema (tables, FTS5
  virtual table, triggers) is initialized. The sqlite-vec extension is loaded
  via `load_extension` if configured.
  """

  @table :cold_conns

  @schema_statements [
    """
    CREATE TABLE IF NOT EXISTS memories (
      id INTEGER PRIMARY KEY,
      bucket TEXT NOT NULL,
      summary TEXT,
      facts TEXT,
      tags TEXT,
      importance REAL,
      embedding BLOB,
      created_at TEXT,
      last_accessed_at TEXT,
      superseded_by INTEGER REFERENCES memories(id)
    )
    """,
    """
    CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
      summary, facts, tags,
      content=memories,
      tokenize='porter ascii'
    )
    """,
    """
    CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
      INSERT INTO memory_fts(rowid, summary, facts, tags)
      VALUES (new.id, new.summary, new.facts, new.tags);
    END
    """,
    """
    CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
      INSERT INTO memory_fts(memory_fts, rowid, summary, facts, tags)
      VALUES('delete', old.id, old.summary, old.facts, old.tags);
    END
    """,
    """
    CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
      INSERT INTO memory_fts(memory_fts, rowid, summary, facts, tags)
      VALUES('delete', old.id, old.summary, old.facts, old.tags);
      INSERT INTO memory_fts(rowid, summary, facts, tags)
      VALUES (new.id, new.summary, new.facts, new.tags);
    END
    """,
    """
    CREATE TABLE IF NOT EXISTS memory_relationships (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      source_id TEXT NOT NULL,
      target_id TEXT NOT NULL,
      relationship_type TEXT NOT NULL,
      metadata_json TEXT,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_rel_src ON memory_relationships(source_id)
    """,
    """
    CREATE INDEX IF NOT EXISTS idx_rel_tgt ON memory_relationships(target_id)
    """,
    """
    CREATE TABLE IF NOT EXISTS buckets (
      name TEXT PRIMARY KEY,
      display_name TEXT,
      created_at TEXT DEFAULT (datetime('now')),
      deleted_at TEXT
    )
    """
  ]

  @doc """
  Initialize the ETS table. Called from Application.start.
  Safe to call multiple times — returns :ok if already exists.
  """
  def init_table do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:set, :named_table, :public])
        :ok
      _ ->
        :ok
    end
  end

  @doc """
  Get or start a connection for the given user_id.
  Returns the pid of the `Exqlite.Connection` GenServer.
  """
  def get_conn(user_id) when is_binary(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, pid}] when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: start_connection(user_id)

      _ ->
        start_connection(user_id)
    end
  end

  @doc """
  Close all connections and clear the ETS table.
  Used for test cleanup.
  """
  def close_all do
    :ets.tab2list(@table)
    |> Enum.each(fn {_user_id, pid} ->
      DynamicSupervisor.terminate_child(Librarian.ColdStore.ConnectionSupervisor, pid)
    end)

    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  List all known user_ids that have connections.
  """
  def all_user_ids do
    :ets.tab2list(@table)
    |> Enum.map(fn {user_id, _pid} -> user_id end)
  end

  @doc """
  Close a specific user's connection, remove it from ETS, and delete the .db file.
  Used by the daily sweep to clean up stale anonymous sandboxes.
  Does nothing if the user has no active connection.
  """
  def close_connection(user_id) when is_binary(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, pid}] when is_pid(pid) ->
        # Terminate the connection process via the dynamic supervisor
        DynamicSupervisor.terminate_child(Librarian.ColdStore.ConnectionSupervisor, pid)
        :ets.delete(@table, user_id)

        # Delete the .db file from disk
        path = db_path(user_id)
        if File.exists?(path) do
          File.rm!(path)
        end

        :ok

      _ ->
        # No active connection — skip. Still try to delete the file though.
        path = db_path(user_id)
        if File.exists?(path) do
          File.rm!(path)
        end

        :ok
    end
  end

  @doc """
  Return the database file path for a user_id.
  Uses `:db_dir` config (defaults to "priv/data").
  """
  def db_path(user_id) do
    base_dir = Application.get_env(:librarian, :db_dir, "priv/data")
    Path.join(base_dir, "#{user_id}.db")
  end

  # --- private ---

  defp start_connection(user_id) do
    path = db_path(user_id)
    File.mkdir_p!(Path.dirname(path))

    connect_opts =
      if Application.get_env(:librarian, :sqlite_vec_enabled, false) do
        vec_path = Application.get_env(:librarian, :sqlite_vec_path, "priv/ext/vec0.so")
        [database: path, load_extensions: [vec_path]]
      else
        [database: path]
      end

    child_spec = %{
      id: {:cold_conn, user_id},
      start: {DBConnection.ConnectionPool, :start_link, [{Exqlite.Connection, connect_opts}]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }

    case DynamicSupervisor.start_child(Librarian.ColdStore.ConnectionSupervisor, child_spec) do
      {:ok, pid} ->
        :ets.insert(@table, {user_id, pid})
        init_schema(pid)
        pid

      {:error, {:already_started, pid}} ->
        :ets.insert(@table, {user_id, pid})
        pid

      {:error, reason} ->
        raise "Failed to start SQLite connection for user #{user_id}: #{inspect(reason)}"
    end
  end

  defp init_schema(conn) do
    Enum.each(@schema_statements, fn stmt ->
      {:ok, _} = Exqlite.query(conn, stmt, [])
    end)

    # Only create vec0 virtual table if sqlite-vec is enabled
    if Application.get_env(:librarian, :sqlite_vec_enabled, false) do
      vec_stmt = """
      CREATE VIRTUAL TABLE IF NOT EXISTS vec_memories USING vec0(
        embedding float[768] distance_metric=cosine
      )
      """
      {:ok, _} = Exqlite.query(conn, vec_stmt, [])

      vec_trigger = """
      CREATE TRIGGER IF NOT EXISTS memories_vec_ai AFTER INSERT ON memories
      WHEN new.embedding IS NOT NULL
      BEGIN
        INSERT INTO vec_memories(rowid, embedding)
        VALUES (new.id, new.embedding);
      END
      """
      {:ok, _} = Exqlite.query(conn, vec_trigger, [])
    end

    :ok
  end

end

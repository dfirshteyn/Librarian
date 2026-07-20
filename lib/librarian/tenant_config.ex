defmodule Librarian.TenantConfig do
  @moduledoc """
  Per-tenant configuration stored in the user's SQLite database.

  Stores user preferences that need to persist across restarts:
  - auto_flush_enabled: boolean
  - auto_consolidation_enabled: boolean
  - flush_threshold: integer (default: 5)
  - flush_timeout_sec: integer (default: 30)

  Table schema: tenant_configs(key TEXT PRIMARY KEY, value TEXT, updated_at TEXT)
  """

  alias Librarian.ColdStore.ConnectionManager

  @default_flush_threshold 5
  @default_flush_timeout_sec 30

  @doc """
  Get tenant configuration value. Returns default if not set.
  """
  def get(user_id, key) when is_binary(user_id) and is_atom(key) do
    conn = ConnectionManager.get_conn(user_id)

    case Exqlite.query(conn, "SELECT value FROM tenant_configs WHERE key = ?1", [
           Atom.to_string(key)
         ]) do
      {:ok, %{rows: [[value]]}} ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> value == "true"
        end

      _ ->
        default_for(key)
    end

  end

  @doc """
  Set tenant configuration value.
  """
  def set(user_id, key, value) when is_binary(user_id) and is_atom(key) do
    conn = ConnectionManager.get_conn(user_id)

    now = DateTime.to_iso8601(DateTime.utc_now())
    value_str = to_string(value)

    Exqlite.query(
      conn,
      "INSERT INTO tenant_configs (key, value, updated_at) VALUES (?1, ?2, ?3) ON CONFLICT(key) DO UPDATE SET value = ?2, updated_at = ?3",
      [Atom.to_string(key), value_str, now]
    )

    :ok
  end

  @doc """
  Check if auto-flush is enabled for a tenant.
  """
  def auto_flush_enabled?(user_id) when is_binary(user_id) do
    get(user_id, :auto_flush_enabled) == true
  end

  @doc """
  Check if auto-consolidation is enabled for a tenant.
  """
  def auto_consolidation_enabled?(user_id) when is_binary(user_id) do
    value = get(user_id, :auto_consolidation_enabled)
    value == true or is_nil(value)
  end

  @doc """
  Get flush threshold for a tenant.
  """
  def flush_threshold(user_id) when is_binary(user_id) do
    get(user_id, :flush_threshold)
  end

  @doc """
  Get flush timeout for a tenant.
  """
  def flush_timeout_sec(user_id) when is_binary(user_id) do
    get(user_id, :flush_timeout_sec)
  end

  # ── Schema ───────────────────────────────────────────────────────────────

  @doc """
  Initialize the tenant_configs table. Called during schema init.
  """
  def schema_statements do
    [
      """
      CREATE TABLE IF NOT EXISTS tenant_configs (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TEXT DEFAULT (datetime('now'))
      )
      """
    ]
  end

  @doc """
  Check if nightly pass is enabled for a tenant.
  """
  def nightly_pass_enabled?(user_id) when is_binary(user_id) do
    get(user_id, :nightly_pass_enabled) == true
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp default_for(:auto_flush_enabled), do: true
  defp default_for(:auto_consolidation_enabled), do: true
  defp default_for(:nightly_pass_enabled), do: true
  defp default_for(:flush_threshold), do: @default_flush_threshold
  defp default_for(:flush_timeout_sec), do: @default_flush_timeout_sec
  defp default_for(_), do: nil
end

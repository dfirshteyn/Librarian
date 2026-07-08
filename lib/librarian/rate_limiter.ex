defmodule Librarian.RateLimiter do
  @moduledoc ~S"""
  Simple, in-memory ETS-based rate limiter for the hackathon demo.

  Tracks requests per IP/tenant pair using a sliding window counter.
  No dependency on the Ecto Repo or any database — pure ETS, microsecond
  latency, survives nothing (ephemeral by design).

  Usage in a plug:
      plug :check_rate
      defp check_rate(conn, _opts) do
        key = "#{conn.remote_ip}:<user-id>"
        case Librarian.RateLimiter.allow?(key) do
          :ok -> conn
          {:error, _} -> conn |> put_status(429) |> json(%{error: "rate limit exceeded"}) |> halt()
        end
      end
  """

  @table :rate_limiter
  @window_ms 60_000  # 1 minute sliding window
  @max_requests 100  # 100 requests per window
  @burst_max 200     # burst up to 200

  @doc """
  Initialize the ETS table. Called from Application.start.
  Safe to call multiple times — returns :ok if already exists.
  """
  def init do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:set, :named_table, :public])
        :ok
      _ ->
        :ok
    end
  end

  @doc """
  Check if a request from this key should be allowed.

  Returns `:ok` if within limits, `{:error, :rate_limited}` if exceeded.
  """
  def allow?(key) when is_binary(key) do
    now = System.monotonic_time(:millisecond)
    window_start = now - @window_ms

    case :ets.lookup(@table, key) do
      [{^key, timestamps}] ->
        # Prune timestamps outside the window
        active = Enum.filter(timestamps, &(&1 > window_start))

        if length(active) >= @burst_max do
          {:error, :rate_limited}
        else
          # Update with new timestamp appended
          new_timestamps = [now | active]
          :ets.insert(@table, {key, new_timestamps})

          if length(new_timestamps) > @max_requests do
            {:error, :rate_limited}
          else
            :ok
          end
        end

      [] ->
        :ets.insert(@table, {key, [now]})
        :ok
    end
  end

  @doc """
  Get current count for a key (for dashboard display).
  """
  def count(key) when is_binary(key) do
    now = System.monotonic_time(:millisecond)
    window_start = now - @window_ms

    case :ets.lookup(@table, key) do
      [{^key, timestamps}] ->
        Enum.count(timestamps, &(&1 > window_start))
      [] ->
        0
    end
  end

  @doc """
  Get total active keys (for dashboard display).
  """
  def active_keys do
    now = System.monotonic_time(:millisecond)
    window_start = now - @window_ms

    :ets.tab2list(@table)
    |> Enum.count(fn {_key, timestamps} ->
      Enum.any?(timestamps, &(&1 > window_start))
    end)
  end

  @doc """
  Reset all counters (for testing).
  """
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end
end

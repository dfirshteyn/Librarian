defmodule Librarian.Wal do
  @moduledoc """
  Write-ahead log for the HOT tier. Solves the one real gap in the
  original scaffold: if a bucket GenServer crashes with unflushed
  payloads in ETS, those payloads were just gone.

  Design:
  - One append-only file per bucket: `priv/wal/<bucket>.wal`
  - Written BEFORE the ETS insert (write-ahead, not write-after)
  - Replayed line-by-line on bucket GenServer restart via `File.stream!/1`
  - Truncated only after a successful `Flusher.flush_bucket/1` drain

  The WAL is the event-sourcing / audit-trail layer Gemini described —
  raw captured payloads in arrival order, never modified. Everything
  downstream (ETS, WARM tier, COLD tier) is derived from it.

  Format: one JSON line per payload, with a sequence number and
  wall-clock timestamp prepended so replay can detect duplicates and
  the "morning briefing" can show when things were captured.
  """

  @wal_dir Application.compile_env(:librarian, :wal_dir, "priv/wal")

  # ---------- write path ----------

  @doc """
  Append a payload to the bucket's WAL. Call this BEFORE inserting into
  ETS — that's what makes it a write-ahead log rather than a write-after
  log. Returns the sequence number assigned to this entry.
  """
  def append(bucket, %Librarian.Capture.Payload{} = payload) do
    path = wal_path(bucket)
    File.mkdir_p!(Path.dirname(path))

    seq = next_seq(bucket)

    line =
      Librarian.Json.encode(%{
        "seq" => seq,
        "captured_at" => DateTime.to_iso8601(payload.occurred_at || DateTime.utc_now()),
        "source" => payload.source,
        "raw_text" => payload.raw_text,
        "hint_tags" => payload.hint_tags,
        "metadata" => payload.metadata
      })

    # :append mode + sync write — we want this on disk before we touch ETS
    File.open!(path, [:append, :sync], fn f -> IO.binwrite(f, line <> "\n") end)
    seq
  end

  # ---------- replay path ----------

  @doc """
  Replay the WAL for a bucket, yielding each payload in order.
  Used by `HotStore.init/1` when a bucket process (re)starts — this is
  how HOT state survives a GenServer crash.

  Uses `File.stream!/1` so arbitrarily large WALs don't have to fit in
  memory all at once; each line is decoded as it's read.
  """
  def replay(bucket) do
    path = wal_path(bucket)

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(fn line ->
        case Librarian.Json.decode(line) do
          {:ok, map} -> payload_from_map(map)
          {:error, _} -> nil
        end
      end)
      |> Stream.reject(&is_nil/1)
    else
      Stream.repeatedly(fn -> nil end) |> Stream.take(0)
    end
  end

  @doc """
  Truncate (clear) the WAL for a bucket. Call this after a successful
  `Flusher.flush_bucket/1` — at that point the payloads are in WARM,
  so keeping them in the WAL too would just cause double-ingestion on
  the next crash/restart.
  """
  def truncate(bucket) do
    path = wal_path(bucket)
    if File.exists?(path), do: File.write!(path, "")
    :ok
  end

  @doc "Does this bucket have unprocessed WAL entries? (Useful for startup diagnostics.)"
  def pending?(bucket) do
    path = wal_path(bucket)
    File.exists?(path) and File.stat!(path).size > 0
  end

  @doc "All buckets that have a non-empty WAL — useful for startup recovery pass."
  def pending_buckets do
    case File.ls(@wal_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".wal"))
        |> Enum.map(&Path.basename(&1, ".wal"))
        |> Enum.filter(&pending?/1)

      {:error, _} ->
        []
    end
  end

  # ---------- internals ----------

  defp wal_path(bucket), do: Path.join(@wal_dir, "#{bucket}.wal")

  # Monotonic per-bucket sequence numbers stored in a process dictionary
  # keyed by bucket name. Fine for a single-machine daemon — if you ever
  # need distributed seq numbers, swap this for an atomic counter in ETS.
  defp next_seq(bucket) do
    key = {:wal_seq, bucket}
    current = Process.get(key, 0)
    Process.put(key, current + 1)
    current + 1
  end

  defp payload_from_map(map) do
    %Librarian.Capture.Payload{
      source: map["source"] || "wal_replay",
      raw_text: map["raw_text"] || "",
      occurred_at: parse_dt(map["captured_at"]),
      hint_tags: map["hint_tags"] || [],
      metadata: Map.merge(map["metadata"] || %{}, %{"wal_seq" => map["seq"], "replayed" => true})
    }
  end

  defp parse_dt(nil), do: DateTime.utc_now()
  defp parse_dt(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
end

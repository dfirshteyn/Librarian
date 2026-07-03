defmodule Librarian.ColdStore do
  @moduledoc """
  The COLD tier: plain files on disk, one JSON-lines file per bucket
  under `priv/cold/<bucket>.jsonl`. Deliberately boring — this is the
  durable layer, it should survive the BEAM restarting and be greppable
  by hand if everything else breaks.
  """

  @dir Application.compile_env(:librarian, :cold_dir, "priv/cold")

  @doc """
  Append a structured insight (a supersession, a synaptic jump, anything
  the curator/router noticed on its own) to `priv/cold/insights.jsonl`.
  This is the "what did the librarian connect while I was away" log —
  read it with `read_insights/1` or `Librarian.morning_briefing/0`.
  """
  def log_insight(map) when is_map(map) do
    File.mkdir_p!(@dir)
    path = Path.join(@dir, "insights.jsonl")

    line =
      map
      |> Map.put("logged_at", DateTime.to_iso8601(DateTime.utc_now()))
      |> Librarian.Json.encode()

    File.write!(path, line <> "\n", [:append])
    :ok
  end

  def read_insights(limit \\ 10) do
    path = Path.join(@dir, "insights.jsonl")

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case Librarian.Json.decode(line) do
          {:ok, map} -> map
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(-limit)
      |> Enum.reverse()
    else
      []
    end
  end

  def archive(%Librarian.WarmStore.Memory{} = memory) do
    File.mkdir_p!(@dir)
    path = bucket_path(memory.bucket)

    line =
      Librarian.Json.encode(%{
        "id" => memory.id,
        "bucket" => memory.bucket,
        "summary" => memory.summary,
        "facts" => memory.facts,
        "tags" => memory.tags,
        "importance" => memory.importance,
        "created_at" => DateTime.to_iso8601(memory.created_at),
        "archived_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

    File.write!(path, line <> "\n", [:append])
    :ok
  end

  def read_bucket(bucket) do
    path = bucket_path(bucket)

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case Librarian.Json.decode(line) do
          {:ok, map} -> map
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  def search(query) do
    @dir
    |> list_bucket_files()
    |> Enum.flat_map(fn bucket -> read_bucket(bucket) end)
    |> Enum.filter(fn m ->
      q = String.downcase(query)
      String.contains?(String.downcase(m["summary"] || ""), q)
    end)
  end

  defp list_bucket_files(dir) do
    case File.ls(dir) do
      {:ok, files} -> files |> Enum.map(&Path.basename(&1, ".jsonl"))
      {:error, _} -> []
    end
  end

  defp bucket_path(bucket), do: Path.join(@dir, "#{bucket}.jsonl")
end

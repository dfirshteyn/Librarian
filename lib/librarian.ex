defmodule Librarian do
  @moduledoc """
  Top-level API. Accepts an optional user_id for multi-tenant isolation —
  each user's buckets are namespaced as "user_id:bucket" so they're
  completely separate GenServer processes under the same supervisor.

  Defaults to user_id "local" so all existing single-user calls work
  unchanged.
  """

  alias Librarian.{Capture, Router, HotStore, WarmStore, Flusher}

  @default_user "local"

  @doc "Ingest a payload. user_id namespaces the memory store — different users never see each other's memories."
  def ingest(map, user_id \\ @default_user)

  def ingest(%{} = map, user_id) when not is_struct(map) do
    case Capture.Payload.from_map(map) do
      %Capture.Payload{} = payload -> ingest(payload, user_id)
      error -> error
    end
  end

  def ingest(%Capture.Payload{} = payload, user_id) do
    {bucket, tags} = Router.route(payload, user_id)
    payload = %{payload | hint_tags: Enum.uniq(payload.hint_tags ++ tags)}

    case HotStore.put_unless_duplicate(bucket, payload) do
      {:ok, :duplicate} ->
        {:ok, bucket, :duplicate}

      {:ok, :stored} ->
        preview = String.slice(payload.raw_text, 0, 80)

        Phoenix.PubSub.broadcast(
          Librarian.PubSub,
          "ingest",
          {:ingested, bucket, payload.source, preview, user_id}
        )

        {:ok, bucket}
    end
  end

  @doc "Recall memories for a user. Synaptic jumps are cross-bucket within the same user's namespace."
  def recall(query, user_id \\ @default_user) do
    warm = WarmStore.recall(query, user_id)
    warm = Enum.map(warm, fn m -> WarmStore.get(m.id) || m end)

    related =
      case warm do
        [top | _] ->
          WarmStore.related_by_tag(top.tags,
            exclude_id: top.id,
            other_bucket_only: top.bucket,
            user_id: user_id
          )

        [] ->
          []
      end

    cold =
      if length(warm) < 3 do
        case Librarian.Curator.embed(query) do
          {:ok, embedding} ->
            Librarian.ColdStore.search_hybrid(query, embedding, user_id, 5)

          _ ->
            Librarian.ColdStore.search_fts(query, user_id)
        end
      else
        []
      end

    %{warm: warm, related: related, cold: cold}
  end

  def command("forget " <> rest, user_id), do: do_forget(rest, user_id)
  def command("flush " <> bucket, _user_id), do: Flusher.flush_bucket(String.trim(bucket))
  def command("flush all", _user_id), do: Flusher.flush_all()
  def command("status", user_id), do: status(user_id)
  def command(query, user_id), do: recall(query, user_id)
  def command(str), do: command(str, @default_user)

  defp do_forget(query, user_id) do
    WarmStore.recall(query, user_id)
    |> Enum.map(fn m ->
      WarmStore.forget(m.id)
      m.id
    end)
  end

  def status(user_id \\ @default_user) do
    prefix = user_id <> ":"
    buckets = HotStore.buckets() |> Enum.filter(&String.starts_with?(&1, prefix))

    %{
      user_id: user_id,
      hot: Map.new(buckets, fn b -> {b, HotStore.count(b)} end),
      warm_count: WarmStore.all() |> Enum.count(&String.starts_with?(&1.bucket, prefix))
    }
  end

  def morning_briefing(limit \\ 5) do
    Librarian.ColdStore.read_insights(limit)
  end
end

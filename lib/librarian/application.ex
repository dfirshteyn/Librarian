defmodule Librarian.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Librarian.BucketRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Librarian.BucketSupervisor},
      Librarian.WarmStore,
      Librarian.Repo,
      {Phoenix.PubSub, name: Librarian.PubSub},
      LibrarianWeb.Endpoint
    ]
    |> maybe_add_ws_server()

    opts = [strategy: :one_for_one, name: Librarian.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, sup} ->
        recover_pending_wals()
        {:ok, sup}
      error ->
        error
    end
  end

  defp recover_pending_wals do
    pending = Librarian.Wal.pending_buckets()

    if pending != [] do
      require Logger
      Logger.info("Librarian: replaying WAL for #{length(pending)} bucket(s): #{Enum.join(pending, ", ")}")
      Enum.each(pending, &Librarian.HotStore.ensure_started/1)
    end
  end

  defp maybe_add_ws_server(children) do
    if Application.get_env(:librarian, :start_ws_server, false) do
      port = Application.get_env(:librarian, :ws_port, 4001)
      children ++ [{Librarian.WsServer, port}]
    else
      children
    end
  end
end


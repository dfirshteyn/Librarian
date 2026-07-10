defmodule Librarian.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        {Registry, keys: :unique, name: Librarian.BucketRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: Librarian.BucketSupervisor},
        {DynamicSupervisor,
         strategy: :one_for_one, name: Librarian.ColdStore.ConnectionSupervisor},
        Librarian.WarmStore,
        Librarian.Repo,
        {Task.Supervisor, name: Librarian.TaskSupervisor},
        {Phoenix.PubSub, name: Librarian.PubSub},
        Librarian.Consolidation.AutomationServer,
        LibrarianWeb.Endpoint
      ]
      |> maybe_add_ws_server()

    # ETS tables must exist before any connections are requested
    Librarian.ColdStore.ConnectionManager.init_table()
    Librarian.RateLimiter.init()
    Librarian.Auth.Manifest.init()

    opts = [strategy: :one_for_one, name: Librarian.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, sup} ->
        recover_pending_wals()
        recover_warm_snapshot()
        {:ok, sup}

      error ->
        error
    end
  end

  defp recover_pending_wals do
    pending = Librarian.Wal.pending_buckets()

    if pending != [] do
      require Logger

      Logger.info(
        "Librarian: replaying WAL for #{length(pending)} bucket(s): #{Enum.join(pending, ", ")}"
      )

      Enum.each(pending, &Librarian.HotStore.ensure_started/1)
    end
  end

  defp recover_warm_snapshot do
    case Librarian.WarmStore.load() do
      :loaded ->
        require Logger
        Logger.info("Librarian: restored WARM memories from snapshot")

      :no_snapshot ->
        :ok
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

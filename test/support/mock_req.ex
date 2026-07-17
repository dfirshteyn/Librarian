defmodule Librarian.Test.MockReq do
  @moduledoc """
  Mock Req.Request that always returns errors for LLM HTTP calls.
  Used to force Council delegation failures in test mode without
  requiring actual LLM servers or API keys.
  """

  @doc "Returns a Req.Request with a mock plug adapter that always fails"
  def new do
    Req.new(plug: {Librarian.Test.MockReqPlug, []})
  end
end

defmodule Librarian.Test.MockReqPlug do
  @moduledoc false
  require Logger

  def start_link(_opts) do
    {:ok, self()}
  end

  def init(opts), do: opts

  def call(%Plug.Conn{} = conn, _opts) do
    # Always return connection refused error
    conn
    |> Plug.Conn.assign(:error, {:error, {:http_error, :econnrefused}})
    |> Plug.Conn.send_resp(503, "Service Unavailable")
  end
end

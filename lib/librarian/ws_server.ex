defmodule Librarian.WsServer do
  @moduledoc """
  A minimal hand-rolled WebSocket server over `:gen_tcp`. Exists only
  because this build environment can't reach hex.pm for Cowboy/Bandit.

  On a real machine, this whole module is a 20-minute job to replace
  with `Plug.Cowboy.WebSocket` or `Phoenix.Socket` — the contract stays
  identical: receive a JSON text frame shaped like a
  `Librarian.Capture.Payload`, call `Librarian.ingest/1`.

  Deliberately supports only what a browser extension's `new
  WebSocket(...)` client actually sends: single-frame, masked text
  frames. No fragmentation, no compression extensions, no ping/pong
  loop. That's enough for the hackathon demo; harden it before trusting
  it with anything else.
  """

  use GenServer
  require Logger
  import Bitwise

  def start_link(port) do
    GenServer.start_link(__MODULE__, port, name: __MODULE__)
  end

  @impl true
  def init(port) do
    {:ok, listen_socket} =
      :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true])

    Logger.info("Librarian.WsServer listening on ws://localhost:#{port}")
    pid = spawn_link(fn -> accept_loop(listen_socket) end)
    {:ok, %{port: port, listen_socket: listen_socket, acceptor: pid}}
  end

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client} ->
        spawn(fn -> handshake(client) end)
        accept_loop(listen_socket)

      {:error, reason} ->
        Logger.error("WsServer accept failed: #{inspect(reason)}")
    end
  end

  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  defp handshake(client) do
    case :gen_tcp.recv(client, 0, 5000) do
      {:ok, request} ->
        case extract_ws_key(request) do
          {:ok, key} ->
            accept_value = compute_accept(key)

            response =
              "HTTP/1.1 101 Switching Protocols\r\n" <>
                "Upgrade: websocket\r\n" <>
                "Connection: Upgrade\r\n" <>
                "Sec-WebSocket-Accept: #{accept_value}\r\n\r\n"

            :gen_tcp.send(client, response)
            :inet.setopts(client, active: false)
            frame_loop(client)

          :error ->
            :gen_tcp.close(client)
        end

      {:error, _reason} ->
        :gen_tcp.close(client)
    end
  end

  defp extract_ws_key(request) do
    request
    |> String.split("\r\n")
    |> Enum.find_value(:error, fn line ->
      case String.split(line, ": ", parts: 2) do
        ["Sec-WebSocket-Key", value] -> {:ok, String.trim(value)}
        _ -> nil
      end
    end)
  end

  defp compute_accept(key) do
    :crypto.hash(:sha, key <> @guid) |> Base.encode64()
  end

  defp frame_loop(client) do
    case :gen_tcp.recv(client, 0, :infinity) do
      {:ok, data} ->
        case decode_frame(data) do
          {:text, payload_text} ->
            handle_message(payload_text, client)
            frame_loop(client)

          :close ->
            :gen_tcp.close(client)

          :ignored ->
            frame_loop(client)
        end

      {:error, _reason} ->
        :gen_tcp.close(client)
    end
  end

  # Minimal RFC 6455 frame decode: single-frame, masked, text (0x1) or close (0x8).
  defp decode_frame(<<opcode_byte, mask_and_len, rest::binary>>) do
    opcode = opcode_byte &&& 0x0F
    masked? = (mask_and_len &&& 0x80) != 0
    len7 = mask_and_len &&& 0x7F

    {payload_len, rest} =
      case len7 do
        126 ->
          <<len::16, rest::binary>> = rest
          {len, rest}

        127 ->
          <<len::64, rest::binary>> = rest
          {len, rest}

        len ->
          {len, rest}
      end

    case opcode do
      0x8 ->
        :close

      0x1 ->
        if masked? do
          <<mask::binary-size(4), payload::binary-size(^payload_len), _::binary>> = rest
          {:text, unmask(payload, mask)}
        else
          <<payload::binary-size(^payload_len), _::binary>> = rest
          {:text, payload}
        end

      _ ->
        :ignored
    end
  end

  defp decode_frame(_), do: :ignored

  defp unmask(payload, mask) do
    mask_bytes = :binary.bin_to_list(mask)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, Enum.at(mask_bytes, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  defp handle_message(text, client) do
    case Librarian.Json.decode(text) do
      {:ok, map} ->
        case Librarian.IngestRouter.process(map, "local") do
          {:ok, bucket} ->
            send_text(client, Librarian.Json.encode(%{"ok" => true, "bucket" => bucket}))

          {:ok, bucket, chunk_count} ->
            send_text(
              client,
              Librarian.Json.encode(%{
                "ok" => true,
                "bucket" => bucket,
                "chunk_count" => chunk_count,
                "note" => "Document auto-chunked into #{chunk_count} pieces"
              })
            )

          {:error, reason} ->
            send_text(client, Librarian.Json.encode(%{"ok" => false, "error" => inspect(reason)}))
        end

      {:error, reason} ->
        send_text(
          client,
          Librarian.Json.encode(%{"ok" => false, "error" => "bad_json: #{inspect(reason)}"})
        )
    end
  end

  defp send_text(client, text) do
    len = byte_size(text)
    header = build_frame_header(len)
    :gen_tcp.send(client, [header, text])
  end

  defp build_frame_header(len) when len <= 125, do: <<0x81, len>>
  defp build_frame_header(len) when len <= 65535, do: <<0x81, 126, len::16>>
  defp build_frame_header(len), do: <<0x81, 127, len::64>>
end

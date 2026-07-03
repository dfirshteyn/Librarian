defmodule Librarian.Json do
  @moduledoc """
  Minimal, dependency-free JSON encode/decode.

  This exists only because this sandbox can't reach hex.pm to pull in
  Jason. On a real machine, delete this module and use Jason — the rest
  of the codebase only calls `Librarian.Json.encode/1` and `decode/1`,
  so swapping the implementation is a one-file change.

  Supports: strings, numbers, booleans, null, flat/nested maps, lists.
  Not spec-complete (no \\uXXXX escapes), but enough for our payloads.
  """

  # ---------- encode ----------

  def encode(value), do: IO.iodata_to_binary(do_encode(value))

  defp do_encode(nil), do: "null"
  defp do_encode(true), do: "true"
  defp do_encode(false), do: "false"
  defp do_encode(v) when is_integer(v), do: Integer.to_string(v)
  defp do_encode(v) when is_float(v), do: Float.to_string(v)
  defp do_encode(v) when is_atom(v), do: do_encode(Atom.to_string(v))

  defp do_encode(v) when is_binary(v) do
    [?", escape_string(v), ?"]
  end

  defp do_encode(v) when is_list(v) do
    items = v |> Enum.map(&do_encode/1) |> Enum.intersperse(",")
    [?[, items, ?]]
  end

  defp do_encode(v) when is_map(v) do
    items =
      v
      |> Enum.map(fn {k, val} -> [do_encode(to_string(k)), ":", do_encode(val)] end)
      |> Enum.intersperse(",")

    [?{, items, ?}]
  end

  defp escape_string(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end

  # ---------- decode ----------

  @doc "Decode a JSON binary into Elixir terms (maps/lists/strings/numbers/bool/nil)."
  def decode(binary) when is_binary(binary) do
    case parse_value(skip_ws(binary)) do
      {:ok, value, rest} ->
        case skip_ws(rest) do
          "" -> {:ok, value}
          _ -> {:error, :trailing_data}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :invalid_json}
  end

  defp skip_ws(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skip_ws(rest)
  defp skip_ws(bin), do: bin

  defp parse_value(<<"null", rest::binary>>), do: {:ok, nil, rest}
  defp parse_value(<<"true", rest::binary>>), do: {:ok, true, rest}
  defp parse_value(<<"false", rest::binary>>), do: {:ok, false, rest}
  defp parse_value(<<?", rest::binary>>), do: parse_string(rest, [])
  defp parse_value(<<?{, rest::binary>>), do: parse_object(skip_ws(rest), %{})
  defp parse_value(<<?[, rest::binary>>), do: parse_array(skip_ws(rest), [])

  defp parse_value(<<c, _::binary>> = bin) when c in ?0..?9 or c == ?- do
    parse_number(bin, [])
  end

  defp parse_value(_), do: {:error, :unexpected_token}

  defp parse_string(<<?", rest::binary>>, acc) do
    {:ok, IO.iodata_to_binary(Enum.reverse(acc)), rest}
  end

  defp parse_string(<<?\\, ?n, rest::binary>>, acc), do: parse_string(rest, [?\n | acc])
  defp parse_string(<<?\\, ?t, rest::binary>>, acc), do: parse_string(rest, [?\t | acc])
  defp parse_string(<<?\\, ?r, rest::binary>>, acc), do: parse_string(rest, [?\r | acc])
  defp parse_string(<<?\\, ?", rest::binary>>, acc), do: parse_string(rest, [?" | acc])
  defp parse_string(<<?\\, ?\\, rest::binary>>, acc), do: parse_string(rest, [?\\ | acc])
  defp parse_string(<<c, rest::binary>>, acc), do: parse_string(rest, [c | acc])
  defp parse_string(<<>>, _acc), do: {:error, :unterminated_string}

  defp parse_number(<<c, rest::binary>>, acc) when c in ?0..?9 or c in [?-, ?+, ?., ?e, ?E] do
    parse_number(rest, [c | acc])
  end

  defp parse_number(rest, acc) do
    str = acc |> Enum.reverse() |> IO.iodata_to_binary()

    num =
      if String.contains?(str, ".") or String.contains?(str, "e") or String.contains?(str, "E") do
        String.to_float(str)
      else
        String.to_integer(str)
      end

    {:ok, num, rest}
  end

  defp parse_object(<<?}, rest::binary>>, acc), do: {:ok, acc, rest}

  defp parse_object(<<?", rest::binary>>, acc) do
    with {:ok, key, rest} <- parse_string(rest, []),
         rest = skip_ws(rest),
         <<?:, rest::binary>> <- rest,
         rest = skip_ws(rest),
         {:ok, value, rest} <- parse_value(rest) do
      rest = skip_ws(rest)

      case rest do
        <<?,, rest::binary>> -> parse_object(skip_ws(rest), Map.put(acc, key, value))
        <<?}, rest::binary>> -> {:ok, Map.put(acc, key, value), rest}
        _ -> {:error, :malformed_object}
      end
    else
      _ -> {:error, :malformed_object}
    end
  end

  defp parse_object(_, _), do: {:error, :malformed_object}

  defp parse_array(<<?], rest::binary>>, acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_array(bin, acc) do
    with {:ok, value, rest} <- parse_value(bin) do
      rest = skip_ws(rest)

      case rest do
        <<?,, rest::binary>> -> parse_array(skip_ws(rest), [value | acc])
        <<?], rest::binary>> -> {:ok, Enum.reverse([value | acc]), rest}
        _ -> {:error, :malformed_array}
      end
    end
  end
end

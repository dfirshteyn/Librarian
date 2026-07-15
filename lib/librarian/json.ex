defmodule Librarian.Json do
  @moduledoc """
  Thin shim over the `glazer` NIF codec.

  Exposes the same two-function surface as the old hand-rolled parser
  (`encode/1` and `decode/1`) so no call-sites need to change.

  encode/1  — returns a binary (raises on unencodable input)
  decode/1  — returns {:ok, term} | {:error, reason}

  The `:use_nil` flag maps JSON null ↔ Elixir nil in both directions.
  """

  # :use_nil  — JSON null ↔ Elixir nil (instead of the atom :null)
  @opts [:use_nil]

  @doc "Encode an Elixir term to a JSON binary. Raises on failure."
  def encode(value) do
    :glazer_json.encode(value, @opts)
  end

  @doc "Encode an Elixir term to a JSON binary. Bang variant; raises on failure (alias of `encode/1`)."
  def encode!(value) do
    :glazer_json.encode(value, @opts)
  end

  @doc "Decode a JSON binary. Returns {:ok, term} or {:error, reason}."
  def decode(binary) when is_binary(binary) do
    :glazer_json.try_decode(binary, @opts)
  end
end

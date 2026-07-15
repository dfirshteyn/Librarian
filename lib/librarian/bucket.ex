defmodule Librarian.Bucket do
  @moduledoc """
  Centralized parse/format helpers for the WARM/Cold bucket key.

  A bucket key is a string with one of these shapes:

    - `"user:name"`            (today's form — no project)
    - `"user:project:name"`  (future 3-tier form)
    - `"name"`                (bare, when user is unknown/irrelevant)

  Parsing is centralized here so the rest of the codebase never hand-rolls
  `String.split(":")`. Crucially, `format(user, nil, name)` returns the
  *exact same* `"user:name"` string as the legacy convention, so adopting
  this module is byte-for-byte backward compatible with existing ETS snapshots
  and tests.

  `project` is optional. `project_of/1` returning `nil` is the
  "wildcard / no project" case and should be treated as "match anything"
  by any consumer (e.g. consolidation scoping).
  """

  @type t :: {user :: String.t() | nil, project :: String.t() | nil, name :: String.t()}

  @doc """
  Parse a bucket key into `{user, project, name}`.

    - `"user:project:name"` -> `{user, project, name}`
    - `"user:name"`          -> `{user, nil, name}`
    - `"name"`                -> `{nil, nil, name}`
    - anything unexpected     -> `{nil, nil, original_str}`
  """
  @spec parse(String.t()) :: t()
  def parse(str) when is_binary(str) do
    case String.split(str, ":") do
      [u, p, n] -> {u, p, n}
      [u, n] -> {u, nil, n}
      [n] -> {nil, nil, n}
      _ -> {nil, nil, str}
    end
  end

  @doc """
  Build a bucket key. When `project` is `nil`, emits the legacy
  `"user:name"` form. Otherwise `"user:project:name"`.
  """
  @spec format(String.t(), String.t() | nil, String.t()) :: String.t()
  def format(user, project \\ nil, name) when is_binary(user) and is_binary(name) do
    if project do
      "#{user}:#{project}:#{name}"
    else
      "#{user}:#{name}"
    end
  end

  @doc "User (tenant) segment of a bucket key, or `nil`."
  @spec user_of(String.t()) :: String.t() | nil
  def user_of(str) when is_binary(str), do: parse(str) |> elem(0)

  @doc "Project segment of a bucket key, or `nil` (wildcard)."
  @spec project_of(String.t()) :: String.t() | nil
  def project_of(str) when is_binary(str), do: parse(str) |> elem(1)

  @doc "Bare bucket name segment of a bucket key."
  @spec name_of(String.t()) :: String.t()
  def name_of(str) when is_binary(str), do: parse(str) |> elem(2)
end

defmodule Librarian.Curator.FailingStub do
  @moduledoc """
  A Curator behaviour implementation that always fails. Used in tests to verify
  error handling paths, particularly lock auto-release when Council fails.
  """

  @behaviour Librarian.Curator

  @impl true
  def summarize(_chunk, _opts \\ []) do
    {:error, :simulated_failure}
  end

  @impl true
  def describe_image(_image_data, _opts \\ []) do
    {:error, :simulated_failure}
  end

  # Not a behaviour callback, but used directly by Council modules
  def chat(_prompt, _opts \\ []), do: {:error, :simulated_failure}

  @impl true
  def embed(_text) do
    {:error, :simulated_failure}
  end
end

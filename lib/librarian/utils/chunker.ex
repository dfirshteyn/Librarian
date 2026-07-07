defmodule Librarian.Utils.Chunker do
  @moduledoc """
  Splits large text documents into manageable chunks for embedding.

  BGE-M3 truncates at 512 tokens, so we split into overlapping word spans
  to preserve context across chunk boundaries. Uses recursive splitting with
  configurable chunk size and overlap.
  """

  @doc """
  Splits text into manageable chunks of words with a sliding overlap.

  Each chunk includes metadata in the metadata map:
  - `chunk_index`: 0-based index of this chunk
  - `total_chunks`: Total number of chunks from this document
  - `correlation_id`: Unique ID to correlate chunks from same source

  ## Options
    - `:chunk_size` - Number of words per chunk (default: 350)
    - `:overlap` - Number of words to slide back for overlap (default: 50)
    - `:correlation_id` - Optional ID to correlate chunks (auto-generated if not provided)
  """
  def split_document(text, opts \\ [])

  def split_document(text, opts) when is_binary(text) do
    chunk_size = Keyword.get(opts, :chunk_size, 350)
    overlap = Keyword.get(opts, :overlap, 50)
    correlation_id = Keyword.get(opts, :correlation_id, generate_correlation_id())

    words = String.split(text, ~r/\s+/, trim: true)

    chunks = do_chunk(words, chunk_size, overlap, [], 0)
    total = length(chunks)

    Enum.map(chunks, fn {chunk, index} ->
      %{
        text: Enum.join(chunk, " "),
        metadata: %{
          chunk_index: index,
          total_chunks: total,
          correlation_id: correlation_id
        }
      }
    end)
  end

  def split_document(_, _), do: []

  defp do_chunk(words, chunk_size, _overlap, acc, index) when length(words) <= chunk_size do
    Enum.reverse([{words, index} | acc])
  end

  defp do_chunk(words, chunk_size, overlap, acc, index) do
    {chunk, _rest} = Enum.split(words, chunk_size)
    # Slide back by the overlap amount for the next starting position
    next_start = max(chunk_size - overlap, 1)
    remaining_words = Enum.drop(words, next_start)

    do_chunk(remaining_words, chunk_size, overlap, [{chunk, index} | acc], index + 1)
  end

  defp generate_correlation_id do
    "chunk_" <> (:erlang.unique_integer([:positive]) |> Integer.to_string(16))
  end
end

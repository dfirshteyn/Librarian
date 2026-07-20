defmodule Librarian.Capture.Payload do
  @moduledoc """
  The one shape every capture source produces. A source knows nothing
  about buckets, tiers, embeddings, or scoring — it just hands over raw
  text plus where/when it came from.

  Extended with file/media support:
    - `stored_path` — path/URL where the original file was saved (FileStore)
    - `dimensions` — image dimensions from ExImageInfo, e.g. "1920x1080"
    - `raw_extraction` — vision model description (images) or markdown (PDFs)
    - `original_data` — base64-encoded original file bytes (for transport/API calls)
  """

  @enforce_keys [:source, :raw_text]
  defstruct [
    :source,
    :raw_text,
    :occurred_at,
    hint_tags: [],
    metadata: %{},
    file_type: nil,
    original_filename: nil,
    parent_id: nil,
    chunk_index: nil,
    # Optional target bucket (bypasses model classification at flush time)
    target_bucket: nil,
    # File/media support
    stored_path: nil,
    dimensions: nil,
    raw_extraction: nil,
    original_data: nil
  ]

  @type t :: %__MODULE__{
          source: String.t(),
          raw_text: String.t(),
          occurred_at: DateTime.t() | nil,
          hint_tags: [String.t()],
          metadata: map(),
          file_type: String.t() | nil,
          original_filename: String.t() | nil,
          parent_id: String.t() | nil,
          chunk_index: non_neg_integer() | nil,
          stored_path: String.t() | nil,
          dimensions: String.t() | nil,
          raw_extraction: String.t() | nil,
          original_data: String.t() | nil
        }

  @doc """
  Build a payload from a plain map (e.g. decoded JSON from a websocket
  frame), filling in `occurred_at` if missing.
  """
  def from_map(%{"source" => source, "raw_text" => raw_text} = map) do
    %__MODULE__{
      source: source,
      raw_text: raw_text,
      occurred_at: parse_time(map["occurred_at"]) || DateTime.utc_now(),
      hint_tags: map["hint_tags"] || [],
      metadata: map["metadata"] || %{},
      file_type: map["file_type"],
      original_filename: map["original_filename"],
      parent_id: map["parent_id"],
      chunk_index: map["chunk_index"],
      target_bucket: map["target_bucket"] || map["bucket"],
      stored_path: map["stored_path"],
      dimensions: map["dimensions"],
      raw_extraction: map["raw_extraction"],
      original_data: map["original_data"]
    }
  end

  def from_map(_), do: {:error, :missing_required_fields}

  defp parse_time(nil), do: nil

  defp parse_time(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil
end

defmodule Librarian.Capture do
  @moduledoc """
  Behaviour for capture sources. In practice most sources won't even
  implement this directly — they'll just call `Librarian.Capture.ingest/1`
  (see `Librarian` module) since the real "behaviour" that matters is the
  payload shape, not a callback module per source.

  This is kept around for sources that *do* want a supervised, named
  process of their own (e.g. a filesystem watcher that polls on a timer).
  """

  @callback init(args :: term()) :: {:ok, state :: term()} | {:error, term()}
  @callback handle_capture(state :: term()) ::
              {:ok, [Librarian.Capture.Payload.t()], state :: term()}
end

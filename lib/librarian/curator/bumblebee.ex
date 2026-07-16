defmodule Librarian.Curator.Bumblebee do
  @moduledoc """
  Pure-BEAM curator backend using Bumblebee + EXLA for both summarization
  and embedding — no external server, no API keys.

  ## Models (downloaded to `priv/models/`)

    - **FunctionGemma** (`google/functiongemma-270m-it`) — text generation for
      structured extraction (summarize/1).
    - **all-MiniLM-L6-v2** (`sentence-transformers/all-MiniLM-L6-v2`) —
      embedding model for vector generation (embed/1).

  ## Supervision

  Two `Nx.Serving` processes must be running in the application supervision
  tree (see `Librarian.Application`):

    - `FunctionGemmaRunner` — `Bumblebee.Text.generation`
    - `MiniLMEmbedderRunner` — `Bumblebee.Text.text_embedding`

  ## Config

      config :librarian,
        bumblebee_enabled: true,
        functiongemma_path: "priv/models/functiongemma",
        minilm_path: "priv/models/all-minilm"

  ## Behaviour

  Implements `Librarian.Curator` so it can be plugged in directly:

      config :librarian, curator: Librarian.Curator.Bumblebee
  """

  @behaviour Librarian.Curator

  @serving_summarizer :function_gemma_runner
  @serving_embedder :minilm_embedder_runner

  # ── Summarize (FunctionGemma) ───────────────────────────────────────

  @impl true
  def summarize(chunk) when is_list(chunk) do
    text = chunk |> Enum.map(& &1.raw_text) |> Enum.join("\n---\n")
    {prompt, _} = Librarian.LeakGuard.scrub(build_prompt(text))

    # Prepend prefill because the model only generates what comes after it
    prefill = function_call_prefill()

    case Nx.Serving.batched_run(@serving_summarizer, prompt) do
      %{results: [%{text: generated}]} ->
        # Reconstruct full function call for parsing
        full_output = prefill <> generated

        case parse_function_call(full_output) do
          {:ok, args} when is_map(args) ->
            {:ok, build_result(args)}

          {:error, reason} ->
            {:error, {reason, full_output}}
        end

      {:error, reason} ->
        {:error, {:serving_error, reason}}

      other ->
        {:error, {:unexpected_response, inspect(other)}}
    end
  end

  # ── Describe image (not supported by Bumblebee) ───────────────────────

  @impl true
  def describe_image(_image_data, _opts) do
    {:error, :vision_not_supported}
  end

  # ── Embed (all-MiniLM-L6-v2) ────────────────────────────────────────

  @impl true
  def embed(text) when is_binary(text) do
    case Nx.Serving.batched_run(@serving_embedder, text) do
      %{embedding: embedding} ->
        {:ok, Nx.to_flat_list(embedding)}

      {:error, reason} ->
        {:error, {:serving_error, reason}}

      other ->
        {:error, {:unexpected_response, inspect(other)}}
    end
  end

  # ── Prompt building ─────────────────────────────────────────────────

  @doc false
  def build_prompt(text) do
    declaration = build_declaration()
    prefill = function_call_prefill()

    "<start_of_turn>developer\n" <>
      "You are a helpful assistant. Use the `extract_memory` function to analyze text.\n" <>
      "\n" <>
      declaration <>
      "<end_of_turn>\n" <>
      "<start_of_turn>user\n" <>
      text <>
      "\n" <>
      "<end_of_turn>\n" <>
      "<start_of_turn>model\n" <>
      prefill
  end

  @doc false
  def function_call_prefill, do: "<start_function_call>call:extract_memory{"

  @doc false
  def build_declaration do
    ~s|<start_function_declaration>declaration:extract_memory{description:<escape>Extract structured metadata from text<escape>,parameters:{properties:{summary:{description:<escape>Concise sentence distilling the core idea<escape>,type:<escape>STRING<escape>},facts:{description:<escape>Short atomic fact strings (max 5)<escape>,type:<escape>ARRAY<escape>},tags:{description:<escape>3-6 lowercase keyword strings<escape>,type:<escape>ARRAY<escape>},importance:{description:<escape>Float 0.0-1.0 reflecting decision-criticality<escape>,type:<escape>NUMBER<escape>},bucket:{description:<escape>One of project,research,ideas,thoughts,finance,inbox - the single best semantic bucket; inbox only if none fit<escape>,type:<escape>STRING<escape>}},required:[<escape>summary<escape>,<escape>facts<escape>,<escape>tags<escape>,<escape>importance<escape>,<escape>bucket<escape>],type:<escape>OBJECT<escape>}}<end_function_declaration>|
  end

  # ── FunctionGemma output parsing ────────────────────────────────────

  @doc false
  def parse_function_call(text) do
    pattern = ~r/<start_function_call>call:\w+\{(.*?)\}<end_function_call>/

    case Regex.run(pattern, text) do
      [_, args_str] ->
        parse_arguments(args_str)

      _ ->
        # Fallback: model may have omitted the closing tag or been truncated
        case Regex.run(~r/<start_function_call>call:\w+\{(.*)/s, text) do
          [_, raw] ->
            # Try to close any open <escape> tag, then close the braces
            args_str = close_open_escapes(raw) |> try_close_braces()
            parse_arguments(args_str)

          _ ->
            {:error, :no_function_call_found}
        end
    end
  end

  # FunctionGemma uses <escape> as BOTH open and close delimiter.
  # An odd count means one is unclosed — append a closing <escape>.
  defp close_open_escapes(text) do
    count = length(Regex.scan(~r/<escape>/, text))

    if rem(count, 2) == 1 do
      text <> "<escape>"
    else
      text
    end
  end

  # Close any unclosed [ or { brackets (for truncated array/object output)
  defp try_close_braces(text) do
    text
    |> close_arrays_at_field_boundaries()
    |> strip_after_last_valid_token()
    |> close_brackets()
  end

  # When a truncated array like facts:[...,tags:[... hasn't been closed,
  # insert ] before the next known field to prevent cross-field leakage.
  defp close_arrays_at_field_boundaries(text) do
    known_fields = ["summary", "facts", "tags", "importance"]

    Enum.reduce(known_fields, text, fn field, acc ->
      pattern = ~r/(#{field}:\[)(.*?)(,(\w+):)/s

      Regex.replace(pattern, acc, fn _full, prefix, content, suffix, next_field ->
        if next_field in known_fields and not String.contains?(content, "]") do
          prefix <> content <> "]" <> suffix
        else
          prefix <> content <> suffix
        end
      end)
    end)
  end

  # Remove trailing partial tokens like "<start_function_response>" or incomplete tags
  defp strip_after_last_valid_token(text) do
    # Cut at any incomplete/partial special token
    case Regex.run(
           ~r/^(.*?)(?:<start_(?!function_call)|<(?!escape|\/|start_function_call))/s,
           text
         ) do
      [_, clean] -> String.trim_trailing(clean)
      _ -> text
    end
  end

  defp close_brackets(text) do
    opens = text |> String.graphemes() |> Enum.count(&(&1 == "["))
    closes = text |> String.graphemes() |> Enum.count(&(&1 == "]"))

    cond do
      opens > closes -> text <> String.duplicate("]", opens - closes) <> "}"
      true -> text <> "}"
    end
  end

  # Parse FunctionGemma's argument format:
  #   importance:1.0,summary:<escape>text</escape>,tags:[<escape>a</escape>,<escape>b</escape>]
  defp parse_arguments(""), do: {:ok, %{}}

  defp parse_arguments(args_str) do
    # Use a single regex that respects <escape> boundaries - find key:<escape>value</escape> or key:[<escape>v</escape>,...] or key:bare_number
    # This avoids splitting commas inside <escape> tags
    result =
      args_str
      |> parse_key_value_pairs()

    if map_size(result) > 0 do
      {:ok, result}
    else
      {:error, :no_function_call_found}
    end
  end

  # Parse key-value pairs from FunctionGemma output.
  # Handles: key:<escape>value</escape>, key:123.0, key:[<escape>v</escape>,<escape>v</escape>]
  defp parse_key_value_pairs(args_str) do
    %{}
    |> parse_summary(args_str)
    |> parse_importance(args_str)
    |> parse_tags(args_str)
    |> parse_facts(args_str)
    |> parse_bucket(args_str)
  end

  # FunctionGemma emits bucket as a bare word (e.g. bucket:research) or as
  # an <escape>-tagged string. Normalize via Router.normalize_bucket.
  defp parse_bucket(acc, args_str) do
    cond do
      match = Regex.run(~r/bucket:<escape>([^<]*)<escape>/, args_str) ->
        Map.put(acc, "bucket", hd(tl(match)))

      match = Regex.run(~r/bucket:(\w+)/, args_str) ->
        Map.put(acc, "bucket", hd(tl(match)))

      true ->
        acc
    end
  end

  defp parse_summary(acc, args_str) do
    case Regex.run(~r/summary:<escape>(.*?)<escape>/s, args_str) do
      [_, value] -> Map.put(acc, "summary", value)
      _ -> acc
    end
  end

  defp parse_importance(acc, args_str) do
    case Regex.run(~r/importance:(\d+(?:\.\d+)?)/, args_str) do
      [_, value] -> Map.put(acc, "importance", value)
      _ -> acc
    end
  end

  defp parse_tags(acc, args_str) do
    cond do
      String.contains?(args_str, "tags:[]") ->
        Map.put(acc, "tags", [])

      true ->
        case Regex.run(~r/tags:\[([^\]]*)\]/, args_str) do
          [_, array_value] ->
            items = extract_array_items(array_value)
            Map.put(acc, "tags", items)

          _ ->
            acc
        end
    end
  end

  defp parse_facts(acc, args_str) do
    cond do
      String.contains?(args_str, "facts:[]") ->
        Map.put(acc, "facts", [])

      true ->
        case Regex.run(~r/facts:\[([^\]]*)\]/, args_str) do
          [_, array_value] ->
            items = extract_array_items(array_value)
            Map.put(acc, "facts", items)

          _ ->
            acc
        end
    end
  end

  # Extract items from an array like [<escape>a</escape>,<escape>b</escape>] -> ["a", "b"]
  # Handles empty arrays and arrays with escape-tagged values
  defp extract_array_items(array_str) do
    array_str
    |> String.trim()
    |> then(fn str ->
      if str == "" do
        []
      else
        ~r/<escape>([^<]*)<escape>/
        |> Regex.scan(str)
        |> Enum.map(fn [_, v] -> v end)
      end
    end)
  end

  # ── Result construction ─────────────────────────────────────────────

  @doc false
  def build_result(args) do
    %Librarian.Curator.Result{
      summary: Map.get(args, "summary", ""),
      facts: Map.get(args, "facts", []) |> parse_array() |> Enum.uniq(),
      tags: Map.get(args, "tags", []) |> parse_array() |> Enum.uniq(),
      importance: to_float(Map.get(args, "importance")),
      bucket: Librarian.Router.normalize_bucket(Map.get(args, "bucket")),
      embedding: nil
    }
  end

  # The model returns escaped inline-array like "fact1,fact2,fact3" or a stringified JSON list
  defp parse_array(value) when is_list(value), do: value

  defp parse_array(value) when is_binary(value) do
    case Librarian.Json.decode(value) do
      {:ok, list} when is_list(list) -> list
      _ -> String.split(value, ",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp parse_array(_), do: []

  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v / 1

  defp to_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.5
    end
  end

  defp to_float(_), do: 0.5
end

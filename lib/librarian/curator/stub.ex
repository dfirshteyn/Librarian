defmodule Librarian.Curator.Stub do
  @moduledoc """
  A zero-dependency curator backend. No ML, no network — just heuristics,
  so the whole pipeline runs and is testable on day one without waiting
  on Bumblebee, llama.cpp, or an API key.

  Swap this out behaviour-compatibly for `Librarian.Curator.QwenApi` or
  a Bumblebee-backed module once you want real reasoning quality. The
  rest of the app never has to change.
  """

  @behaviour Librarian.Curator

  @stopwords ~w(the a an and or but if then is are was were be been being
                to of in on at for with as by from this that it its i you
                your we our they their he she his her not no do does did
                have has had will would can could should im ive dont)

  @embedding_dim 64

  @impl true
  def summarize(chunk) when is_list(chunk) do
    text =
      chunk
      |> Enum.map(& &1.raw_text)
      |> Enum.join("\n")

    sentences = split_sentences(text)
    words = tokenize(text)
    keyword_freqs = word_frequencies(words)
    first_seen = first_occurrence_order(words)

    summary = pick_summary_sentences(sentences, keyword_freqs)
    facts = pick_fact_like_sentences(sentences)
    tags = top_keywords(keyword_freqs, first_seen, 6)
    importance = score_importance(chunk, keyword_freqs)

    {:ok,
     %Librarian.Curator.Result{
       summary: summary,
       facts: facts,
       tags: tags,
       importance: importance,
       embedding: nil
     }}
  end

  @impl true
  def embed(text) when is_binary(text) do
    # Deterministic bag-of-words hashing into a fixed-size vector.
    # Crude, but gives cosine similarity *something* real to chew on
    # without pulling in a model. Swap for Bumblebee/EXLA or an API
    # embedding call later via the same callback.
    vector = List.duplicate(0.0, @embedding_dim)

    vector =
      text
      |> tokenize()
      |> Enum.reduce(vector, fn word, acc ->
        idx = :erlang.phash2(word, @embedding_dim)
        List.update_at(acc, idx, &(&1 + 1.0))
      end)

    norm = :math.sqrt(Enum.reduce(vector, 0.0, fn x, acc -> acc + x * x end))
    normalized = if norm > 0, do: Enum.map(vector, &(&1 / norm)), else: vector

    {:ok, normalized}
  end

  @doc "Cosine similarity helper, useful once you have two embeddings to compare."
  def cosine_similarity(a, b) when length(a) == length(b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    dot
  end

  # --- internals ---

  defp split_sentences(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s']/u, " ")
    |> String.split()
    |> Enum.reject(&(&1 in @stopwords or String.length(&1) < 2))
  end

  defp word_frequencies(words) do
    Enum.reduce(words, %{}, fn w, acc -> Map.update(acc, w, 1, &(&1 + 1)) end)
  end

  # Map enumeration order is not guaranteed to match first-occurrence
  # order in the source text, which silently dropped relevant tied-
  # frequency keywords (e.g. "sqlite" lost to "alternative" in testing,
  # purely because of how the map happened to enumerate). This makes the
  # tiebreak explicit and deterministic instead of incidental.
  defp first_occurrence_order(words) do
    words
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {w, idx}, acc -> Map.put_new(acc, w, idx) end)
  end

  defp pick_summary_sentences(sentences, keyword_freqs) do
    sentences
    |> Enum.map(fn s -> {s, sentence_score(s, keyword_freqs)} end)
    |> Enum.sort_by(fn {_s, score} -> -score end)
    |> Enum.take(2)
    |> Enum.map(fn {s, _} -> s end)
    |> Enum.join(" ")
    |> case do
      "" -> "(nothing substantive to summarize)"
      s -> s
    end
  end

  defp sentence_score(sentence, keyword_freqs) do
    sentence
    |> tokenize()
    |> Enum.reduce(0, fn w, acc -> acc + Map.get(keyword_freqs, w, 0) end)
  end

  # Crude "this looks like a decision/fact" filter: sentences with
  # decision-flavored verbs or explicit naming. Good enough as a stub;
  # a real model replaces this entirely.
  @fact_markers ~w(switched changed decided chose renamed fixed deployed
                   removed added rejected picked using use will is are)

  defp pick_fact_like_sentences(sentences) do
    sentences
    |> Enum.filter(fn s ->
      down = String.downcase(s)
      Enum.any?(@fact_markers, &String.contains?(down, &1))
    end)
    |> Enum.take(5)
  end

  defp top_keywords(keyword_freqs, first_seen, n) do
    keyword_freqs
    |> Enum.sort_by(fn {w, freq} -> {-freq, Map.get(first_seen, w, 999_999)} end)
    |> Enum.take(n)
    |> Enum.map(fn {w, _freq} -> w end)
  end

  defp score_importance(chunk, keyword_freqs) do
    length_signal = chunk |> Enum.map(&String.length(&1.raw_text)) |> Enum.sum() |> min(2000)
    keyword_signal = keyword_freqs |> Map.values() |> Enum.sum()

    raw = length_signal / 2000 * 0.5 + min(keyword_signal / 20, 1.0) * 0.5
    Float.round(min(raw, 1.0), 3)
  end
end

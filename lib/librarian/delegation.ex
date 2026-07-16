defmodule Librarian.Delegation do
  @moduledoc """
  Orchestrates the "Delegate to Council" → "Publish" flow for a single
  WARM memory.

  Lifecycle of a memory through this module:

    1. `delegate_to_council/2` hard-locks the memory, runs the Council
       multi-agent deliberation on it, stores the synthesis + persona takes
       on the memory, then releases the lock (or auto-releases on failure so
       the card returns to a normal WARM state — nothing is left stranded).
    2. `publish_memory/2` is ONLY allowed once `council != nil`. It:
         a. Scrubs the synthesis text through LeakGuard (separate from the
            pre-Council scrub — this runs specifically on the Judge output).
         b. Always re-embeds the scrubbed synthesis (the original embedding
            was computed on the pre-Council summary; the synthesis is the
            actual public content so the embedding must match it).
         c. Writes the Judge's advisory bucket as the node's permanent
            category (locked — no post-publish user edits).
         d. Marks the memory `published` + stores the node hash.

  Hard-lock guarantees: while `locked` is true, the consolidator sweep and
  any other mutation path skip / are blocked from touching the memory. If the
  council or publish step errors, the lock is released and the memory reverts
  to a standard WARM card (no half-applied council/publish state).

  Progress is broadcast over PubSub on the topic `delegation:<tenant_id>`
  with messages
  `{:council_progress, id, stage, pct}` and `{:publish_progress, id, stage, pct}`
  so the dashboard card can render a live loading bar.
  """

  require Logger

  @council_topic_prefix "delegation:"
  defp topic(user_id), do: @council_topic_prefix <> user_id

  # ── Delegate to Council ──────────────────────────────────────────────

  @doc """
  Send a single WARM memory to the Knowledge Council for multi-agent
  deliberation. Runs one memory at a time (per product rule: delegate is
  allowed for exactly one piece).

  Returns `{:ok, council_map}` on success, or `{:error, reason}`.
  `council_map` is `%{synthesis: string, persona_takes: %{name => take}}`.

  ## Hard-lock
  The memory is flagged `locked: true` for the duration. On success the
  synthesis is stored and the lock is released. On any failure the lock is
  released and the `council` field is left unset, so the card returns to a
  normal WARM state.
  """
  @spec delegate_to_council(integer(), String.t()) :: {:ok, map()} | {:error, term()}
  def delegate_to_council(memory_id, user_id) when is_integer(memory_id) do
    case Librarian.WarmStore.get(memory_id) do
      nil ->
        {:error, :memory_not_found}

      memory ->
        if memory.locked do
          {:error, :locked}
        else
          # Acquire hard lock
          Librarian.WarmStore.update(memory_id, %{locked: true})
          broadcast(user_id, {:council_progress, memory_id, :starting, 5})

          case Librarian.Council.deliberate_on_memory(memory_id) do
            {:ok, %{synthesis: judge_result, persona_takes: takes} = result} ->
              broadcast(user_id, {:council_progress, memory_id, :synthesizing, 80})

              # `judge_result` is the full map returned by Judge.synthesize/2:
              # %{summary:, facts:, tags:, importance:, bucket:, persona_perspectives:}
              # We unpack the actual synthesis *string* and the advisory bucket separately
              # so that is_binary(council[:synthesis]) works at publish time.
              synthesis_text =
                case judge_result do
                  %{summary: s} when is_binary(s) -> s
                  s when is_binary(s) -> s
                  _ -> ""
                end

              advisory_bucket =
                case judge_result do
                  %{bucket: b} when is_binary(b) and b != "" -> b
                  _ -> nil
                end

              council_map = %{
                synthesis: synthesis_text,
                bucket: advisory_bucket,
                persona_takes: takes,
                failures: Map.get(result, :failures, [])
              }

              Librarian.WarmStore.update(memory_id, %{
                council: council_map,
                locked: false
              })

              broadcast(user_id, {:council_progress, memory_id, :done, 100})
              {:ok, council_map}

            {:error, reason} ->
              Logger.warning("[Delegation] Council failed for ##{memory_id}: #{inspect(reason)}")
              Librarian.WarmStore.update(memory_id, %{locked: false})
              broadcast(user_id, {:council_progress, memory_id, :error, 0})
              {:error, reason}
          end
        end
    end
  end

  # ── Publish ──────────────────────────────────────────────────────────

  @doc """
  Publish a delegated (council-run) memory to the public knowledge graph.

  Allowed ONLY if the memory has a non-nil `council` with a binary synthesis
  string. The flow:

    1. Runs LeakGuard on the synthesis text (a second, separate scrub pass
       distinct from the pre-Council input scrub).
    2. **Always** re-embeds the scrubbed synthesis (not the original memory
       embedding — the synthesis is the actual public content and the vector
       must match what's displayed).
    3. Writes the Judge's advisory bucket as the node's permanent, locked
       category.
    4. Marks the memory `published` and stores the node hash.

  Returns `{:ok, hash_id}` or `{:error, reason}`.
  """
  def publish_memory(memory_id, user_id) when is_integer(memory_id) do
    memory = Librarian.WarmStore.get(memory_id)

    cond do
      is_nil(memory) ->
        {:error, :memory_not_found}

      memory.locked ->
        {:error, :locked}

      memory.published ->
        {:error, :already_published}

      !(memory.council && is_binary(memory.council[:synthesis])) ->
        {:error, :not_delegated}

      true ->
        do_publish(memory, user_id)
    end
  end

  defp do_publish(memory, user_id) do
    memory_id = memory.id
    Librarian.WarmStore.update(memory_id, %{locked: true})

    synthesis_raw = memory.council[:synthesis]

    # ── LeakGuard: scrub the Judge's synthesis text ──────────────────────
    # This is a SEPARATE scrub pass specifically on the Council judge output,
    # distinct from the pre-Council LeakGuard pass that runs on the input
    # prompt. The Judge may have surfaced detail from the source material that
    # should not go public. This is the final privacy backstop before Postgres.
    {synthesis, redaction_count} = Librarian.LeakGuard.scrub(synthesis_raw)

    if redaction_count > 0 do
      Logger.warning(
        "[Delegation] LeakGuard redacted #{redaction_count} pattern(s) from synthesis of ##{memory_id} before publish"
      )
    end

    broadcast(user_id, {:publish_progress, memory_id, :embedding, 20})

    try do
      # ── Embedding: ALWAYS re-embed the synthesis ─────────────────────────
      # The pre-Council embedding was computed on the original memory summary.
      # The synthesis is the actual public content — its embedding must match
      # what the public node displays, otherwise nearest-neighbor search in
      # search_public_graph will be silently wrong.
      case embed_synthesis(synthesis, user_id) do
        {:ok, embedding} ->
          broadcast(user_id, {:publish_progress, memory_id, :publishing, 60})

          # ── Bucket: write the Judge's advisory bucket as the permanent category
          # The Judge's suggestion becomes the node's real locked bucket at
          # publish time. No post-publish user edits allowed (the WarmStore
          # `update` here doesn't expose bucket as editable after publish).
          council_bucket =
            case memory.council[:bucket] do
              b when is_binary(b) and b != "" -> b
              _ -> bucket_bare(memory.bucket)
            end

          artifact = %{
            "summary" => synthesis,
            "importance" => memory.importance || 0.5,
            "bucket" => council_bucket,
            "tags" => memory.tags || [],
            "facts" => memory.facts || [],
            "persona_perspectives" => memory.council[:persona_takes] || %{}
          }

          publisher_hash = publisher_hash(user_id)

          case Librarian.Network.publish(artifact, embedding, publisher_hash) do
            {:ok, hash_id} ->
              # Lock the bucket permanently by writing it back to the WARM memory.
              # `published: true` blocks any further mutation paths from touching it.
              Librarian.WarmStore.update(memory_id, %{
                published: true,
                publish_hash: hash_id,
                bucket: "#{user_id}:#{council_bucket}",
                locked: false
              })

              broadcast(user_id, {:publish_progress, memory_id, :done, 100})
              {:ok, hash_id}

            other_error ->
              reason =
                case other_error do
                  {:error, reason} -> reason
                  {:error, type, reason} -> {type, reason}
                end

              Logger.warning(
                "[Delegation] Network publish failed for ##{memory_id}: #{inspect(reason)}"
              )

              Librarian.WarmStore.update(memory_id, %{locked: false})
              broadcast(user_id, {:publish_progress, memory_id, :error, 0})
              {:error, reason}
          end

        {:error, reason} ->
          Logger.warning("[Delegation] Embedding failed for ##{memory_id}: #{inspect(reason)}")
          Librarian.WarmStore.update(memory_id, %{locked: false})
          broadcast(user_id, {:publish_progress, memory_id, :error, 0})
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("[Delegation] Exception publishing ##{memory_id}: #{inspect(e)}")
        Librarian.WarmStore.update(memory_id, %{locked: false})
        broadcast(user_id, {:publish_progress, memory_id, :error, 0})
        {:error, {:exception, e}}
    end
  end

  # ── Embedding ────────────────────────────────────────────────────────

  # ALWAYS re-embed the synthesis text. The existing memory embedding was
  # computed on the original pre-Council summary; the synthesis is the actual
  # public content, and its embedding must reflect what's displayed on the
  # node. Using the old embedding would make nearest-neighbor search return
  # results based on content that isn't what's shown — a silent correctness bug.
  defp embed_synthesis(synthesis, user_id) when is_binary(synthesis) and synthesis != "" do
    curator_impl = Librarian.Curator.resolve_curator(user_id, [])

    case Librarian.Curator.embed(synthesis, curator_impl) do
      {:ok, vec} when is_list(vec) and vec != [] -> {:ok, vec}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :empty_embedding}
    end
  end

  defp embed_synthesis(_synthesis, _user_id), do: {:error, :empty_synthesis}

  # ── Helpers ─────────────────────────────────────────────────────────

  defp bucket_bare(bucket) when is_binary(bucket) do
    bucket |> String.split(":") |> List.last()
  end

  defp publisher_hash(user_id) do
    :crypto.hash(:sha256, "publisher:" <> user_id) |> Base.encode16(case: :lower)
  end

  defp broadcast(user_id, msg) do
    Phoenix.PubSub.broadcast(Librarian.PubSub, topic(user_id), msg)
  end
end

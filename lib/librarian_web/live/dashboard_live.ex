defmodule LibrarianWeb.DashboardLive do
  use LibrarianWeb, :live_view

  import LibrarianWeb.Dashboard.Components.Header
  import LibrarianWeb.Dashboard.Components.TenantBanner
  import LibrarianWeb.Dashboard.Components.TierBar
  import LibrarianWeb.Dashboard.Components.IngestFeed
  import LibrarianWeb.Dashboard.Components.WarmCards
  import LibrarianWeb.Dashboard.Components.StructuredRecallTerminal
  import LibrarianWeb.Dashboard.Components.InsightsPanel
  import LibrarianWeb.Dashboard.Components.AncestryModal
  alias Librarian.{WarmStore, HotStore, Flusher}
  require Logger

  # ── Swarm / Flood demo texts are now located in Librarian.Demo ──

  @impl true
  def mount(_params, session, socket) do
    # Identity comes from the signed, server-verified claim persisted in the
    # session by Librarian.Auth.Plug — never from a client-supplied URL param.
    # A forged or hand-edited ?tid= simply fails verification and falls back to
    # a fresh anonymous sandbox, so tier escalation is impossible.
    tenant_id =
      case session do
        %{"sandbox_id" => sid} when is_binary(sid) and byte_size(sid) > 0 ->
          sid

        _ ->
          # Fallback (e.g. unit tests) — never happens in the browser pipeline.
          Librarian.Auth.generate_anon_id()
      end

    # Tier is part of the signed claim, so it is authentic.
    tier = Map.get(session, "tier", :anon)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Librarian.PubSub, "ingest")
      Phoenix.PubSub.subscribe(Librarian.PubSub, "flush")
      Phoenix.PubSub.subscribe(Librarian.PubSub, "delegation:#{tenant_id}")
      :timer.send_interval(2000, self(), :refresh_warm)
    end

    {:ok,
     socket
     |> stream(:feed, [])
     |> assign(:feed_empty, true)
     |> assign(:tenant_id, tenant_id)
     |> assign(:tier, tier)
     |> assign(:force_local, false)
     |> assign_memories(tenant_id)
     |> assign(:hot_counts, hot_counts(tenant_id))
     |> assign(:query, "")
     |> assign(:recall_results, nil)
     |> assign(:insights, Librarian.morning_briefing(20))
     |> assign(:token_savings, compute_token_savings(tenant_id))
     |> assign(:ingest_text, "")
     |> assign(:ingest_bucket, "inbox")
     |> assign(:expanded_memories, MapSet.new())
     |> assign(:demo_running, false)
     |> assign(:demo_total, 0)
     |> assign(:ancestry_memory_id, nil)
     |> assign(:ancestry_tree, [])
     |> assign(:structured_response, nil)
     |> assign(:council_pending, MapSet.new())
     |> assign(:publish_pending, MapSet.new())
     |> assign(:delegation_progress, %{})
     |> assign(:publish_confirm_id, nil)
     |> assign(:publish_confirm_synthesis, nil)
     |> assign(:auto_consolidation_enabled, Librarian.Consolidation.AutomationServer.enabled?())
     |> assign(:active_bucket, "all")
     |> assign(
       :flush_concurrency,
       Application.get_env(:librarian, :parallel_flush_max_concurrency, 1)
     )}
  end

  # ── PubSub handlers ─────────────────────────────────────────────────

  @impl true
  def handle_info({:ingested, bucket, source, preview, user_id}, socket) do
    entry = %{
      id: System.unique_integer([:positive, :monotonic]),
      bucket: bucket,
      source: source,
      preview: preview,
      user_id: user_id,
      at: Time.utc_now() |> Time.truncate(:second)
    }

    tid = socket.assigns.tenant_id

    {:noreply,
     socket
     |> stream_insert(:feed, entry, at: 0, limit: 50)
     |> assign(:feed_empty, false)
     |> assign(:hot_counts, hot_counts(tid))}
  end

  def handle_info({:flushed, _bucket}, socket) do
    tid = socket.assigns.tenant_id

    {:noreply,
     socket
     |> assign_memories(tid)
     |> assign(:hot_counts, hot_counts(tid))
     |> assign(:token_savings, compute_token_savings(tid))}
  end

  def handle_info({:auto_consolidation_toggled, new_val}, socket) do
    {:noreply, assign(socket, :auto_consolidation_enabled, new_val)}
  end

  def handle_info(:refresh_warm, socket) do
    tid = socket.assigns.tenant_id

    {:noreply,
     socket
     |> assign_memories(tid)
     |> assign(:hot_counts, hot_counts(tid))
     |> assign(:insights, Librarian.morning_briefing(20))
     |> assign(:token_savings, compute_token_savings(tid))}
  end

  # ── PublicGraph refresh tick ───────────────────────────────────────────
  # :timer.send_interval in a LiveComponent's mount/1 sends to self(), which
  # resolves to the *parent LiveView* PID (components share the LV process).
  # We catch the tick here and forward it to the component via send_update/2,
  # which triggers PublicGraph.update/2 and reloads graph data.
  def handle_info(:refresh_graph, socket) do
    send_update(LibrarianWeb.Dashboard.Components.PublicGraph, id: "public_graph")
    {:noreply, socket}
  end

  # ── Delegation / Publish progress ─────────────────────────────────

  def handle_info({:council_progress, id, stage, pct}, socket) do
    socket = update_progress(socket, :delegation_progress, id, stage, pct)

    socket =
      if stage == :done or stage == :error do
        socket
        |> update(:council_pending, &MapSet.delete(&1, id))
        |> assign_memories(socket.assigns.tenant_id)
      else
        update(socket, :council_pending, &MapSet.put(&1, id))
      end

    {:noreply, socket}
  end

  def handle_info({:publish_progress, id, stage, pct}, socket) do
    socket = update_progress(socket, :delegation_progress, id, stage, pct)

    socket =
      if stage == :done or stage == :error do
        socket
        |> update(:publish_pending, &MapSet.delete(&1, id))
        |> assign_memories(socket.assigns.tenant_id)
      else
        update(socket, :publish_pending, &MapSet.put(&1, id))
      end

    {:noreply, socket}
  end

  defp update_progress(socket, key, id, stage, pct) do
    current = socket.assigns[key]
    assign(socket, key, Map.put(current, id, %{stage: stage, pct: pct}))
  end

  # ── Helpers (private functions used by handle_event) ──────────────────

  defp raw_for(id_str) when is_binary(id_str) do
    case Integer.parse(id_str) do
      {int_id, ""} ->
        case Librarian.WarmStore.get(int_id) do
          nil -> nil
          mem -> mem.raw_original
        end

      _ ->
        nil
    end
  end

  defp raw_for(_), do: nil

  defp assign_memories(socket, tenant_id) do
    socket
    |> assign(:memories, all_memories(tenant_id))
    |> assign(:superseded_count, WarmStore.superseded_count_for_user(tenant_id))
    |> assign(:cold_count, Librarian.ColdStore.count(tenant_id))
  end

  defp all_memories(tenant_id) do
    WarmStore.all_for_user(tenant_id) |> Enum.reject(& &1.superseded_by)
  end

  defp hot_counts(tenant_id) do
    prefix = tenant_id <> ":"

    HotStore.buckets()
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(fn b -> {b, HotStore.count(b)} end)
    |> Enum.into(%{})
  end

  defp compute_token_savings(tenant_id) do
    memories = WarmStore.all_for_user(tenant_id) |> Enum.reject(& &1.superseded_by)

    if memories == [] do
      %{savings_pct: 0, raw_tokens: 0, curated_tokens: 0}
    else
      raw_tokens =
        memories
        |> Enum.map(fn m ->
          (String.length(m.summary || "") + String.length(Enum.join(m.facts || [], " ")))
          |> div(4)
        end)
        |> Enum.sum()

      curated_tokens =
        memories
        |> Enum.map(fn m ->
          (String.length(m.summary || "") + String.length(Enum.join(m.facts || [], " ")) +
             String.length(Enum.join(m.tags || [], " ")))
          |> div(4)
        end)
        |> Enum.sum()

      savings_pct =
        if raw_tokens > 0 do
          trunc((1 - curated_tokens / max(raw_tokens, 1)) * 100)
        else
          0
        end

      %{savings_pct: savings_pct, raw_tokens: raw_tokens, curated_tokens: curated_tokens}
    end
  end

  # ── Structured recall commands ─────────────────────────────────────

  @impl true
  def handle_event("structured_recall", %{"command" => cmd}, socket) do
    tid = socket.assigns.tenant_id

    case String.split(String.trim(cmd)) do
      ["/model" | query_parts] ->
        query = Enum.join(query_parts, " ")
        results = Librarian.recall(query, tid, force_local: socket.assigns.force_local)

        warm_mapped =
          Enum.map(results.warm, fn m ->
            %{
              id: m.id,
              bucket: m.bucket,
              summary: m.summary,
              facts: m.facts || [],
              tags: m.tags || [],
              importance: m.importance,
              created: DateTime.to_iso8601(m.created_at),
              tier: "warm"
            }
          end)

        cold_mapped =
          Enum.map(results.cold, fn m ->
            %{
              id: m.id,
              bucket: m.bucket,
              summary: m.summary,
              facts: m.facts || [],
              tags: m.tags || [],
              importance: m.importance,
              created: m.created_at,
              tier: "cold"
            }
          end)

        response = %{
          type: "model_recall",
          query: query,
          count: length(results.warm) + length(results.cold),
          memories: warm_mapped ++ cold_mapped
        }

        {:noreply, assign(socket, :structured_response, response)}

      ["/recall" | query_parts] ->
        query = Enum.join(query_parts, " ")
        results = Librarian.recall(query, tid, force_local: socket.assigns.force_local)

        response = %{
          type: "search_recall",
          query: query,
          warm_count: length(results.warm),
          related_count: length(results.related),
          cold_count: length(results.cold),
          warm: Enum.take(Enum.map(results.warm, & &1.summary), 5),
          related: Enum.take(Enum.map(results.related, & &1.summary), 3),
          cold: Enum.take(Enum.map(results.cold, & &1.summary), 3)
        }

        {:noreply, assign(socket, :structured_response, response)}

      ["/trace" | query_parts] ->
        query = Enum.join(query_parts, " ")

        result =
          Librarian.Ancestry.progressive_recall(query, tid,
            force_local: socket.assigns.force_local
          )

        response = %{
          type: "trace_recall",
          query: query,
          count: length(result.results),
          results: result.results
        }

        {:noreply, assign(socket, :structured_response, response)}

      ["/ancestry" | id_parts] ->
        id_str = Enum.join(id_parts, " ")

        response =
          case Integer.parse(String.trim(id_str)) do
            {memory_id, ""} ->
              tree = Librarian.Ancestry.get_tree(memory_id, tid)
              %{type: "ancestry_recall", memory_id: memory_id, depth: 5, tree: tree}

            _ ->
              %{type: "error", message: "Invalid /ancestry id (expected integer)"}
          end

        {:noreply, assign(socket, :structured_response, response)}

      ["/status"] ->
        status = Librarian.status(tid)
        response = %{type: "status", data: Map.delete(status, [:user_id])}
        {:noreply, assign(socket, :structured_response, response)}

      _ ->
        response = %{
          type: "error",
          message: "Unknown command. Use /model [query], /recall [query], or /status"
        }

        {:noreply, assign(socket, :structured_response, response)}
    end
  end

  # ── Event handlers ──────────────────────────────────────────────────

  @impl true
  def handle_event("recall", %{"query" => q}, socket) when byte_size(q) > 0 do
    tid = socket.assigns.tenant_id
    results = Librarian.recall(q, tid, force_local: socket.assigns.force_local)

    {:noreply,
     assign(socket, :recall_results, %{query: q, warm: results.warm, related: results.related})}
  end

  def handle_event("recall", _params, socket) do
    {:noreply, assign(socket, :recall_results, nil)}
  end

  def handle_event("flush_all", _params, socket) do
    Flusher.flush_all(socket.assigns.tenant_id, socket.assigns.flush_concurrency,
      force_local: socket.assigns.force_local
    )

    tid = socket.assigns.tenant_id

    {:noreply,
     socket
     |> assign_memories(tid)
     |> assign(:hot_counts, hot_counts(tid))
     |> assign(:token_savings, compute_token_savings(tid))
     |> put_flash(:info, "Flushed all buckets")}
  end

  def handle_event("nightly_pass", _params, socket) do
    tid = socket.assigns.tenant_id
    concurrency = socket.assigns.flush_concurrency
    force_local = socket.assigns.force_local

    Task.start(fn ->
      Flusher.flush_all(tid, concurrency, force_local: force_local)
      Flusher.nightly_pass()
      Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:flushed, :all})
    end)

    {:noreply, put_flash(socket, :info, "Nightly pass started (async)")}
  end

  def handle_event("set_flush_concurrency", %{"value" => value}, socket) do
    concurrency = String.to_integer(value)
    {:noreply, assign(socket, :flush_concurrency, concurrency)}
  end

  # Toggle: force the local 1.7B model even for judge accounts (lets you
  # show the speed/clarity difference side-by-side during the demo).
  def handle_event("toggle_force_local", _params, socket) do
    {:noreply, assign(socket, :force_local, not socket.assigns.force_local)}
  end

  # Force an explicit consolidation sweep using the tier-resolved curator.
  # Judges (and anyone not forcing local) get the premium cloud re-curation;
  # free tier uses the local model. This is the same engine the background
  # AutomationServer polls on, just triggered on-demand from the dashboard.
  def handle_event("force_consolidation", _params, socket) do
    tid = socket.assigns.tenant_id
    force_local = socket.assigns.force_local
    active_bucket = socket.assigns.active_bucket

    label =
      if active_bucket == "all",
        do: tid,
        else: "#{tid}:#{active_bucket} (bucket-scoped)"

    Task.start(fn ->
      Librarian.Consolidator.consolidate(tid,
        force_local: force_local,
        bucket_filter: (if active_bucket == "all", do: nil, else: active_bucket)
      )
      Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:flushed, tid})
    end)

    {:noreply, put_flash(socket, :info, "Consolidation sweep started for #{label}")}
  end

  # ── Bucket filter ────────────────────────────────────────────────────
  # Clicking a bucket pill sets @active_bucket which filters the WARM card
  # list without reloading the page. "all" shows every bucket.
  def handle_event("set_active_bucket", %{"bucket" => bucket}, socket) do
    {:noreply, assign(socket, :active_bucket, bucket)}
  end

  # ── Re-bucket a WARM memory ──────────────────────────────────────────
  # Lets users override the 0.6B model's bucket decision before delegation.
  # Cannot re-bucket a locked or published memory.
  def handle_event("rebucket_memory", %{"id" => id, "bucket" => new_bucket}, socket) do
    tid = socket.assigns.tenant_id
    memory_id = String.to_integer(id)

    case Librarian.WarmStore.get(memory_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Memory not found")}

      %{locked: true} ->
        {:noreply, put_flash(socket, :error, "Memory is locked — wait for delegation to finish")}

      %{published: true} ->
        {:noreply, put_flash(socket, :error, "Published memories cannot be re-bucketed")}

      _memory ->
        full_bucket = "#{tid}:#{new_bucket}"
        Librarian.WarmStore.update(memory_id, %{bucket: full_bucket})
        {:noreply,
         socket
         |> assign_memories(tid)
         |> put_flash(:info, "Moved to #{new_bucket}")}
    end
  end

  # ── Delegate to Council (single memory) ──────────────────────────
  # Runs one memory at a time. Spawns async + broadcasts live progress
  # over `delegation:#{tid}` so the card renders a loading bar. The
  # memory is hard-locked inside Librarian.Delegation for the duration.
  def handle_event("delegate_council", %{"id" => id}, socket) do
    tid = socket.assigns.tenant_id
    memory_id = String.to_integer(id)

    # Skip if already in flight (idempotent against double-clicks)
    if MapSet.member?(socket.assigns.council_pending, memory_id) do
      {:noreply, socket}
    else
      socket = update(socket, :council_pending, &MapSet.put(&1, memory_id))

      Task.start(fn ->
        case Librarian.Delegation.delegate_to_council(memory_id, tid) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Phoenix.PubSub.broadcast(
              Librarian.PubSub,
              "delegation:#{tid}",
              {:council_progress, memory_id, :error, 0}
            )

            Phoenix.LiveView.send_update(__MODULE__,
              id: "dashboard",
              flash: %{error: "Delegate failed: #{inspect(reason)}"}
            )
        end
      end)

      {:noreply, socket}
    end
  end

  # ── Publish confirm modal state ─────────────────────────────────────
  # The user must explicitly confirm publishing after seeing the actual
  # synthesis text that will go public (with a privacy warning). Clicking
  # "Publish" on the card just opens the modal; the async work only fires
  # after the user clicks "Confirm Publish" inside the modal.

  def handle_event("publish_memory", %{"id" => id}, socket) do
    memory_id = String.to_integer(id)

    # Guard: skip if already in flight or already published
    if MapSet.member?(socket.assigns.publish_pending, memory_id) do
      {:noreply, socket}
    else
      # Load the memory and open the confirm modal — do NOT publish yet.
      memory = Librarian.WarmStore.get(memory_id)

      if memory && memory.council && is_binary(memory.council[:synthesis]) do
        {:noreply,
         socket
         |> assign(:publish_confirm_id, memory_id)
         |> assign(:publish_confirm_synthesis, memory.council[:synthesis])}
      else
        {:noreply, put_flash(socket, :error, "Memory has no Council synthesis — delegate first.")}
      end
    end
  end

  def handle_event("cancel_publish", _params, socket) do
    {:noreply,
     socket
     |> assign(:publish_confirm_id, nil)
     |> assign(:publish_confirm_synthesis, nil)}
  end

  # ── Confirmed publish — this is where the actual async work fires ────
  def handle_event("confirm_publish", %{"id" => id}, socket) do
    tid = socket.assigns.tenant_id
    memory_id = String.to_integer(id)

    socket =
      socket
      |> assign(:publish_confirm_id, nil)
      |> assign(:publish_confirm_synthesis, nil)
      |> update(:publish_pending, &MapSet.put(&1, memory_id))

    Task.start(fn ->
      case Librarian.Delegation.publish_memory(memory_id, tid) do
        {:ok, hash_id} ->
          Phoenix.PubSub.broadcast(
            Librarian.PubSub,
            "delegation:#{tid}",
            {:publish_progress, memory_id, :done, 100}
          )

          Phoenix.LiveView.send_update(__MODULE__,
            id: "dashboard",
            flash: %{info: "Published to public graph (#{String.slice(hash_id, 0, 12)})"}
          )

        {:error, reason} ->
          Phoenix.PubSub.broadcast(
            Librarian.PubSub,
            "delegation:#{tid}",
            {:publish_progress, memory_id, :error, 0}
          )

          Phoenix.LiveView.send_update(__MODULE__,
            id: "dashboard",
            flash: %{error: "Publish failed: #{inspect(reason)}"}
          )
      end
    end)

    {:noreply, socket}
  end

  def handle_event("manual_ingest", %{"text" => text, "bucket" => bucket}, socket)
      when byte_size(text) > 0 do
    tid = socket.assigns.tenant_id

    case Librarian.IngestRouter.process(
           %{
             "source" => "web_ui",
             "raw_text" => text,
             "hint_tags" => [],
             "metadata" => %{}
           },
           tid
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:ingest_text, "")
         |> assign(:ingest_bucket, bucket)
         |> put_flash(:info, "Ingested to #{bucket}")}

      {:ok, _, chunk_count} ->
        {:noreply,
         socket
         |> assign(:ingest_text, "")
         |> assign(:ingest_bucket, bucket)
         |> put_flash(:info, "Ingested (auto-chunked into #{chunk_count} pieces) to #{bucket}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Ingest failed: #{inspect(reason)}")}
    end
  end

  def handle_event("manual_ingest", _params, socket) do
    {:noreply, put_flash(socket, :error, "Text required")}
  end

  def handle_event("file_upload", params, socket) do
    tid = socket.assigns.tenant_id

    case params["file"] do
      %Plug.Upload{} = upload ->
        file_content = File.read!(upload.path)
        mime_type = Librarian.Utils.FileDetector.mime_type(upload.filename)

        # Base64-encode binary files, keep text as-is
        {raw_text, file_data} =
          if String.starts_with?(mime_type, "text/") or mime_type == "application/json" do
            {file_content, nil}
          else
            {nil, Base.encode64(file_content)}
          end

        ingest_params = %{
          "source" => "file_upload",
          "raw_text" => raw_text,
          "file_data" => file_data,
          "original_filename" => upload.filename,
          "file_type" => mime_type,
          "hint_tags" => []
        }

        case Librarian.IngestRouter.process(ingest_params, tid) do
          {:ok, _bucket} ->
            {:noreply,
             socket
             |> assign(:ingest_text, "")
             |> put_flash(:info, "File uploaded")}

          {:ok, _bucket, _chunk_count} ->
            {:noreply,
             socket
             |> assign(:ingest_text, "")
             |> put_flash(:info, "File uploaded (chunked)")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Upload failed")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "No file selected")}
    end
  end

  def handle_event("toggle_memory", %{"id" => id}, socket) do
    id = String.to_integer(id)

    new_set =
      if MapSet.member?(socket.assigns.expanded_memories, id),
        do: MapSet.delete(socket.assigns.expanded_memories, id),
        else: MapSet.put(socket.assigns.expanded_memories, id)

    {:noreply, assign(socket, :expanded_memories, new_set)}
  end

  def handle_event("open_ancestry", %{"id" => id}, socket) do
    memory_id = String.to_integer(id)
    tid = socket.assigns.tenant_id
    tree = Librarian.ColdStore.get_memory_ancestry(to_string(memory_id), tid)

    # Enrich each edge with the linked raw original (progressive disclosure)
    # of its source/target nodes so the modal can disclose unedited source.
    enriched =
      Enum.map(tree, fn rel ->
        Map.merge(rel, %{
          source_raw: raw_for(rel.source_id),
          target_raw: raw_for(rel.target_id)
        })
      end)

    {:noreply, assign(socket, ancestry_memory_id: memory_id, ancestry_tree: enriched)}
  end

  def handle_event("close_ancestry", _params, socket) do
    {:noreply, assign(socket, ancestry_memory_id: nil, ancestry_tree: [])}
  end

  def handle_event("flush_bucket", %{"bucket" => bucket}, socket) do
    case Librarian.Flusher.flush_bucket(bucket, force_local: socket.assigns.force_local) do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:flushed, bucket})
        {:noreply, put_flash(socket, :info, "Flushed #{bucket}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Flush failed: #{inspect(reason)}")}
    end
  end

  def handle_event("seed_demo", _params, socket) do
    if socket.assigns.demo_running do
      {:noreply, socket}
    else
      tid = socket.assigns.tenant_id

      Task.start(fn ->
        Librarian.Demo.seed_sandbox(tid, 10)
        Phoenix.LiveView.send_update(__MODULE__, id: "dashboard", demo_running: false)
      end)

      {:noreply,
       socket
       |> assign(:demo_running, true)
       |> assign(:demo_total, 10)}
    end
  end

  def handle_event("toggle_auto_consolidation", _params, socket) do
    new_val = not socket.assigns.auto_consolidation_enabled
    Librarian.Consolidation.AutomationServer.set_enabled(new_val)
    Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:auto_consolidation_toggled, new_val})
    {:noreply, socket}
  end

  # Catch-all fallback for other events to prevent GenServer crashes (e.g. __noop)
  @impl true
  def handle_event(event, params, socket) do
    Logger.debug("Unhandled event #{inspect(event)} with params #{inspect(params)}")
    {:noreply, socket}
  end

  # ── Publish confirm modal ─────────────────────────────────────────────
  # This is the deliberate UI gate: the user sees the actual synthesis text
  # (exactly what will be written to Postgres as the public node summary)
  # before anything is committed. The privacy warning is explicit: scrubbing
  # reduces but does not guarantee zero leaked detail.

  attr(:memory_id, :integer, required: true)
  attr(:synthesis, :string, required: true)

  def publish_confirm_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/70 flex items-center justify-center z-50 p-4"
         phx-key="Escape" phx-window-keydown="cancel_publish">
      <div class="bg-gray-900 border border-emerald-600 rounded-xl shadow-2xl max-w-lg w-full p-6 space-y-4">
        <h2 class="text-sm font-bold text-emerald-400 uppercase tracking-wider">
          🌐 Confirm Publish to Public Graph
        </h2>

        <p class="text-xs text-gray-400">
          The following synthesis text will be written to the immutable public graph as
          a permanent node. <strong class="text-amber-300">Review carefully</strong> — once
          published this cannot be unpublished.
        </p>

        <div class="bg-gray-800 border border-gray-700 rounded p-3 max-h-48 overflow-y-auto">
          <p class="text-xs text-gray-200 leading-relaxed"><%= @synthesis %></p>
        </div>

        <div class="bg-amber-950/60 border border-amber-700 rounded p-3">
          <p class="text-[11px] text-amber-300 leading-relaxed">
            ⚠️ <strong>Privacy notice:</strong> LeakGuard scrubs common secret patterns
            (API keys, tokens, DB URLs) from this text before it was used by the Council.
            Scrubbing <em>reduces</em> the risk of accidental leakage but is not a guarantee
            against all personal or sensitive detail. You are responsible for the content
            you publish to the public graph.
          </p>
        </div>

        <div class="flex gap-3">
          <button phx-click="cancel_publish"
            class="flex-1 text-xs bg-gray-700 hover:bg-gray-600 text-gray-300 px-3 py-2 rounded font-bold transition">
            Cancel
          </button>
          <button phx-click="confirm_publish" phx-value-id={@memory_id}
            class="flex-1 text-xs bg-emerald-700 hover:bg-emerald-600 text-white px-3 py-2 rounded font-bold transition">
            ✅ Confirm Publish
          </button>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    # Compute per-bucket counts from the full memories list for the filter bar.
    # We do this in render (not a separate assign) so it stays in sync with
    # @memories without needing an extra broadcast cycle.
    bucket_counts =
      assigns.memories
      |> Enum.group_by(fn m -> m.bucket |> String.split(":") |> List.last() end)
      |> Map.new(fn {b, ms} -> {b, length(ms)} end)

    # The visible warm cards are filtered by active_bucket.
    # "all" shows everything; any other value filters to that bare bucket name.
    filtered_memories =
      if assigns.active_bucket == "all" do
        assigns.memories
      else
        Enum.filter(assigns.memories, fn m ->
          (m.bucket |> String.split(":") |> List.last()) == assigns.active_bucket
        end)
      end

    assigns =
      assigns
      |> assign(:bucket_counts, bucket_counts)
      |> assign(:filtered_memories, filtered_memories)

    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100 font-mono p-4">
      <.header token_savings={@token_savings} flush_concurrency={@flush_concurrency} demo_running={@demo_running} demo_total={@demo_total} />
      <.tenant_banner tenant_id={@tenant_id} tier={@tier} force_local={@force_local} />
      <.tier_bar hot_counts={@hot_counts} memories={@memories} tenant_id={@tenant_id} superseded_count={@superseded_count} cold_count={@cold_count} />

      <%!-- ── Bucket Filter Bar ─────────────────────────────────────────── --%>
      <div class="flex gap-2 mb-3 flex-wrap items-center">
        <span class="text-[10px] text-gray-500 uppercase tracking-widest mr-1">Bucket</span>

        <button phx-click="set_active_bucket" phx-value-bucket="all"
          class={"text-[11px] px-2.5 py-1 rounded-full font-bold border transition " <>
            if(@active_bucket == "all",
              do: "bg-indigo-600 border-indigo-400 text-white",
              else: "bg-gray-800 border-gray-700 text-gray-400 hover:bg-gray-700")}>
          All (<%= length(@memories) %>)
        </button>

        <%= for {bucket, count} <- Enum.sort(@bucket_counts) do %>
          <button phx-click="set_active_bucket" phx-value-bucket={bucket}
            class={"text-[11px] px-2.5 py-1 rounded-full font-bold border transition " <>
              if(@active_bucket == bucket,
                do: "bg-indigo-600 border-indigo-400 text-white",
                else: "bg-gray-800 border-gray-700 text-gray-400 hover:bg-gray-700")}>
            <%= bucket_icon(bucket) %> <%= bucket %> (<%= count %>)
          </button>
        <% end %>
      </div>

      <%!-- ── Action Controls ──────────────────────────────────────────── --%>
      <div class="flex gap-2 mb-4 items-center flex-wrap">
        <button phx-click="force_consolidation"
          class="text-xs bg-fuchsia-700 hover:bg-fuchsia-600 text-white px-3 py-1.5 rounded font-bold transition">
          <%= if @active_bucket == "all", do: "⚡ Force Consolidation Sweep", else: "⚡ Sweep: #{@active_bucket}" %>
        </button>

        <button phx-click="toggle_auto_consolidation"
          class={"text-xs px-3 py-1.5 rounded font-bold transition border " <>
            if(@auto_consolidation_enabled,
              do: "bg-fuchsia-600 hover:bg-fuchsia-500 text-white border-fuchsia-400",
              else: "bg-gray-800 hover:bg-gray-700 text-gray-400 border-gray-600")}>
          <%= if @auto_consolidation_enabled, do: "⚙️ Auto-Consolidation: ON", else: "⚙️ Auto-Consolidation: OFF" %>
        </button>

        <%= if @tier == :judge do %>
          <button phx-click="toggle_force_local"
            class={"text-xs px-3 py-1.5 rounded font-bold transition border " <>
              if(@force_local,
                do: "bg-amber-600 hover:bg-amber-500 text-white border-amber-400",
                else: "bg-violet-700 hover:bg-violet-600 text-white border-violet-500")}>
            <%= if @force_local, do: "🖥️ Local 1.7B Active", else: "☁️ Cloud Qwen API Active" %>
          </button>
        <% else %>
          <span class="text-xs text-gray-600 px-2 py-1.5 rounded border border-gray-800 select-none">
            🖥️ Local Model
          </span>
        <% end %>
      </div>

      <div class="grid grid-cols-3 gap-4 mb-4" style="height: calc(50vh - 180px);">
        <.ingest_feed tenant_id={@tenant_id} ingest_text={@ingest_text} ingest_bucket={@ingest_bucket} feed_empty={@feed_empty} streams={@streams} />
        <.warm_cards tenant_id={@tenant_id} memories={@filtered_memories} active_bucket={@active_bucket} expanded_memories={@expanded_memories} council_pending={@council_pending} publish_pending={@publish_pending} delegation_progress={@delegation_progress} />
        <.insights_panel insights={@insights} />
      </div>

      <div class="grid grid-cols-2 gap-4" style="height: calc(50vh - 160px);">
        <.structured_recall_terminal tenant_id={@tenant_id} structured_response={@structured_response} />
        <.live_component module={LibrarianWeb.Dashboard.Components.PublicGraph} id="public_graph" />
      </div>

      <%= if @ancestry_memory_id do %>
        <.ancestry_modal memory_id={@ancestry_memory_id} tenant_id={@tenant_id} ancestry={@ancestry_tree} />
      <% end %>

      <%= if @publish_confirm_id do %>
        <.publish_confirm_modal memory_id={@publish_confirm_id} synthesis={@publish_confirm_synthesis} />
      <% end %>
    </div>
    """
  end

  # ── Bucket icon helper ────────────────────────────────────────────────

  defp bucket_icon("inbox"), do: "📥"
  defp bucket_icon("project"), do: "🛠️"
  defp bucket_icon("research"), do: "🔬"
  defp bucket_icon("ideas"), do: "💡"
  defp bucket_icon("thoughts"), do: "💭"
  defp bucket_icon("finance"), do: "💰"
  defp bucket_icon(_), do: "📂"
end

defmodule LibrarianWeb.DashboardLive do
  use LibrarianWeb, :live_view

  import LibrarianWeb.Dashboard.Components.Header
  import LibrarianWeb.Dashboard.Components.ControlStrip
  import LibrarianWeb.Dashboard.Components.IngestFeed
  import LibrarianWeb.Dashboard.Components.WarmCards
  import LibrarianWeb.Dashboard.Components.StructuredRecallTerminal
  import LibrarianWeb.Dashboard.Components.DrawerControls
  import LibrarianWeb.Dashboard.Components.AncestryModal
  import LibrarianWeb.Dashboard.Components.NodeDetailModal
  alias Librarian.{WarmStore, HotStore, Flusher}
  require Logger

  @impl true
  def mount(_params, session, socket) do
    tenant_id =
      case session do
        %{"sandbox_id" => sid} when is_binary(sid) and byte_size(sid) > 0 -> sid
        _ -> Librarian.Auth.generate_anon_id()
      end

    tier = Map.get(session, "tier", :anon)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Librarian.PubSub, "ingest")
      Phoenix.PubSub.subscribe(Librarian.PubSub, "flush")
      Phoenix.PubSub.subscribe(Librarian.PubSub, "flush_progress")
      Phoenix.PubSub.subscribe(Librarian.PubSub, "delegation:#{tenant_id}")
      Phoenix.PubSub.subscribe(Librarian.PubSub, "consolidation:#{tenant_id}")
    end

    {:ok,
     socket
     |> assign(:hot_payloads, HotStore.feed_entries_for_user(tenant_id))
     |> assign(:feed_empty, false)
     |> assign(:tenant_id, tenant_id)
     |> assign(:tier, tier)
     |> assign(:force_local, false)
     |> assign_memories(tenant_id)
     |> assign(:hot_counts, hot_counts(tenant_id))
     |> assign(:telemetry, Librarian.Telemetry.snapshot(tenant_id))
     |> assign(:auto_flush_enabled, Librarian.FlushQueue.enabled?(tenant_id))
     |> assign(
       :auto_consolidation_enabled,
       Librarian.Consolidation.AutomationServer.enabled?(tenant_id)
     )
     |> assign(:nightly_pass_enabled, Librarian.TenantConfig.nightly_pass_enabled?(tenant_id))
     |> assign(:query, "")
     |> assign(:recall_results, nil)
     |> assign(:insights, Librarian.morning_briefing(20))
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
     |> assign(:flush_progress, %{})
     |> assign(:new_memories, %{})
     |> assign(:publish_confirm_id, nil)
     |> assign(:publish_confirm_synthesis, nil)
     |> assign(:active_bucket, "all")
     |> assign(:show_terminal, false)
     |> assign(:show_graph, false)
     |> assign(:show_insights, false)
     |> assign(:graph_mode, "public")
     |> assign(
       :private_count,
       length(WarmStore.all_for_user(tenant_id) |> Enum.reject(& &1.superseded_by))
     )
      |> assign(:public_count, 0)
      |> assign(:insights_drawer_count, 0)
      |> assign(:selected_node, nil)}
  end

  @impl true
  def handle_info({:ingested, _bucket, _source, _preview, _user_id}, socket) do
    tid = socket.assigns.tenant_id

    {:noreply,
     socket
     |> assign(:hot_payloads, HotStore.feed_entries_for_user(tid))
     |> assign(:hot_counts, hot_counts(tid))
     |> assign(:telemetry, Librarian.Telemetry.snapshot(tid))}
  end

  def handle_info({:flushed, _bucket, _user_id}, socket) do
    tid = socket.assigns.tenant_id
    updated_socket = assign_memories(socket, tid)

    {:noreply,
     updated_socket
     |> assign(:hot_counts, hot_counts(tid))
     |> assign(:flush_progress, %{})
     |> assign(:new_memories, %{})
     |> assign(:private_count, length(updated_socket.assigns.memories))
     |> assign(:telemetry, Librarian.Telemetry.snapshot(tid))}
  end

  def handle_info({:flush_progress, user_id, bucket, processed, total, memory}, socket) do
    # Check if this progress event is for the current tenant
    if socket.assigns.tenant_id == user_id do
      # Update flush progress for this bucket
      flush_progress =
        Map.put(socket.assigns.flush_progress, bucket, %{processed: processed, total: total})

      # Mark this memory as new (for animation)
      new_memories = Map.put(socket.assigns.new_memories, memory.id, true)

      {:noreply,
       socket |> assign(:flush_progress, flush_progress) |> assign(:new_memories, new_memories)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:auto_consolidation_toggled, new_val}, socket) do
    {:noreply, assign(socket, :auto_consolidation_enabled, new_val)}
  end

  def handle_info({:nightly_pass_toggled, new_val}, socket) do
    {:noreply, assign(socket, :nightly_pass_enabled, new_val)}
  end

  def handle_info({:spawned, count}, socket) do
    {:noreply, put_flash(socket, :info, "🔄 Consolidation started: #{count} memories")}
  end

  def handle_info({:merged, from_id, into_id, sim, _preview_a, _preview_b}, socket) do
    {:noreply,
     put_flash(socket, :info, "🔗 Merged ##{from_id} → ##{into_id} (sim: #{Float.round(sim, 2)})")}
  end

  def handle_info({:complete, survivors, merged_count}, socket) do
    msg =
      if merged_count > 0 do
        "✅ Consolidation complete: #{survivors} survivors, #{merged_count} merged"
      else
        "✅ Consolidation complete: #{survivors} survivors, no merges needed"
      end

    {:noreply,
     socket
     |> put_flash(:info, msg)
     |> assign_memories(socket.assigns.tenant_id)}
  end

  def handle_info({:complete, survivors}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "✅ Consolidation complete: #{survivors} survivors")
     |> assign_memories(socket.assigns.tenant_id)}
  end

  def handle_info(:refresh_graph, socket) do
    # Update the appropriate graph component based on mode
    cond do
      socket.assigns.show_graph and socket.assigns.graph_mode == "public" ->
        send_update(LibrarianWeb.Dashboard.Components.PublicGraph, id: "graph_overlay")

      socket.assigns.show_graph and socket.assigns.graph_mode == "private" ->
        send_update(LibrarianWeb.Dashboard.Components.PrivateGraph, id: "private_graph")

      true ->
        :ok
    end

    {:noreply, socket}
  end

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

        # Don't update public_count here - it will be lazy-loaded when graph drawer opens
      else
        update(socket, :publish_pending, &MapSet.put(&1, id))
      end

    {:noreply, socket}
  end

  defp update_progress(socket, key, id, stage, pct) do
    assign(socket, key, Map.put(socket.assigns[key], id, %{stage: stage, pct: pct}))
  end

  defp update_public_count(socket) do
    # Lazy: only update if graph drawer is currently open
    if socket.assigns.show_graph and socket.assigns.graph_mode == "public" do
      assign(socket, :public_count, length(Librarian.Network.get_graph().nodes || []))
    else
      socket
    end
  end

  @impl true
  def handle_event("toggle_terminal", _params, socket),
    do: {:noreply, assign(socket, :show_terminal, not socket.assigns.show_terminal)}

  def handle_event("toggle_graph", _params, socket) do
    socket = assign(socket, :show_graph, not socket.assigns.show_graph)
    # When opening the graph drawer, trigger the appropriate component to load data
    cond do
      socket.assigns.show_graph and socket.assigns.graph_mode == "public" ->
        send_update(LibrarianWeb.Dashboard.Components.PublicGraph, id: "graph_overlay")
        {:noreply, update_public_count(socket)}

      socket.assigns.show_graph and socket.assigns.graph_mode == "private" ->
        send_update(LibrarianWeb.Dashboard.Components.PrivateGraph, id: "private_graph")
        # Update private count immediately since we have the memories
        {:noreply, socket |> assign(:private_count, length(socket.assigns.memories))}

      true ->
        {:noreply, socket}
    end
  end

  # Update private graph when mode changes to private (and ensure drawer opens)
  def handle_event("set_graph_mode", %{"mode" => "private"}, socket) do
    socket = assign(socket, :graph_mode, "private")

    # Open the drawer if not already open and trigger graph load
    socket =
      cond do
        socket.assigns.show_graph ->
          # Drawer already open, just trigger update and set private count
          :ok =
            send_update(LibrarianWeb.Dashboard.Components.PrivateGraph,
              id: "private_graph",
              tenant_id: socket.assigns.tenant_id
            )

          socket
          |> assign(:private_count, length(socket.assigns.memories))

        true ->
          # Drawer closed, open it
          assign(socket, :show_graph, true)
      end

    {:noreply, socket}
  end

  # Update public graph when mode changes to public (and ensure drawer opens)
  def handle_event("set_graph_mode", %{"mode" => "public"}, socket) do
    socket = assign(socket, :graph_mode, "public")

    # Open the drawer if not already open and trigger graph load
    socket =
      if socket.assigns.show_graph do
        :ok = send_update(LibrarianWeb.Dashboard.Components.PublicGraph, id: "graph_overlay")
        socket
      else
        assign(socket, :show_graph, true)
      end

    {:noreply, update_public_count(socket)}
  end

  def handle_event("toggle_insights", _params, socket),
    do: {:noreply, assign(socket, :show_insights, not socket.assigns.show_insights)}

  # Removed generic set_graph_mode - now handled by specific private/public versions above

  @impl true
  def handle_event("structured_recall", %{"command" => cmd}, socket) do
    tid = socket.assigns.tenant_id

    case String.split(String.trim(cmd)) do
      ["/model" | qp] ->
        q = Enum.join(qp, " ")
        r = Librarian.recall(q, tid, force_local: socket.assigns.force_local)

        w =
          Enum.map(r.warm, fn m ->
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

        c =
          Enum.map(r.cold, fn m ->
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

        {:noreply,
         assign(socket, :structured_response, %{
           type: "model_recall",
           query: q,
           count: length(r.warm) + length(r.cold),
           memories: w ++ c
         })}

      ["/recall" | qp] ->
        q = Enum.join(qp, " ")
        r = Librarian.recall(q, tid, force_local: socket.assigns.force_local)

        {:noreply,
         assign(socket, :structured_response, %{
           type: "search_recall",
           query: q,
           warm_count: length(r.warm),
           related_count: length(r.related),
           cold_count: length(r.cold),
           warm: Enum.take(Enum.map(r.warm, & &1.summary), 5),
           related: Enum.take(Enum.map(r.related, & &1.summary), 3),
           cold: Enum.take(Enum.map(r.cold, & &1.summary), 3)
         })}

      ["/trace" | qp] ->
        q = Enum.join(qp, " ")
        r = Librarian.Ancestry.progressive_recall(q, tid, force_local: socket.assigns.force_local)

        {:noreply,
         assign(socket, :structured_response, %{
           type: "trace_recall",
           query: q,
           count: length(r.results),
           results: r.results
         })}

      ["/ancestry" | id_parts] ->
        id_str = Enum.join(id_parts, " ")

        resp =
          case Integer.parse(String.trim(id_str)) do
            {mid, ""} ->
              %{
                type: "ancestry_recall",
                memory_id: mid,
                depth: 5,
                tree: Librarian.Ancestry.get_tree(mid, tid)
              }

            _ ->
              %{type: "error", message: "Invalid /ancestry id (expected integer)"}
          end

        {:noreply, assign(socket, :structured_response, resp)}

      ["/status"] ->
        {:noreply,
         assign(socket, :structured_response, %{
           type: "status",
           data: Map.delete(Librarian.status(tid), [:user_id])
         })}

      _ ->
        {:noreply,
         assign(socket, :structured_response, %{
           type: "error",
           message: "Unknown command. Use /model [query], /recall [query], or /status"
         })}
    end
  end

  @impl true
  def handle_event("recall", %{"query" => q}, socket) when byte_size(q) > 0 do
    r = Librarian.recall(q, socket.assigns.tenant_id, force_local: socket.assigns.force_local)
    {:noreply, assign(socket, :recall_results, %{query: q, warm: r.warm, related: r.related})}
  end

  def handle_event("recall", _params, socket),
    do: {:noreply, assign(socket, :recall_results, nil)}

  def handle_event("nightly_pass", _params, socket) do
    tid = socket.assigns.tenant_id

    Task.start(fn ->
      Flusher.flush_all(tid, Application.get_env(:librarian, :parallel_flush_max_concurrency, 1),
        force_local: socket.assigns.force_local
      )

      Flusher.nightly_pass()
      Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:flushed, :all})
    end)

    {:noreply, put_flash(socket, :info, "Nightly pass started (async)")}
  end

  def handle_event("toggle_force_local", _params, socket),
    do: {:noreply, assign(socket, :force_local, not socket.assigns.force_local)}

  def handle_event("force_consolidation", _params, socket) do
    tid = socket.assigns.tenant_id
    ab = socket.assigns.active_bucket

    Task.start(fn ->
      Librarian.Consolidator.consolidate(tid,
        force_local: socket.assigns.force_local,
        bucket_filter: if(ab == "all", do: nil, else: ab)
      )

      Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:flushed, tid})
    end)

    {:noreply,
     put_flash(
       socket,
       :info,
       "Consolidation sweep started for #{if ab == "all", do: tid, else: "#{tid}:#{ab} (bucket-scoped)"}"
     )}
  end

  def handle_event("set_active_bucket", %{"bucket" => bucket}, socket),
    do: {:noreply, assign(socket, :active_bucket, bucket)}

  def handle_event("rebucket_memory", %{"id" => id, "bucket" => new_bucket}, socket) do
    mid = String.to_integer(id)

    case Librarian.WarmStore.get(mid) do
      nil ->
        {:noreply, put_flash(socket, :error, "Memory not found")}

      %{locked: true} ->
        {:noreply, put_flash(socket, :error, "Memory is locked")}

      %{published: true} ->
        {:noreply, put_flash(socket, :error, "Published memories cannot be re-bucketed")}

      _ ->
        Librarian.WarmStore.update(mid, %{bucket: "#{socket.assigns.tenant_id}:#{new_bucket}"})

        {:noreply,
         socket
         |> assign_memories(socket.assigns.tenant_id)
         |> put_flash(:info, "Moved to #{new_bucket}")}
    end
  end

  def handle_event("delete_memory", %{"id" => id}, socket) do
    mid = String.to_integer(id)

    case Librarian.WarmStore.get(mid) do
      nil ->
        {:noreply, put_flash(socket, :error, "Memory not found")}

      %{published: true} ->
        {:noreply, put_flash(socket, :error, "Published memories cannot be deleted")}

      _ ->
        case Librarian.forget_memory(mid, socket.assigns.tenant_id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign_memories(socket.assigns.tenant_id)
             |> assign(:private_count, length(socket.assigns.memories) - 1)
             |> put_flash(:info, "Memory deleted")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("delegate_council", %{"id" => id}, socket) do
    mid = String.to_integer(id)

    if MapSet.member?(socket.assigns.council_pending, mid) do
      {:noreply, socket}
    else
      socket = update(socket, :council_pending, &MapSet.put(&1, mid))

      Task.start(fn ->
        case Librarian.Delegation.delegate_to_council(mid, socket.assigns.tenant_id) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Phoenix.PubSub.broadcast(
              Librarian.PubSub,
              "delegation:#{socket.assigns.tenant_id}",
              {:council_progress, mid, :error, 0}
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

  def handle_event("publish_memory", %{"id" => id}, socket) do
    mid = String.to_integer(id)

    if MapSet.member?(socket.assigns.publish_pending, mid) do
      {:noreply, socket}
    else
      mem = Librarian.WarmStore.get(mid)

      if mem && mem.council && is_binary(mem.council[:synthesis]) do
        {:noreply,
         socket
         |> assign(:publish_confirm_id, mid)
         |> assign(:publish_confirm_synthesis, mem.council[:synthesis])}
      else
        {:noreply, put_flash(socket, :error, "Memory has no Council synthesis — delegate first.")}
      end
    end
  end

  def handle_event("cancel_publish", _params, socket),
    do:
      {:noreply,
       socket |> assign(:publish_confirm_id, nil) |> assign(:publish_confirm_synthesis, nil)}

  def handle_event("confirm_publish", %{"id" => id}, socket) do
    mid = String.to_integer(id)
    tid = socket.assigns.tenant_id

    socket =
      socket
      |> assign(:publish_confirm_id, nil)
      |> assign(:publish_confirm_synthesis, nil)
      |> update(:publish_pending, &MapSet.put(&1, mid))

    Task.start(fn ->
      case Librarian.Delegation.publish_memory(mid, tid) do
        {:ok, hash} ->
          Phoenix.PubSub.broadcast(
            Librarian.PubSub,
            "delegation:#{tid}",
            {:publish_progress, mid, :done, 100}
          )

          Phoenix.LiveView.send_update(__MODULE__,
            id: "dashboard",
            flash: %{info: "Published (#{String.slice(hash, 0, 12)})"}
          )

        {:error, reason} ->
          Phoenix.PubSub.broadcast(
            Librarian.PubSub,
            "delegation:#{tid}",
            {:publish_progress, mid, :error, 0}
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
    case Librarian.IngestRouter.process(
           %{"source" => "web_ui", "raw_text" => text, "hint_tags" => [], "metadata" => %{}},
           socket.assigns.tenant_id
         ) do
      {:ok, _} ->
        {:noreply,
         socket |> assign(:ingest_text, "") |> put_flash(:info, "Ingested to #{bucket}")}

      {:ok, _, cc} ->
        {:noreply,
         socket
         |> assign(:ingest_text, "")
         |> put_flash(:info, "Ingested (auto-chunked into #{cc} pieces) to #{bucket}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Ingest failed: #{inspect(reason)}")}
    end
  end

  def handle_event("manual_ingest", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Text required")}

  def handle_event("file_upload", params, socket) do
    case params["file"] do
      %Plug.Upload{} = upload ->
        fc = File.read!(upload.path)
        mt = Librarian.Utils.FileDetector.mime_type(upload.filename)

        {rt, fd} =
          if String.starts_with?(mt, "text/") or mt == "application/json",
            do: {fc, nil},
            else: {nil, Base.encode64(fc)}

        case Librarian.IngestRouter.process(
               %{
                 "source" => "file_upload",
                 "raw_text" => rt,
                 "file_data" => fd,
                 "original_filename" => upload.filename,
                 "file_type" => mt,
                 "hint_tags" => []
               },
               socket.assigns.tenant_id
             ) do
          {:ok, _} ->
            {:noreply, socket |> assign(:ingest_text, "") |> put_flash(:info, "File uploaded")}

          {:ok, _, _} ->
            {:noreply,
             socket |> assign(:ingest_text, "") |> put_flash(:info, "File uploaded (chunked)")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Upload failed")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "No file selected")}
    end
  end

  def handle_event("toggle_memory", %{"id" => id}, socket) do
    i = String.to_integer(id)

    {:noreply,
     assign(
       socket,
       :expanded_memories,
       if(MapSet.member?(socket.assigns.expanded_memories, i),
         do: MapSet.delete(socket.assigns.expanded_memories, i),
         else: MapSet.put(socket.assigns.expanded_memories, i)
       )
     )}
  end

  def handle_event("open_ancestry", %{"id" => id}, socket) do
    mid = String.to_integer(id)
    tid = socket.assigns.tenant_id

    {:noreply,
     assign(socket,
       ancestry_memory_id: mid,
       ancestry_tree:
         Enum.map(Librarian.ColdStore.get_memory_ancestry(to_string(mid), tid), fn rel ->
           Map.merge(rel, %{
             source_raw: raw_for(rel.source_id),
             target_raw: raw_for(rel.target_id)
           })
         end)
     )}
  end

  def handle_event("close_ancestry", _params, socket),
    do: {:noreply, assign(socket, ancestry_memory_id: nil, ancestry_tree: [])}

  def handle_event("select_private_node", %{"id" => id}, socket) do
    mid = String.to_integer(id)
    memory = Librarian.WarmStore.get(mid)

    node =
      if memory do
        %{
          type: :private,
          id: memory.id,
          summary: memory.summary || "",
          importance: memory.importance || 0.5,
          bucket: memory.bucket |> String.split(":") |> List.last(),
          tags: memory.tags || [],
          facts: memory.facts || [],
          council: memory.council,
          raw_original: memory.raw_original
        }
      end

    {:noreply, assign(socket, :selected_node, node)}
  end

  def handle_event("select_public_node", %{"id" => id}, socket) do
    node =
      case Librarian.Network.get_node(id) do
        nil ->
          nil

        public_node ->
          Map.put(public_node, :type, :public)
      end

    {:noreply, assign(socket, :selected_node, node)}
  end

  def handle_event("close_node_detail", _params, socket),
    do: {:noreply, assign(socket, :selected_node, nil)}

  def handle_event("seed_demo", _params, socket) do
    if socket.assigns.demo_running do
      {:noreply, socket}
    else
      Task.start(fn ->
        Librarian.Demo.seed_sandbox(socket.assigns.tenant_id, 10)
        Phoenix.LiveView.send_update(__MODULE__, id: "dashboard", demo_running: false)
      end)

      {:noreply, socket |> assign(:demo_running, true) |> assign(:demo_total, 10)}
    end
  end

  def handle_event("toggle_auto_consolidation", _params, socket) do
    nv = not socket.assigns.auto_consolidation_enabled
    Librarian.Consolidation.AutomationServer.set_enabled(socket.assigns.tenant_id, nv)
    Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:auto_consolidation_toggled, nv})
    {:noreply, socket}
  end

  def handle_event("toggle_auto_flush", _params, socket) do
    nv = not socket.assigns.auto_flush_enabled
    Librarian.FlushQueue.set_enabled(socket.assigns.tenant_id, nv)
    {:noreply, socket |> assign(:auto_flush_enabled, nv)}
  end

  def handle_event("toggle_nightly_pass", _params, socket) do
    nv = not socket.assigns.nightly_pass_enabled
    Librarian.TenantConfig.set(socket.assigns.tenant_id, :nightly_pass_enabled, nv)
    Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:nightly_pass_toggled, nv})
    {:noreply, socket |> assign(:nightly_pass_enabled, nv)}
  end

  def handle_event("flush_all_buckets", _params, socket) do
    tid = socket.assigns.tenant_id

    Task.start(fn ->
      # Flush with progress broadcast via FlushProgressAgent
      Flusher.flush_all(tid, 1,
        progress_callback: &Librarian.FlushProgressAgent.report_progress/4
      )

      Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:flushed, tid})
    end)

    {:noreply,
     socket
     |> assign(:flush_progress, %{})
     |> put_flash(:info, "Flush triggered")}
  end

  @impl true
  def handle_event(event, params, socket) do
    Logger.debug("Unhandled event #{inspect(event)} with params #{inspect(params)}")
    {:noreply, socket}
  end

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

  defp assign_memories(socket, tid),
    do:
      socket
      |> assign(:memories, WarmStore.all_for_user(tid) |> Enum.reject(& &1.superseded_by))
      |> assign(:superseded_count, WarmStore.superseded_count_for_user(tid))
      |> assign(:cold_count, Librarian.ColdStore.count(tid))
      |> assign(:telemetry, Librarian.Telemetry.snapshot(tid))

  defp hot_counts(tid) do
    p = tid <> ":"

    HotStore.buckets()
    |> Enum.filter(&String.starts_with?(&1, p))
    |> Enum.map(fn b -> {b, HotStore.count(b)} end)
    |> Enum.into(%{})
  end

  attr(:memory_id, :integer, required: true)
  attr(:synthesis, :string, required: true)

  def publish_confirm_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/70 flex items-center justify-center z-50 p-4" phx-key="Escape" phx-window-keydown="cancel_publish">
      <div class="bg-gray-900 border border-emerald-600 rounded-xl shadow-2xl max-w-lg w-full p-6 space-y-4">
        <h2 class="text-sm font-bold text-emerald-400 uppercase tracking-wider">🌐 Confirm Publish to Public Graph</h2>
        <p class="text-xs text-gray-400">The following synthesis text will be written to the immutable public graph as a permanent node. <strong class="text-amber-300">Review carefully</strong> — once published this cannot be unpublished.</p>
        <div class="bg-gray-800 border border-gray-700 rounded p-3 max-h-48 overflow-y-auto"><p class="text-xs text-gray-200 leading-relaxed"><%= @synthesis %></p></div>
        <div class="bg-amber-950/60 border border-amber-700 rounded p-3"><p class="text-[11px] text-amber-300 leading-relaxed">⚠️ <strong>Privacy notice:</strong> LeakGuard scrubs common secret patterns (API keys, tokens, DB URLs) from this text before it was used by the Council. Scrubbing <em>reduces</em> the risk of accidental leakage but is not a guarantee against all personal or sensitive detail. You are responsible for the content you publish to the public graph.</p></div>
        <div class="flex gap-3">
          <button phx-click="cancel_publish" class="flex-1 text-xs bg-gray-700 hover:bg-gray-600 text-gray-300 px-3 py-2 rounded font-bold transition">Cancel</button>
          <button phx-click="confirm_publish" phx-value-id={@memory_id} class="flex-1 text-xs bg-emerald-700 hover:bg-emerald-600 text-white px-3 py-2 rounded font-bold transition">✅ Confirm Publish</button>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    bucket_counts =
      assigns.memories
      |> Enum.group_by(fn m -> m.bucket |> String.split(":") |> List.last() end)
      |> Map.new(fn {b, ms} -> {b, length(ms)} end)

    filtered =
      if assigns.active_bucket == "all",
        do: assigns.memories,
        else:
          Enum.filter(assigns.memories, fn m ->
            m.bucket |> String.split(":") |> List.last() == assigns.active_bucket
          end)

    assigns =
      assigns |> assign(:bucket_counts, bucket_counts) |> assign(:filtered_memories, filtered)

    ~H"""
    <div class="h-screen bg-gray-950 text-gray-100 font-mono p-4 flex flex-col overflow-hidden">
      <.header tenant_id={@tenant_id} tier={@tier} force_local={@force_local} demo_running={@demo_running} telemetry={@telemetry} />
      <.control_strip auto_consolidation_enabled={@auto_consolidation_enabled} auto_flush_enabled={@auto_flush_enabled} nightly_pass_enabled={@nightly_pass_enabled} hot_counts={@hot_counts} active_bucket={@active_bucket} tier={@tier} force_local={@force_local} warm_count={length(@memories)} cold_count={@cold_count} />
      <div class="flex gap-2 mb-3 flex-wrap items-center">
        <span class="text-[10px] text-gray-500 uppercase tracking-widest mr-1">Lanes</span>
        <button phx-click="set_active_bucket" phx-value-bucket="all" class={"text-[11px] px-2.5 py-1 rounded-full font-bold border transition " <> if(@active_bucket == "all", do: "bg-indigo-600 border-indigo-400 text-white", else: "bg-gray-800 border-gray-700 text-gray-400 hover:bg-gray-700")}>📋 All (<%= length(@memories) %>)</button>
        <%= for {bucket, count} <- Enum.sort(@bucket_counts) do %>
          <%= if count > 0 or bucket in ["All", "inbox"] do %>
            <button phx-click="set_active_bucket" phx-value-bucket={bucket} class={"text-[11px] px-2.5 py-1 rounded-full font-bold border transition " <> if(@active_bucket == bucket, do: "bg-indigo-600 border-indigo-400 text-white", else: "bg-gray-800 border-gray-700 text-gray-400 hover:bg-gray-700")}><%= bucket_icon(bucket) %> <%= bucket %> (<%= count %>)</button>
          <% end %>
        <% end %>
      </div>
      <div class="grid grid-cols-2 gap-4 flex-1 min-h-0">
        <.ingest_feed tenant_id={@tenant_id} ingest_text={@ingest_text} ingest_bucket={@ingest_bucket} feed_empty={@feed_empty} hot_payloads={@hot_payloads} hot_counts={@hot_counts} auto_flush_enabled={@auto_flush_enabled} flush_progress={@flush_progress} />
        <.warm_cards tenant_id={@tenant_id} memories={@filtered_memories} active_bucket={@active_bucket} expanded_memories={@expanded_memories} council_pending={@council_pending} publish_pending={@publish_pending} delegation_progress={@delegation_progress} flush_progress={@flush_progress} new_memories={@new_memories} auto_consolidation_enabled={@auto_consolidation_enabled} />
      </div>
      <.drawer_controls show_terminal={@show_terminal} show_graph={@show_graph} show_insights={@show_insights} private_count={@private_count} public_count={@public_count} insights_count={@insights_drawer_count} graph_mode={@graph_mode} />
      <.structured_recall_terminal tenant_id={@tenant_id} structured_response={@structured_response} show={@show_terminal} />
      <div class={"fixed inset-0 z-40 flex items-end justify-center pointer-events-none " <> if(@show_graph, do: "", else: "hidden")}>
        <div class="absolute inset-0 bg-black/50 pointer-events-auto" phx-click="toggle_graph"></div>
        <div class={"relative w-full max-w-4xl bg-gray-900 border border-cyan-800 rounded-t-xl shadow-2xl pointer-events-auto transition-transform duration-300 " <> if(@show_graph, do: "translate-y-0 max-h-[70vh]", else: "translate-y-full")} style={if(@show_graph, do: "max-height: 70vh; overflow: hidden;", else: "")}>
          <div class="flex items-center justify-between px-4 py-3 border-b border-cyan-900">
            <div class="flex items-center gap-3">
              <h2 class="text-sm font-bold text-cyan-300 uppercase tracking-wider">🕸️ Knowledge Graph</h2>
              <div class="flex gap-1 bg-gray-800 rounded-lg p-0.5">
                <button phx-click="set_graph_mode" phx-value-mode="private" class={"text-[10px] px-2 py-0.5 rounded font-bold transition " <> if(@graph_mode == "private", do: "bg-cyan-700 text-white", else: "text-gray-400 hover:text-gray-200")}>Private</button>
                <button phx-click="set_graph_mode" phx-value-mode="public" class={"text-[10px] px-2 py-0.5 rounded font-bold transition " <> if(@graph_mode == "public", do: "bg-cyan-700 text-white", else: "text-gray-400 hover:text-gray-200")}>Public</button>
              </div>
            </div>
            <button phx-click="toggle_graph" class="text-gray-500 hover:text-gray-300 transition text-lg leading-none">✕</button>
          </div>
          <div class="p-4" style="height: calc(70vh - 52px);">
            <%= if @graph_mode == "public" do %>
              <.live_component module={LibrarianWeb.Dashboard.Components.PublicGraph} id="graph_overlay" />
            <% else %>
              <.live_component module={LibrarianWeb.Dashboard.Components.PrivateGraph} id="private_graph" tenant_id={@tenant_id} />
            <% end %>
          </div>
        </div>
      </div>
      <div class={"fixed inset-0 z-40 flex items-end justify-center pointer-events-none " <> if(@show_insights, do: "", else: "hidden")}>
        <div class="absolute inset-0 bg-black/50 pointer-events-auto" phx-click="toggle_insights"></div>
        <div class={"relative w-full max-w-3xl bg-gray-900 border border-amber-800 rounded-t-xl shadow-2xl pointer-events-auto transition-transform duration-300 max-h-[60vh] overflow-y-auto " <> if(@show_insights, do: "translate-y-0", else: "translate-y-full")}>
          <div class="flex items-center justify-between px-4 py-3 border-b border-amber-900 sticky top-0 bg-gray-900">
            <h2 class="text-sm font-bold text-amber-300 uppercase tracking-wider">✨ All Insights</h2>
            <button phx-click="toggle_insights" class="text-gray-500 hover:text-gray-300 transition text-lg leading-none">✕</button>
          </div>
          <div class="p-4 space-y-3">
            <%= if @insights == [] do %>
              <p class="text-gray-600 text-xs">No insights yet. Run the Nightly Pass to discover connections.</p>
            <% else %>
              <%= for insight <- @insights do %>
                <div class="bg-gray-800 rounded p-3 border border-gray-700">
                  <div class="flex items-center gap-2 mb-1">
                    <span class="text-xs"><%= insight_icon(insight["kind"]) %></span>
                    <span class="text-xs text-gray-400"><%= insight["kind"] %></span>
                    <span class="text-xs text-gray-600 ml-auto"><%= insight["logged_at"] %></span>
                  </div>
                  <p class="text-xs text-gray-300"><%= insight_summary(insight) %></p>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>
      <%= if @ancestry_memory_id do %><.ancestry_modal memory_id={@ancestry_memory_id} tenant_id={@tenant_id} ancestry={@ancestry_tree} /><% end %>
      <%= if @publish_confirm_id do %><.publish_confirm_modal memory_id={@publish_confirm_id} synthesis={@publish_confirm_synthesis} /><% end %>
      <%= if @selected_node do %><.node_detail_modal node={@selected_node} /><% end %>
    </div>
    """
  end

  defp bucket_icon("inbox"), do: "📥"
  defp bucket_icon("project"), do: "🛠️"
  defp bucket_icon("research"), do: "🔬"
  defp bucket_icon("ideas"), do: "💡"
  defp bucket_icon("thoughts"), do: "💭"
  defp bucket_icon("finance"), do: "💰"
  defp bucket_icon(_), do: "📂"

  defp insight_icon("supersession"), do: "🔄"
  defp insight_icon("deep_supersession"), do: "⚠️"
  defp insight_icon("deep_cross_connection"), do: "🔗"
  defp insight_icon("consolidation_started"), do: "🔄"
  defp insight_icon("consolidation_complete"), do: "✅"
  defp insight_icon("consolidation_skipped"), do: "⏭️"
  defp insight_icon(_), do: "💡"

  defp insight_summary(%{"kind" => "supersession"} = m),
    do: "Superseded: \"#{m["old_summary"]}\" → \"#{m["new_summary"]}\""

  defp insight_summary(%{"kind" => "deep_supersession"} = m),
    do: "Qwen flagged contradiction: memory ##{m["old_id"]} superseded by ##{m["new_id"]}"

  defp insight_summary(%{"kind" => "deep_cross_connection"} = m),
    do: "Qwen connected ##{m["id_a"]} ↔ ##{m["id_b"]}: #{m["note"]}"

  defp insight_summary(%{"kind" => "consolidation_started"} = m),
    do: "Consolidation started: #{m["memory_count"]} memories in flight"

  defp insight_summary(%{"kind" => "consolidation_complete"} = m),
    do: "Consolidation complete: #{m["survivor_count"]} survivors, #{m["merged_clusters"]} merged (from #{m["initial_count"]} initial)"

  defp insight_summary(%{"kind" => "consolidation_skipped"} = m),
    do: "Consolidation skipped: #{m["reason"]} (#{m["count"]})"

  defp insight_summary(m), do: inspect(m)
end

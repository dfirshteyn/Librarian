defmodule LibrarianWeb.Dashboard.Components.PrivateGraph do
  @moduledoc """
  Private graph visualization component.

  Renders a force-directed SVG graph of your private memories (WARM tier) with
  edges based on shared tags between memories. This shows your personal
  knowledge graph - how your memories connect to each other.

  Nodes are colored by bucket, sized by importance, and labeled with
  truncated summaries. Edges connect memories that share tags.
  """
  use LibrarianWeb, :live_component

  alias Librarian.WarmStore

  @impl true
  def mount(socket) do
    # Don't fetch on mount - lazy load
    {:ok, socket |> assign(:graph, nil) |> assign(:tenant_id, nil)}
  end

  @impl true
  def update(assigns, socket) do
    # If tenant_id is provided, load the graph
    tenant_id = assigns[:tenant_id] || socket.assigns[:tenant_id]

    cond do
      tenant_id == nil and socket.assigns[:tenant_id] != nil ->
        # Keep existing tenant_id if present
        {:ok, socket}

      tenant_id ->
        # Load the graph with the provided tenant_id
        {:ok, assign_graph(socket, tenant_id)}

      true ->
        {:ok, socket}
    end
  end

  @impl true
  def handle_event("refresh_graph", _params, socket) do
    tid = socket.assigns[:tenant_id]
    if tid do
      {:noreply, assign_graph(socket, tid)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_graph, socket) do
    tid = socket.assigns[:tenant_id]
    if tid do
      {:noreply, assign_graph(socket, tid)}
    else
      {:noreply, socket}
    end
  end

  defp assign_graph(socket, tenant_id) do
    graph = build_private_graph(tenant_id)
    socket
    |> assign(:graph, graph)
    |> assign(:tenant_id, tenant_id)
  end

  defp build_private_graph(user_id) do
    memories = WarmStore.all_for_user(user_id)

    # Build nodes with id, summary, importance, bucket
    nodes =
      Enum.map(memories, fn m ->
        %{
          id: m.id,
          summary: m.summary || "Untitled",
          importance: m.importance || 0.5,
          bucket: bucket_name(m.bucket),
          tags: m.tags || []
        }
      end)

    # Build edges based on shared tags (threshold: at least 1 shared tag)
    edges = build_edges_simple(memories)

    %{nodes: nodes, edges: edges}
  end

  defp build_edges_simple(memories) do
    indexed = Enum.with_index(memories)

    for {m1, idx1} <- indexed,
        {m2, _idx2} <- indexed,
        idx1 < Enum.find_index(memories, fn m -> m.id == m2.id end),
        shared = shared_tags(m1, m2),
        shared > 0 do
      %{
        source: m1.id,
        target: m2.id,
        weight: min(1.0, shared / 5.0)
      }
    end
  end

  defp shared_tags(m1, m2) do
    tags1 = MapSet.new(m1.tags || [])
    tags2 = MapSet.new(m2.tags || [])
    MapSet.intersection(tags1, tags2) |> MapSet.size()
  end

  defp bucket_name(full_bucket), do: full_bucket |> String.split(":") |> List.last()

  @impl true
  def render(assigns) do
    # Handle case where graph hasn't loaded yet
    graph = assigns[:graph] || %{nodes: [], edges: []}
    assigns = assign(assigns, :graph, graph)

    ~H"""
    <div class="bg-gray-900 border border-gray-800 rounded-lg p-3 h-full flex flex-col">
      <div class="flex justify-between items-center mb-2">
        <div class="flex items-center gap-2">
          <h3 class="text-xs font-bold text-cyan-400 uppercase tracking-wider">
            🔒 Private Knowledge Graph
          </h3>
          <button phx-click="refresh_graph" phx-target={@myself}
            class="text-[9px] bg-cyan-950/60 hover:bg-cyan-900 border border-cyan-800 text-cyan-300 px-1.5 py-0.5 rounded transition">
            🔄 Sync
          </button>
        </div>
        <span class="text-[10px] text-gray-500">
          <%= @graph.nodes |> length() %> nodes · <%= @graph.edges |> length() %> connections
        </span>
      </div>

      <div class="flex-1 relative overflow-hidden rounded bg-gray-950">
        <%= if @graph.nodes == [] do %>
          <div class="flex items-center justify-center h-full">
            <p class="text-gray-500 text-xs">No memories yet. Ingest text and delegate to Council to build your graph.</p>
          </div>
        <% else %>
          <svg viewBox="0 0 800 500" class="w-full h-full">
            <%!-- Edges --%>
            <%= for edge <- @graph.edges do %>
              <line
                x1={node_x(@graph.nodes, edge.source)}
                y1={node_y(@graph.nodes, edge.source)}
                x2={node_x(@graph.nodes, edge.target)}
                y2={node_y(@graph.nodes, edge.target)}
                stroke={edge_color(edge.weight)}
                stroke-width={edge_width(edge.weight)}
                stroke-opacity="0.3"
              />
            <% end %>

            <%!-- Nodes --%>
            <%= for node <- @graph.nodes do %>
              <g class="cursor-pointer" phx-click="select_private_node" phx-value-id={node.id}>
                <%!-- Glow --%>
                <circle
                  cx={node_x(@graph.nodes, node.id)}
                  cy={node_y(@graph.nodes, node.id)}
                  r={node_radius(node.importance) + 3}
                  fill={bucket_color(node.bucket)}
                  fill-opacity="0.1"
                />
                <%!-- Core --%>
                <circle
                  cx={node_x(@graph.nodes, node.id)}
                  cy={node_y(@graph.nodes, node.id)}
                  r={node_radius(node.importance)}
                  fill={bucket_color(node.bucket)}
                  stroke={bucket_color(node.bucket)}
                  stroke-width="1.5"
                  stroke-opacity="0.8"
                />
                <%!-- Label --%>
                <text
                  x={node_x(@graph.nodes, node.id)}
                  y={node_y(@graph.nodes, node.id) + node_radius(node.importance) + 10}
                  text-anchor="middle"
                  fill="#9CA3AF"
                  font-size="7"
                  font-family="monospace"
                >
                  <%= String.slice(node.summary, 0, 25) <> "..." %>
                </text>
              </g>
            <% end %>
          </svg>
        <% end %>
      </div>

      <%!-- Legend --%>
      <div class="flex gap-3 mt-2 text-[10px] text-gray-500 flex-wrap">
        <span class="flex items-center gap-1">
          <span class="w-2 h-2 rounded-full bg-emerald-500 inline-block"></span> inbox
        </span>
        <span class="flex items-center gap-1">
          <span class="w-2 h-2 rounded-full bg-violet-500 inline-block"></span> project
        </span>
        <span class="flex items-center gap-1">
          <span class="w-2 h-2 rounded-full bg-amber-500 inline-block"></span> research
        </span>
        <span class="flex items-center gap-1">
          <span class="w-2 h-2 rounded-full bg-rose-500 inline-block"></span> ideas
        </span>
        <span class="flex items-center gap-1">
          <span class="w-2 h-2 rounded-full bg-sky-500 inline-block"></span> thoughts
        </span>
      </div>
    </div>
    """
  end

  # ── Layout helpers (simple circular layout) ────────────────

  defp node_x(nodes, id) do
    case find_index(nodes, id) do
      nil -> 400
      idx -> 400 + 300 * :math.cos(2 * :math.pi() * idx / max(length(nodes), 1))
    end
  end

  defp node_y(nodes, id) do
    case find_index(nodes, id) do
      nil -> 250
      idx -> 250 + 200 * :math.sin(2 * :math.pi() * idx / max(length(nodes), 1))
    end
  end

  defp find_index(nodes, id) do
    Enum.find_index(nodes, fn n -> n.id == id end)
  end

  defp node_radius(importance) when is_number(importance) do
    4 + importance * 8
  end

  defp node_radius(_), do: 6

  defp bucket_color("inbox"), do: "#6366F1"
  defp bucket_color("project"), do: "#10B981"
  defp bucket_color("research"), do: "#8B5CF6"
  defp bucket_color("ideas"), do: "#F59E0B"
  defp bucket_color("thoughts"), do: "#F43F5E"
  defp bucket_color(_), do: "#6B7280"

  defp edge_color(weight) when is_number(weight) and weight > 0.6, do: "#10B981"
  defp edge_color(weight) when is_number(weight) and weight > 0.3, do: "#8B5CF6"
  defp edge_color(_), do: "#4B5563"

  defp edge_width(weight) when is_number(weight), do: 0.3 + weight * 1.0
  defp edge_width(_), do: 0.3
end

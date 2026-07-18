defmodule LibrarianWeb.Dashboard.Components.PublicGraph do
  @moduledoc """
  Public graph visualization component.

  Renders a force-directed SVG graph of the public network nodes and edges.
  Fetches data from `Librarian.Network.get_graph/0` on mount and every 30s.

  Nodes are colored by bucket, sized by importance, and labeled with
  truncated summaries. Edges are weighted by semantic similarity.
  """
  use LibrarianWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign_graph(socket)}
  end

  @impl true
  def update(_assigns, socket) do
    {:ok, assign_graph(socket)}
  end

  @impl true
  def handle_event("refresh_graph", _params, socket) do
    {:noreply, assign_graph(socket)}
  end

  def handle_info(:refresh_graph, socket) do
    {:noreply, assign_graph(socket)}
  end

  defp assign_graph(socket) do
    graph = Librarian.Network.get_graph()
    assign(socket, :graph, graph)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="bg-gray-900 border border-gray-800 rounded-lg p-3 h-full flex flex-col">
      <div class="flex justify-between items-center mb-2">
        <div class="flex items-center gap-2">
          <h3 class="text-xs font-bold text-cyan-400 uppercase tracking-wider">
            🌐 Public Knowledge Graph
          </h3>
          <button phx-click="refresh_graph" phx-target={@myself}
            class="text-[9px] bg-cyan-950/60 hover:bg-cyan-900 border border-cyan-800 text-cyan-300 px-1.5 py-0.5 rounded transition">
            🔄 Sync
          </button>
        </div>
        <span class="text-[10px] text-gray-500">
          {@graph.nodes |> length()} nodes · {@graph.edges |> length()} edges
        </span>
      </div>

      <div class="flex-1 relative overflow-hidden rounded bg-gray-950">
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
              stroke-opacity="0.4"
            />
          <% end %>

          <%!-- Nodes --%>
          <%= for {node, idx} <- Enum.with_index(@graph.nodes) do %>
            <g class="cursor-pointer" phx-click="select_public_node" phx-value-id={node.id}>
              <%!-- Glow --%>
              <circle
                cx={node_x(@graph.nodes, node.id)}
                cy={node_y(@graph.nodes, node.id)}
                r={node_radius(node.importance) + 4}
                fill={bucket_color(node.bucket)}
                fill-opacity="0.15"
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
                <%= String.slice(node.summary, 0, 30) <> "..." %>
              </text>
            </g>
          <% end %>
        </svg>
      </div>

      <%!-- Legend --%>
      <div class="flex gap-3 mt-2 text-[10px] text-gray-500 flex-wrap">
        <span class="flex items-center gap-1">
          <span class="w-2 h-2 rounded-full bg-emerald-500 inline-block"></span> project
        </span>
        <span class="flex items-center gap-1">
          <span class="w-2 h-2 rounded-full bg-violet-500 inline-block"></span> research
        </span>
        <span class="flex items-center gap-1">
          <span class="w-2 h-2 rounded-full bg-amber-500 inline-block"></span> ideas
        </span>
        <span class="flex items-center gap-1">
          <span class="w-2 h-2 rounded-full bg-rose-500 inline-block"></span> thoughts
        </span>
      </div>
    </div>
    """
  end

  # ── Layout helpers (simple circular layout for demo) ────────────────

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
    5 + importance * 10
  end

  defp node_radius(_), do: 8

  defp bucket_color("project"), do: "#10B981"
  defp bucket_color("research"), do: "#8B5CF6"
  defp bucket_color("ideas"), do: "#F59E0B"
  defp bucket_color("thoughts"), do: "#F43F5E"
  defp bucket_color(_), do: "#6B7280"

  defp edge_color(weight) when is_number(weight) and weight > 0.8, do: "#10B981"
  defp edge_color(weight) when is_number(weight) and weight > 0.6, do: "#8B5CF6"
  defp edge_color(_), do: "#4B5563"

  defp edge_width(weight) when is_number(weight), do: 0.5 + weight * 1.5
  defp edge_width(_), do: 0.5
end

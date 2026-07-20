defmodule LibrarianWeb.Dashboard.Components.NodeDetailModal do
  use Phoenix.Component

  attr(:node, :map, required: true)

  def node_detail_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center p-4"
         phx-click="close_node_detail"
         phx-window-keydown="close_node_detail"
         phx-key="escape">
      <!-- Backdrop -->
      <div class="absolute inset-0 bg-black/60 backdrop-blur-sm"></div>

      <!-- Modal card -->
      <div class="relative bg-gray-900 border border-gray-700 rounded-xl shadow-2xl w-full max-w-lg max-h-[80vh] overflow-hidden"
           phx-click="__noop">

        <!-- Header -->
        <div class="flex items-center justify-between px-5 py-3 border-b border-gray-700">
          <h3 class="text-sm font-bold text-gray-200 uppercase tracking-wider flex items-center gap-2">
            <%= if @node.type == :private do %>🔒<% else %>🌐<% end %>
            Node Detail
          </h3>
          <button phx-click="close_node_detail"
                  class="text-gray-500 hover:text-gray-300 transition text-lg leading-none">
            ✕
          </button>
        </div>

        <!-- Body -->
        <div class="px-5 py-4 overflow-y-auto max-h-[calc(80vh-56px)] space-y-4">
          <!-- ID -->
          <div>
            <span class="text-[10px] text-gray-500 uppercase tracking-wider">ID</span>
            <p class="text-xs text-gray-300 font-mono break-all mt-0.5"><%= @node.id %></p>
          </div>

          <!-- Summary -->
          <div>
            <span class="text-[10px] text-gray-500 uppercase tracking-wider">Summary</span>
            <p class="text-xs text-gray-200 mt-0.5 leading-relaxed"><%= @node.summary %></p>
          </div>

          <div class="grid grid-cols-2 gap-4">
            <!-- Bucket -->
            <div>
              <span class="text-[10px] text-gray-500 uppercase tracking-wider">Bucket</span>
              <p class="text-xs text-gray-300 mt-0.5">
                <span class="inline-block w-2 h-2 rounded-full mr-1" style={"background-color: #{bucket_color(@node.bucket)}"}></span>
                <%= @node.bucket %>
              </p>
            </div>

            <!-- Importance -->
            <div>
              <span class="text-[10px] text-gray-500 uppercase tracking-wider">Importance</span>
              <p class="text-xs text-gray-300 mt-0.5">
                <span class={"#{importance_color(@node.importance)}"}><%= Float.round(@node.importance, 3) %></span>
              </p>
            </div>
          </div>

          <!-- Type-specific fields -->
          <%= if @node.type == :private do %>
            <!-- Tags -->
            <div>
              <span class="text-[10px] text-gray-500 uppercase tracking-wider">Tags</span>
              <div class="flex flex-wrap gap-1 mt-1">
                <%= if length(@node.tags || []) > 0 do %>
                  <%= for tag <- @node.tags do %>
                    <span class="text-[10px] bg-gray-800 text-gray-400 px-1.5 py-0.5 rounded border border-gray-700"><%= tag %></span>
                  <% end %>
                <% else %>
                  <span class="text-[10px] text-gray-600">none</span>
                <% end %>
              </div>
            </div>

            <!-- Facts -->
            <div>
              <span class="text-[10px] text-gray-500 uppercase tracking-wider">Facts</span>
              <ul class="list-disc list-inside mt-1 space-y-0.5">
                <%= if length(@node.facts || []) > 0 do %>
                  <%= for fact <- @node.facts do %>
                    <li class="text-xs text-gray-400"><%= fact %></li>
                  <% end %>
                <% else %>
                  <li class="text-xs text-gray-600">none</li>
                <% end %>
              </ul>
            </div>

            <!-- Council synthesis -->
            <%= if @node.council do %>
              <div>
                <span class="text-[10px] text-violet-400 uppercase tracking-wider">🏛️ Council Synthesis</span>
                <p class="text-xs text-violet-300 mt-0.5 leading-relaxed bg-violet-950/40 border border-violet-900/50 rounded p-2"><%= @node.council[:synthesis] || @node.council["synthesis"] %></p>
              </div>
            <% end %>

            <!-- Raw original -->
            <%= if @node.raw_original do %>
              <details>
                <summary class="text-[10px] text-emerald-500 uppercase tracking-wider cursor-pointer">📄 Raw Original</summary>
                <pre class="text-[10px] text-gray-500 mt-1 p-2 bg-gray-950 rounded border border-gray-800 max-h-40 overflow-y-auto whitespace-pre-wrap"><%= @node.raw_original %></pre>
              </details>
            <% end %>
          <% else %>
            <!-- Publisher hash -->
            <div>
              <span class="text-[10px] text-gray-500 uppercase tracking-wider">Publisher</span>
              <p class="text-xs text-gray-400 font-mono mt-0.5 break-all"><%= @node.publisher_hash || "anonymous" %></p>
            </div>

            <!-- Inserted at -->
            <div>
              <span class="text-[10px] text-gray-500 uppercase tracking-wider">Published</span>
              <p class="text-xs text-gray-400 mt-0.5"><%= @node.inserted_at %></p>
            </div>

            <!-- Metadata -->
            <%= if @node.metadata && @node.metadata != %{} do %>
              <div>
                <span class="text-[10px] text-gray-500 uppercase tracking-wider">Metadata</span>
                <pre class="text-[10px] text-gray-400 mt-1 p-2 bg-gray-950 rounded border border-gray-800 max-h-32 overflow-y-auto"><%= inspect(@node.metadata, pretty: true) %></pre>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp bucket_color("inbox"), do: "#6366F1"
  defp bucket_color("project"), do: "#10B981"
  defp bucket_color("research"), do: "#8B5CF6"
  defp bucket_color("ideas"), do: "#F59E0B"
  defp bucket_color("thoughts"), do: "#F43F5E"
  defp bucket_color(_), do: "#6B7280"

  defp importance_color(i) when i >= 0.7, do: "text-emerald-400"
  defp importance_color(i) when i >= 0.4, do: "text-amber-400"
  defp importance_color(_), do: "text-gray-400"
end

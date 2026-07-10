defmodule LibrarianWeb.Dashboard.Components.AncestryModal do
  use Phoenix.Component

  import LibrarianWeb.Dashboard.Components.Helpers

  attr :memory_id, :integer, required: true
  attr :tenant_id, :string, required: true
  attr :ancestry, :list, required: true

  def ancestry_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center"
         phx-click="close_ancestry"
         phx-window-keydown="close_ancestry"
         phx-key="escape">
      <!-- Backdrop -->
      <div class="absolute inset-0 bg-black/60 backdrop-blur-sm"></div>

      <!-- Modal card -->
      <div class="relative bg-gray-900 border border-gray-700 rounded-xl shadow-2xl w-full max-w-2xl max-h-[80vh] overflow-hidden"
           phx-click="__noop">
        <!-- Header -->
        <div class="flex items-center justify-between px-6 py-4 border-b border-gray-700">
          <h3 class="text-sm font-bold text-gray-200 uppercase tracking-wider">
            🌳 Ancestry Tree — Memory #<%= @memory_id %>
          </h3>
          <button phx-click="close_ancestry"
                  class="text-gray-500 hover:text-gray-300 transition text-lg leading-none">
            ✕
          </button>
        </div>

        <!-- Body -->
        <div class="px-6 py-4 overflow-y-auto max-h-[calc(80vh-80px)] space-y-3">
          <%= if @ancestry == [] do %>
            <p class="text-gray-500 text-sm">No ancestry relationships found for this memory.</p>
          <% else %>
            <%= for {depth, rels} <- @ancestry |> Enum.group_by(& &1.depth) |> Enum.sort() do %>
              <div class="mb-4">
                <div class="flex items-center gap-2 mb-2">
                  <span class="text-xs text-gray-500 font-mono">Depth <%= depth %></span>
                  <div class="flex-1 h-px bg-gray-700"></div>
                </div>
                <div class="space-y-2 ml-4 border-l-2 border-gray-700 pl-4">
                  <%= for rel <- rels do %>
                    <div class="flex items-center gap-2 text-sm">
                      <span class="text-gray-400"><%= relationship_badge(rel.type) %></span>
                      <span class="text-gray-500">#<%= rel.source_id %></span>
                      <span class="text-gray-600">→</span>
                      <span class="text-gray-300 font-mono">#<%= rel.target_id %></span>
                      <%= if rel.metadata && rel.metadata["similarity"] do %>
                        <span class="text-gray-600 text-xs">(sim: <%= Float.round(rel.metadata["similarity"], 2) %>)</span>
                      <% end %>
                      <span class="text-gray-600 text-xs ml-auto"><%= rel.created_at %></span>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end

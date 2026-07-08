defmodule LibrarianWeb.Dashboard.Components.WarmCards do
  use Phoenix.Component

  import LibrarianWeb.Dashboard.Components.Helpers

  attr :tenant_id, :string, required: true
  attr :memories, :list, required: true
  attr :expanded_memories, :any, required: true

  def warm_cards(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg p-4 overflow-hidden flex flex-col">
      <h2 class="text-sm font-bold text-gray-300 mb-3 uppercase tracking-wider">
        🧠 WARM Memory Tier
        <span class="text-indigo-400 text-[10px]">[<%= tenant_short(@tenant_id) %>]</span>
      </h2>
      <div class="flex-1 overflow-y-auto space-y-3">
        <%= for memory <- Enum.sort_by(@memories, &(-&1.importance)) do %>
          <div class={"bg-gray-800 rounded p-3 border #{if MapSet.member?(@expanded_memories, memory.id), do: "border-blue-500", else: "border-gray-700"} cursor-pointer"}
               phx-click="toggle_memory" phx-value-id={memory.id}>
            <div class="flex items-center gap-2 mb-2">
              <span class={"w-2 h-2 rounded-full flex-shrink-0 #{bucket_color(memory.bucket)}"} />
              <span class="text-xs font-bold text-gray-200"><%= String.split(memory.bucket, ":") |> List.last() %></span>
              <span class="text-xs text-gray-500 ml-auto">#<%= memory.id %></span>
            </div>
            <p class="text-xs text-gray-300 mb-2"><%= memory.summary %></p>

            <div class="h-1 bg-gray-700 rounded mb-2">
              <div class="h-1 bg-blue-500 rounded" style={importance_pct(memory.importance)} />
            </div>

            <%= if MapSet.member?(@expanded_memories, memory.id) do %>
              <.memory_detail memory={memory} />
            <% end %>
          </div>
        <% end %>
        <p :if={@memories == []} class="text-gray-600 text-xs">
          No memories yet. Run Flood Demo or Swarm Demo to populate.
        </p>
      </div>
    </div>
    """
  end

  # ── Memory Detail (expanded card) ───────────────────────────────────

  attr :memory, :map, required: true

  def memory_detail(assigns) do
    ~H"""
    <div class="mt-2 pt-2 border-t border-gray-700 space-y-2">
      <div>
        <span class="text-xs text-gray-400">Facts:</span>
        <%= if @memory.facts && @memory.facts != [] do %>
          <ul class="text-xs text-gray-300 mt-1 space-y-1 list-disc list-inside">
            <%= for fact <- @memory.facts do %>
              <li><%= fact %></li>
            <% end %>
          </ul>
        <% else %>
          <p class="text-xs text-gray-600 mt-1">No facts extracted</p>
        <% end %>
      </div>
      <div class="flex gap-3 text-xs">
        <span class="text-gray-400">Created: <%= DateTime.to_iso8601(@memory.created_at) %></span>
        <%= if @memory.embedding do %>
          <span class="text-blue-400">🔢 Embedding: <%= length(@memory.embedding) %>-dim</span>
        <% end %>
      </div>
      <div class="text-xs">
        <span class="text-gray-400">Tags: </span>
        <%= for tag <- (@memory.tags || []) do %>
          <span class="text-xs bg-gray-700 text-gray-300 rounded px-1.5 py-0.5"><%= tag %></span>
        <% end %>
      </div>
      <%= if @memory.superseded_by do %>
        <div class="text-xs text-yellow-400">⚠️ Superseded by #<%= @memory.superseded_by %></div>
      <% end %>
    </div>
    """
  end
end

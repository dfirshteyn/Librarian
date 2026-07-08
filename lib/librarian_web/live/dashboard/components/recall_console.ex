defmodule LibrarianWeb.Dashboard.Components.RecallConsole do
  use Phoenix.Component

  import LibrarianWeb.Dashboard.Components.Helpers

  attr :tenant_id, :string, required: true
  attr :query, :string, required: true
  attr :recall_results, :any, required: true

  def recall_console(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg p-4 overflow-hidden flex flex-col">
      <h2 class="text-sm font-bold text-gray-300 mb-3 uppercase tracking-wider">
        🔍 Recall Console
        <span class="text-indigo-400 text-[10px]">[<%= tenant_short(@tenant_id) %>]</span>
      </h2>
      <form phx-submit="recall" class="mb-4">
        <div class="flex gap-2">
          <input type="text" name="query" value={@query}
            placeholder="search your memories..."
            class="flex-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm text-white placeholder-gray-500 focus:outline-none focus:border-blue-500"
            autofocus />
          <button type="submit"
            class="px-3 py-1.5 bg-blue-700 hover:bg-blue-600 rounded text-sm transition">
            Recall
          </button>
        </div>
      </form>

      <div class="flex-1 overflow-y-auto">
        <%= if @recall_results do %>
          <p class="text-xs text-gray-500 mb-3">
            "<%= @recall_results.query %>" →
            <%= length(@recall_results.warm) %> direct,
            <%= length(@recall_results.related) %> synaptic jumps
          </p>
          <%= for memory <- @recall_results.warm do %>
            <div class="bg-gray-800 rounded p-2 mb-2 border-l-2 border-blue-500">
              <div class="flex items-center gap-2 mb-1">
                <span class={"w-1.5 h-1.5 rounded-full #{bucket_color(memory.bucket)}"} />
                <span class="text-xs font-bold text-gray-200"><%= memory.bucket %></span>
                <span class="text-xs text-gray-500">score=<%= Float.round(memory.importance, 3) %></span>
              </div>
              <p class="text-xs text-gray-300 line-clamp-3"><%= memory.summary %></p>
            </div>
          <% end %>
          <%= if @recall_results.related != [] do %>
            <p class="text-xs text-yellow-500 mt-3 mb-2">⚡ Synaptic jumps (cross-bucket)</p>
            <%= for memory <- @recall_results.related do %>
              <div class="bg-gray-800 rounded p-2 mb-2 border-l-2 border-yellow-500">
                <div class="flex items-center gap-2 mb-1">
                  <span class={"w-1.5 h-1.5 rounded-full #{bucket_color(memory.bucket)}"} />
                  <span class="text-xs font-bold text-gray-200"><%= memory.bucket %></span>
                </div>
                <p class="text-xs text-gray-300 line-clamp-2"><%= memory.summary %></p>
              </div>
            <% end %>
          <% end %>
          <p :if={@recall_results.warm == []} class="text-gray-600 text-xs">
            No memories match "<%= @recall_results.query %>"
          </p>
        <% else %>
          <p class="text-gray-600 text-xs">Enter a query to search WARM memories.</p>
          <p class="text-gray-700 text-xs mt-2">
            3-way RRF: keyword + BGE-M3 vector + importance. Isolated to your session.
          </p>
        <% end %>
      </div>
    </div>
    """
  end
end

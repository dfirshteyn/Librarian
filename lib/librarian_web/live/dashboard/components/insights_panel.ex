defmodule LibrarianWeb.Dashboard.Components.InsightsPanel do
  use Phoenix.Component

  import LibrarianWeb.Dashboard.Components.Helpers

  attr(:insights, :list, required: true)

  def insights_panel(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg p-4 overflow-hidden">
      <h2 class="text-sm font-bold text-gray-300 mb-3 uppercase tracking-wider">
        ✨ Connections & Insights
        <span class="text-[10px] text-gray-500 font-normal ml-2 group relative">
          ℹ️
          <span class="absolute bottom-full left-0 mb-1 hidden group-hover:block bg-gray-800 text-[10px] text-gray-300 px-2 py-1 rounded shadow-lg whitespace-nowrap z-10 border border-gray-700">
            Cross-bucket synaptic discoveries from Council deep passes
          </span>
        </span>
      </h2>
      <div class="overflow-x-auto whitespace-nowrap pb-2 -mb-2">
        <div class="flex gap-3 inline-flex">
          <%= if @insights == [] do %>
            <div class="flex-shrink-0 w-80 bg-gray-800 rounded p-3 border border-gray-700">
              <p class="text-xs text-gray-400">
                No insights yet. Run the Nightly Pass to discover cross-bucket connections, contradictions, and patterns.
              </p>
            </div>
          <% else %>
            <%= for insight <- @insights do %>
              <div class="flex-shrink-0 w-72 bg-gray-800 rounded p-3 border border-gray-700">
                <div class="flex items-center gap-2 mb-1">
                  <span class="text-xs"><%= insight_icon(insight["kind"]) %></span>
                  <span class="text-xs text-gray-400"><%= insight["kind"] %></span>
                  <span class="text-xs text-gray-600 ml-auto"><%= insight["logged_at"] %></span>
                </div>
                <p class="text-xs text-gray-300 whitespace-normal"><%= insight_summary(insight) %></p>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end

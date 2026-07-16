defmodule LibrarianWeb.Dashboard.Components.InsightsPanel do
  use Phoenix.Component

  import LibrarianWeb.Dashboard.Components.Helpers

  attr(:insights, :list, required: true)

  def insights_panel(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg p-4 overflow-hidden flex flex-col">
      <h2 class="text-sm font-bold text-gray-300 mb-3 uppercase tracking-wider">
        🔗 Connections & Insights
      </h2>
      <div class="flex-1 overflow-y-auto space-y-3">
        <%= if @insights == [] do %>
          <p class="text-gray-600 text-xs">
            No insights yet. Run the Nightly Pass (Qwen) to discover cross-bucket connections, contradictions, and patterns.
          </p>
          <div class="bg-gray-800 rounded p-3 border border-gray-700 mt-2">
            <p class="text-xs text-gray-400">
              The Qwen deep pass analyzes all WARM memories together to find:
            </p>
            <ul class="text-xs text-gray-500 mt-2 space-y-1 list-disc list-inside">
              <li>Cross-bucket connections (synaptic jumps)</li>
              <li>Contradictions between decisions</li>
              <li>Repeated patterns across sessions</li>
              <li>Re-ranking of importance scores</li>
            </ul>
          </div>
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
    """
  end
end

defmodule LibrarianWeb.Dashboard.Components.Header do
  use Phoenix.Component

  attr :token_savings, :map, required: true
  attr :flush_concurrency, :integer, required: true
  attr :demo_running, :boolean, required: true
  attr :demo_total, :integer, required: true

  def header(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-6">
      <div>
        <h1 class="text-2xl font-bold text-white">📚 Librarian</h1>
        <p class="text-gray-400 text-sm">local-first memory daemon · BEAM/OTP</p>
      </div>
      <div class="flex items-center gap-4">
        <div class="bg-gray-800 rounded px-3 py-1.5 text-xs">
          <span class="text-gray-400">Token savings: </span>
          <span class="text-green-400 font-bold"><%= @token_savings.savings_pct %>%</span>
          <span class="text-gray-600"> | </span>
          <span class="text-gray-400"><%= @token_savings.curated_tokens %> curated</span>
        </div>
        <button phx-click="flush_all"
          class="px-3 py-1.5 bg-blue-700 hover:bg-blue-600 rounded text-sm transition">
          Flush HOT → WARM
        </button>
        <button phx-click="nightly_pass"
          class="px-3 py-1.5 bg-purple-700 hover:bg-purple-600 rounded text-sm transition">
          Nightly Pass (Qwen)
        </button>
        <select phx-change="set_flush_concurrency" name="value"
          class="bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-sm text-white focus:outline-none focus:border-blue-500">
          <%= for c <- [1, 2, 3, 4] do %>
            <option value={c} selected={@flush_concurrency == c}><%= c %>x</option>
          <% end %>
        </select>
        <button phx-click="flood_demo"
          disabled={@demo_running}
          class={if @demo_running, do: "px-3 py-1.5 rounded text-sm transition bg-gray-700 cursor-not-allowed", else: "px-3 py-1.5 rounded text-sm transition bg-green-700 hover:bg-green-600"}>
          <%= if @demo_running, do: "Running... #{@demo_total}", else: "Flood Demo" %>
        </button>
        <button phx-click="swarm_demo"
          disabled={@demo_running}
          class={if @demo_running, do: "px-3 py-1.5 rounded text-sm transition bg-gray-700 cursor-not-allowed", else: "px-3 py-1.5 rounded text-sm transition bg-amber-600 hover:bg-amber-500"}>
          <%= if @demo_running, do: "Running... #{@demo_total}", else: "🐝 Swarm Demo" %>
        </button>
      </div>
    </div>
    """
  end
end

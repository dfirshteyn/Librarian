defmodule LibrarianWeb.Dashboard.Components.DrawerControls do
  use Phoenix.Component

  attr(:show_terminal, :boolean, default: false)
  attr(:show_graph, :boolean, default: false)
  attr(:show_insights, :boolean, default: false)
  attr(:show_consolidation_history, :boolean, default: false)
  attr(:show_cold_store, :boolean, default: false)
  attr(:private_count, :integer, default: 0)
  attr(:public_count, :integer, default: 0)
  attr(:insights_count, :integer, default: 0)
  attr(:consolidation_history_count, :integer, default: 0)
  attr(:cold_store_count, :integer, default: 0)
  attr(:graph_mode, :string, default: "public")

  def drawer_controls(assigns) do
    ~H"""
    <div class="flex items-center gap-2 mt-3 border-t border-gray-800 pt-3">
      <button phx-click="toggle_terminal"
        class={"text-xs px-3 py-1.5 rounded font-bold transition border flex items-center gap-1.5 " <>
          if(@show_terminal,
            do: "bg-green-900/60 border-green-700 text-green-300",
            else: "bg-gray-800 hover:bg-gray-700 border-gray-700 text-gray-400")}>
        💻 Terminal
      </button>

      <button phx-click="set_graph_mode" phx-value-mode="private"
        id="graph-btn"
        class={"text-xs px-3 py-1.5 rounded font-bold transition border flex items-center gap-1.5 " <>
          if(@show_graph and @graph_mode == "private",
            do: "bg-cyan-900/60 border-cyan-700 text-cyan-300",
            else: "bg-gray-800 hover:bg-gray-700 border-gray-700 text-gray-400")}>
        🕸️ Graph: Private (<%= @private_count %>)
      </button>

      <button phx-click="set_graph_mode" phx-value-mode="public"
        id="public-graph-btn"
        class={"text-xs px-3 py-1.5 rounded font-bold transition border flex items-center gap-1.5 " <>
          if(@show_graph and @graph_mode == "public",
            do: "bg-cyan-900/60 border-cyan-700 text-cyan-300",
            else: "bg-gray-800 hover:bg-gray-700 border-gray-700 text-gray-400")}>
        🕸️ Graph: Public (<%= @public_count %>)
      </button>

      <button phx-click="toggle_insights"
        class={"text-xs px-3 py-1.5 rounded font-bold transition border flex items-center gap-1.5 " <>
          if(@show_insights,
            do: "bg-amber-900/60 border-amber-700 text-amber-300",
            else: "bg-gray-800 hover:bg-gray-700 border-gray-700 text-gray-400")}>
        ✨ Insights (<%= @insights_count %>)
      </button>

      <button phx-click="toggle_consolidation_history"
        class={"text-xs px-3 py-1.5 rounded font-bold transition border flex items-center gap-1.5 " <>
          if(@show_consolidation_history,
            do: "bg-blue-900/60 border-blue-700 text-blue-300",
            else: "bg-gray-800 hover:bg-gray-700 border-gray-700 text-gray-400")}>
        🔄 Consolidation
      </button>

      <button phx-click="toggle_cold_store"
        class={"text-xs px-3 py-1.5 rounded font-bold transition border flex items-center gap-1.5 " <>
          if(@show_cold_store,
            do: "bg-indigo-900/60 border-indigo-700 text-indigo-300",
            else: "bg-gray-800 hover:bg-gray-700 border-gray-700 text-gray-400")}>
        🧊 Cold Store
      </button>

      <div class="ml-auto text-sm font-bold text-gray-600">
        ⮜ Click to open panels
      </div>
    </div>
    """
  end
end

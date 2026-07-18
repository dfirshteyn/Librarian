defmodule LibrarianWeb.Dashboard.Components.ControlStrip do
  use Phoenix.Component

  attr(:auto_consolidation_enabled, :boolean, required: true)
  attr(:auto_flush_enabled, :boolean, required: true)
  attr(:nightly_pass_enabled, :boolean, required: true)
  attr(:hot_counts, :map, required: true)
  attr(:active_bucket, :string, required: true)
  attr(:tier, :atom, default: :anon)
  attr(:force_local, :boolean, default: false)
  attr(:warm_count, :integer, required: true)
  attr(:cold_count, :integer, required: true)

  def control_strip(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-3 flex-wrap bg-gray-900/60 border border-gray-800 rounded-lg px-4 py-3 gap-3">
      <%!-- Left side: Key Metrics/Counts --%>
      <div class="flex items-center gap-3">
        <div class="flex items-center gap-2.5 bg-red-950/30 border border-red-900/40 rounded-lg px-3 py-1.5 shadow-sm">
          <span class="text-xs text-red-400 font-bold tracking-wider">🔥 HOT</span>
          <span class="text-sm font-bold font-mono text-red-200"><%= total_hot(@hot_counts) %></span>
        </div>
        <div class="flex items-center gap-2.5 bg-indigo-950/30 border border-indigo-900/40 rounded-lg px-3 py-1.5 shadow-sm">
          <span class="text-xs text-indigo-400 font-bold tracking-wider">🧠 WARM</span>
          <span class="text-sm font-bold font-mono text-indigo-200"><%= @warm_count %></span>
        </div>
        <div class="flex items-center gap-2.5 bg-cyan-950/30 border border-cyan-900/40 rounded-lg px-3 py-1.5 shadow-sm">
          <span class="text-xs text-cyan-400 font-bold tracking-wider">❄️ COLD</span>
          <span class="text-sm font-bold font-mono text-cyan-200"><%= @cold_count %></span>
        </div>
      </div>

      <%!-- Right side: Automation Toggles and Run Pass Button --%>
      <div class="flex items-center gap-2 ml-auto flex-wrap">
        <!-- Auto-Flush Toggle -->
        <button phx-click="toggle_auto_flush"
          class={"text-xs px-3 py-1.5 rounded-lg font-bold transition-all duration-200 border cursor-pointer active:scale-95 " <>
            if(@auto_flush_enabled,
              do: "bg-blue-600/90 hover:bg-blue-500/90 text-white border-blue-400/50 shadow-sm shadow-blue-900/20",
              else: "bg-gray-800/80 hover:bg-gray-700/80 text-gray-400 border-gray-700/60")}>
          <%= if @auto_flush_enabled, do: "🧼 Auto-Flush: ON", else: "🧼 Auto-Flush: OFF" %>
        </button>

        <!-- Auto-Consolidation Toggle -->
        <button phx-click="toggle_auto_consolidation"
          class={"text-xs px-3 py-1.5 rounded-lg font-bold transition-all duration-200 border cursor-pointer active:scale-95 " <>
            if(@auto_consolidation_enabled,
              do: "bg-fuchsia-600/90 hover:bg-fuchsia-500/90 text-white border-fuchsia-400/50 shadow-sm shadow-fuchsia-900/20",
              else: "bg-gray-800/80 hover:bg-gray-700/80 text-gray-400 border-gray-700/60")}>
          <%= if @auto_consolidation_enabled, do: "⚙️ Auto-Consolidate: ON", else: "⚙️ Auto-Consolidate: OFF" %>
        </button>

        <!-- Auto-Nightly Pass Toggle -->
        <button phx-click="toggle_nightly_pass"
          class={"text-xs px-3 py-1.5 rounded-lg font-bold transition-all duration-200 border cursor-pointer active:scale-95 " <>
            if(@nightly_pass_enabled,
              do: "bg-violet-600/90 hover:bg-violet-500/90 text-white border-violet-400/50 shadow-sm shadow-violet-900/20",
              else: "bg-gray-800/80 hover:bg-gray-700/80 text-gray-400 border-gray-700/60")}>
          <%= if @nightly_pass_enabled, do: "🔮 Auto-Synaptic: ON", else: "🔮 Auto-Synaptic: OFF" %>
        </button>

        <div class="w-px h-6 bg-gray-800 mx-1"></div>

        <!-- Force Synaptic Integration Button -->
        <button phx-click="nightly_pass"
          class="text-xs bg-gradient-to-r from-purple-600 to-indigo-600 hover:from-purple-500 hover:to-indigo-500 text-white px-3 py-1.5 rounded-lg font-bold transition-all duration-200 active:scale-95 shadow-md shadow-purple-950/50 cursor-pointer">
          ✨ Run Synaptic Integration Pass
        </button>
      </div>
    </div>
    """
  end

  defp total_hot(hot_counts) do
    hot_counts |> Map.values() |> Enum.reduce(0, &(&1 + &2))
  end
end

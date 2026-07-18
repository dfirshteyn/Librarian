defmodule LibrarianWeb.Dashboard.Components.ControlStrip do
  use Phoenix.Component

  attr(:auto_consolidation_enabled, :boolean, required: true)
  attr(:auto_flush_enabled, :boolean, required: true)
  attr(:hot_counts, :map, required: true)
  attr(:active_bucket, :string, required: true)
  attr(:tier, :atom, default: :anon)
  attr(:force_local, :boolean, default: false)
  attr(:warm_count, :integer, required: true)
  attr(:cold_count, :integer, required: true)

  def control_strip(assigns) do
    ~H"""
    <div class="flex items-center gap-2 mb-3 flex-wrap bg-gray-900/60 border border-gray-800 rounded-lg px-3 py-2">
      <button phx-click="force_consolidation"
        class="text-xs bg-fuchsia-700 hover:bg-fuchsia-600 text-white px-2.5 py-1 rounded font-bold transition">
        <%= if @active_bucket == "all", do: "⚡ Force Sweep", else: "⚡ Sweep: #{@active_bucket}" %>
      </button>

      <button phx-click="toggle_auto_consolidation"
        class={"text-xs px-2.5 py-1 rounded font-bold transition border " <>
          if(@auto_consolidation_enabled,
            do: "bg-fuchsia-600 hover:bg-fuchsia-500 text-white border-fuchsia-400",
            else: "bg-gray-800 hover:bg-gray-700 text-gray-400 border-gray-600")}>
        <%= if @auto_consolidation_enabled, do: "⚙️ Auto-Consolidation: ON", else: "⚙️ Auto-Consolidation: OFF" %>
      </button>

      <button phx-click="toggle_auto_flush"
        class={"text-xs px-2.5 py-1 rounded font-bold transition border " <>
          if(@auto_flush_enabled,
            do: "bg-blue-600 hover:bg-blue-500 text-white border-blue-400",
            else: "bg-gray-800 hover:bg-gray-700 text-gray-400 border-gray-600")}>
        <%= if @auto_flush_enabled, do: "🧼 Auto-Flush: ON", else: "🧼 Auto-Flush: OFF" %>
      </button>

      <button phx-click="nightly_pass"
        class="text-xs bg-purple-700 hover:bg-purple-600 text-white px-2.5 py-1 rounded font-bold transition">
        🔮 Run Nightly Pass
      </button>

      <div class="w-px h-5 bg-gray-700 mx-1"></div>

      <div class="flex items-center gap-2 bg-gray-800 rounded px-2 py-1">
        <span class="text-[10px] text-gray-300">🔥 HOT</span>
        <span class="text-[10px] font-bold text-white"><%= total_hot(@hot_counts) %></span>
      </div>
      <div class="flex items-center gap-2 bg-gray-800 rounded px-2 py-1">
        <span class="text-[10px] text-gray-300">WARM</span>
        <span class="text-[10px] font-bold text-white"><%= @warm_count %></span>
      </div>
      <div class="flex items-center gap-2 bg-blue-950/40 rounded px-2 py-1 border border-blue-800/40">
        <span class="text-[10px] text-blue-300">❄️ COLD</span>
        <span class="text-[10px] font-bold text-blue-200"><%= @cold_count %></span>
      </div>

      <div class="ml-auto flex items-center gap-1">
        <%= if @tier == :judge do %>
          <button phx-click="toggle_force_local"
            class={"text-[10px] px-2 py-0.5 rounded font-bold transition border " <>
              if(@force_local,
                do: "bg-amber-600 hover:bg-amber-500 text-white border-amber-400",
                else: "bg-violet-700 hover:bg-violet-600 text-white border-violet-500")}>
            <%= if @force_local, do: "🖥️ Local 1.7B", else: "☁️ Cloud Qwen" %>
          </button>
        <% else %>
          <span class="text-[10px] text-gray-600 px-1.5 py-0.5 rounded border border-gray-800 select-none">
            🖥️ Local Model
          </span>
        <% end %>
      </div>
    </div>
    """
  end

  defp total_hot(hot_counts) do
    hot_counts |> Map.values() |> Enum.reduce(0, &(&1 + &2))
  end
end

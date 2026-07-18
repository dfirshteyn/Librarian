defmodule LibrarianWeb.Dashboard.Components.Header do
  use Phoenix.Component

  attr(:tenant_id, :string, required: true)
  attr(:tier, :atom, default: :anon)
  attr(:force_local, :boolean, default: false)
  attr(:demo_running, :boolean, required: true)

  def header(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-3">
      <div class="flex items-center gap-3">
        <h1 class="text-xl font-bold text-white">📚 Librarian Ledger</h1>
        <code class="text-xs bg-gray-800 px-2 py-0.5 rounded text-indigo-300 font-mono"><%= @tenant_id %></code>
        <button data-tenant-id={@tenant_id}
          onclick="var tid=this.getAttribute('data-tenant-id');navigator.clipboard.writeText(tid);this.textContent='Copied!';setTimeout(()=>this.textContent='📋 Copy',1500)"
          class="text-[10px] bg-indigo-700 hover:bg-indigo-600 text-white px-1.5 py-0.5 rounded transition">
          📋 Copy
        </button>
        <span class={"text-[10px] text-white px-1.5 py-0.5 rounded font-bold " <> tier_badge_color(@tier, @force_local)}>
          <%= tier_label(@tier, @force_local) %>
        </span>
      </div>
      <div class="flex items-center gap-2">
        <button phx-click="seed_demo"
          disabled={@demo_running}
          class={if @demo_running,
            do: "text-xs px-2 py-1 rounded bg-gray-700 cursor-not-allowed text-gray-500",
            else: "text-xs px-2 py-1 rounded bg-emerald-700 hover:bg-emerald-600 text-white transition font-bold"}>
          <%= if @demo_running, do: "Seeding...", else: "🌱 Seed Demo" %>
        </button>
      </div>
    </div>
    """
  end

  defp tier_label(:judge, false), do: "JUDGE · CLOUD QWEN"
  defp tier_label(_tier, true), do: "LOCAL OVERRIDE (1.7B)"
  defp tier_label(_tier, false), do: "FREE · LOCAL 1.7B"

  defp tier_badge_color(:judge, false), do: "bg-fuchsia-600"
  defp tier_badge_color(_tier, true), do: "bg-amber-600"
  defp tier_badge_color(_tier, false), do: "bg-emerald-600"
end

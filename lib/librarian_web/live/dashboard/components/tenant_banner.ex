defmodule LibrarianWeb.Dashboard.Components.TenantBanner do
  use Phoenix.Component

  attr :tenant_id, :string, required: true
  attr :tier, :atom, default: :anon
  attr :force_local, :boolean, default: false

  def tenant_banner(assigns) do
    ~H"""
    <div class="bg-gradient-to-r from-indigo-900/60 via-purple-900/40 to-gray-900 rounded-lg border border-indigo-800/50 p-4 mb-5">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <span class="text-xl">📦</span>
          <div>
            <div class="flex items-center gap-2">
              <span class="text-sm font-bold text-white">Active Memory Vault:</span>
              <code class="text-sm bg-gray-800 px-2 py-0.5 rounded text-indigo-300 font-mono"><%= @tenant_id %></code>
              <button data-tenant-id={@tenant_id} onclick="var tid=this.getAttribute('data-tenant-id');navigator.clipboard.writeText(tid);this.textContent='Copied!';setTimeout(()=>this.textContent='📋 Copy Token',1500)"
                class="text-xs bg-indigo-700 hover:bg-indigo-600 text-white px-2 py-1 rounded transition">
                📋 Copy Token
              </button>
              <span class={"text-xs text-white px-2 py-0.5 rounded font-bold " <> tier_badge_color(@tier, @force_local)}>
                <%= tier_label(@tier, @force_local) %>
              </span>
            </div>
            <p class="text-xs text-gray-400 mt-1">
              <%= if @tier == :judge do %>
                Premium cloud tier — re-curation routed to Alibaba Cloud Qwen. Granted by a server-signed link (not self-serviceable).
              <% else %>
                Free tier — runs fully local on the 1.7B model. Sandboxed in a local SQLite WAL file.
              <% end %>
            </p>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <span class="text-xs text-gray-500">Isolated</span>
          <span class="w-2 h-2 rounded-full bg-green-500" title="sandboxed" />
        </div>
      </div>
    </div>
    """
  end

  defp tier_label(tier, force_local) do
    cond do
      force_local -> "LOCAL OVERRIDE (1.7B)"
      tier == :judge -> "JUDGE · CLOUD QWEN"
      true -> "FREE · LOCAL 1.7B"
    end
  end

  defp tier_badge_color(tier, force_local) do
    cond do
      force_local -> "bg-amber-600"
      tier == :judge -> "bg-fuchsia-600"
      true -> "bg-emerald-600"
    end
  end
end

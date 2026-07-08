defmodule LibrarianWeb.Dashboard.Components.TenantBanner do
  use Phoenix.Component

  attr :tenant_id, :string, required: true

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
            </div>
            <p class="text-xs text-gray-400 mt-1">
              This session is sandboxed in a local SQLite WAL file. No account required.
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
end

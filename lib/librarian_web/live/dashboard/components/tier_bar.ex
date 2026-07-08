defmodule LibrarianWeb.Dashboard.Components.TierBar do
  use Phoenix.Component

  import LibrarianWeb.Dashboard.Components.Helpers

  attr :hot_counts, :map, required: true
  attr :memories, :list, required: true
  attr :tenant_id, :string, required: true

  def tier_bar(assigns) do
    ~H"""
    <div class="flex gap-3 mb-6 flex-wrap">
      <%= for {bucket, count} <- Enum.sort(@hot_counts) do %>
        <div class="flex items-center gap-2 bg-gray-800 rounded px-3 py-1.5">
          <span class={"w-2 h-2 rounded-full #{bucket_color(bucket)}"} />
          <span class="text-xs text-gray-300"><%= String.split(bucket, ":") |> List.last() %></span>
          <span class="text-xs font-bold text-white"><%= count %> HOT</span>
          <button phx-click="flush_bucket" phx-value-bucket={bucket}
            class="ml-1 text-xs text-blue-400 hover:text-blue-300">[flush]</button>
        </div>
      <% end %>
      <div class="flex items-center gap-2 bg-gray-800 rounded px-3 py-1.5">
        <span class="text-xs text-gray-300">WARM</span>
        <span class="text-xs font-bold text-white"><%= length(@memories) %></span>
      </div>
      <div class="flex items-center gap-2 bg-gray-800 rounded px-3 py-1.5">
        <span class="text-xs text-gray-300">🔢 embedded</span>
        <span class="text-xs font-bold text-white"><%= Enum.count(@memories, &(not is_nil(&1.embedding))) %></span>
      </div>
      <div class="flex items-center gap-2 bg-amber-900/50 rounded px-3 py-1.5 border border-amber-700">
        <span class="text-xs text-amber-300">🔒 sandbox: <%= tenant_short(@tenant_id) %></span>
      </div>
    </div>
    """
  end
end

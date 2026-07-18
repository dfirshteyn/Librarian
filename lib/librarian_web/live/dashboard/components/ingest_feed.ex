defmodule LibrarianWeb.Dashboard.Components.IngestFeed do
  use Phoenix.Component

  import LibrarianWeb.Dashboard.Components.Helpers

  attr(:tenant_id, :string, required: true)
  attr(:ingest_text, :string, required: true)
  attr(:ingest_bucket, :string, required: true)
  attr(:feed_empty, :boolean, required: true)
  attr(:streams, :map, required: true)
  attr(:hot_counts, :map, required: true)
  attr(:auto_flush_enabled, :boolean, required: true)
  attr(:flush_progress, :map, required: false)

  def ingest_feed(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg p-4 overflow-hidden flex flex-col">
      <div class="flex items-center justify-between mb-3">
        <h2 class="text-sm font-bold text-gray-300 uppercase tracking-wider">
          🔥 HOT Ingest & Workspace
          <span class="text-indigo-400 text-[10px]">[<%= tenant_short(@tenant_id) %>]</span>
          <span class="text-[10px] text-gray-500 font-normal ml-1 group relative">
            ℹ️
            <span class="absolute bottom-full left-0 mb-1 hidden group-hover:block bg-gray-800 text-[10px] text-gray-300 px-2 py-1 rounded shadow-lg whitespace-nowrap z-10 border border-gray-700">
              Text hits the local WAL instantly. WARM summaries managed by 0.6B model; 1.7B for Council validation
            </span>
          </span>
        </h2>

        <%= if show_flush_button?(@hot_counts, @auto_flush_enabled) do %>
          <button phx-click="flush_all_buckets"
            class="text-xs bg-blue-700 hover:bg-blue-600 text-white px-2.5 py-1 rounded font-bold transition">
            🧼 Flush HOT → WARM
          </button>
        <% end %>
      </div>

      <form phx-submit="manual_ingest" class="mb-3 space-y-2.5">
        <textarea name="text" value={@ingest_text} rows="3" placeholder="Paste text to ingest..."
          class="w-full bg-gray-800/80 border border-gray-700 focus:border-blue-500/80 rounded-lg px-3 py-2 text-xs text-white placeholder-gray-500 focus:outline-none focus:ring-2 focus:ring-blue-500/20 transition-all resize-none"></textarea>
        <div class="flex gap-2">
          <select name="bucket" class="bg-gray-800/80 border border-gray-700 rounded-lg px-2.5 py-1.5 text-xs text-white focus:outline-none focus:border-blue-500 transition-colors cursor-pointer">
            <%= for b <- buckets_list() do %>
              <option value={b} selected={@ingest_bucket == b}><%= b %></option>
            <% end %>
          </select>
          <button type="submit"
            class="flex-1 px-3 py-1.5 bg-blue-700 hover:bg-blue-600 rounded-lg text-xs font-bold transition cursor-pointer active:scale-95">
            Ingest to HOT
          </button>
        </div>
      </form>

      <%!--
        File upload form targetting a hidden iframe.
        Stays on the same page and submits instantly once a file is chosen, reloading dynamically.
      --%>
      <form action="/api/ingest/file" method="post" enctype="multipart/form-data"
            target="upload-iframe" class="mb-3">
        <label for="file-input" class="cursor-pointer flex flex-col items-center justify-center gap-1.5 bg-gray-800/50 hover:bg-gray-800/80 border border-gray-700/80 border-dashed rounded-lg py-3.5 text-xs text-gray-400 hover:text-gray-200 transition-all active:scale-[0.99] select-none">
          <span class="text-base">📎</span>
          <span class="font-bold text-[11px] tracking-wide">Choose or drag a file to ingest</span>
          <span class="text-[9px] text-gray-500">PDF, TXT, MD, JSON, CSV</span>
          <input type="file" name="file" id="file-input" accept=".pdf,.png,.jpg,.jpeg,.gif,.txt,.md,.json,.csv" class="hidden" onchange="this.form.submit()" />
        </label>
      </form>
      <iframe name="upload-iframe" id="upload-iframe" style="display:none"
              onload="(function(){var f=document.getElementById('upload-iframe');if(f.dataset.loaded){window.location.reload()}else{f.dataset.loaded='1'}})()">
      </iframe>

      <%= if has_flush_progress?(@flush_progress) do %>
        <div class="mb-2 bg-gray-800 rounded p-2 border border-blue-600">
          <div class="flex items-center gap-2 mb-1">
            <span class="text-[10px] text-blue-400 font-bold">🧼 Flushing...</span>
            <span class="text-[10px] text-gray-400"><%= flush_progress_summary(@flush_progress) %></span>
          </div>
          <div class="h-1 bg-gray-700 rounded">
            <div class="h-1 bg-blue-500 rounded transition-all duration-300" style={flush_progress_pct(@flush_progress)}>
            </div>
          </div>
        </div>
      <% end %>

      <div class="flex-1 overflow-y-auto space-y-2" id="feed" phx-update="stream" style="max-height: 400px;">
        <div :if={@feed_empty} id="feed-empty" class="text-gray-600 text-xs">
          Waiting for ingest events... use the text box above or run Seed Demo.
        </div>
        <%= for {dom_id, entry} <- @streams.feed do %>
          <div id={dom_id} class="border-l-2 border-gray-700 pl-3 py-1">
            <div class="flex items-center gap-2 mb-0.5">
              <span class={"w-2 h-2 rounded-full flex-shrink-0 #{bucket_color(entry.bucket)}"} />
              <span class="text-xs font-bold text-gray-200"><%= entry.bucket %></span>
              <span class="text-xs text-gray-500"><%= entry.source %></span>
              <span class="text-xs text-gray-600 ml-auto"><%= entry.at %></span>
            </div>
            <p class="text-xs text-gray-400 truncate"><%= entry.preview %></p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp show_flush_button?(hot_counts, auto_flush_enabled) do
    total = hot_counts |> Map.values() |> Enum.reduce(0, &(&1 + &2))
    total > 0 and not auto_flush_enabled
  end

  defp has_flush_progress?(nil), do: false
  defp has_flush_progress?(%{}), do: true

  defp flush_progress_summary(progress) do
    progress
    |> Map.values()
    |> Enum.reduce({0, 0}, fn %{processed: p, total: t}, {acc_p, acc_t} ->
      {acc_p + p, acc_t + t}
    end)
    |> case do
      {0, 0} -> ""
      {processed, total} -> "#{processed}/#{total} payloads"
    end
  end

  defp flush_progress_pct(progress) do
    progress
    |> Map.values()
    |> Enum.reduce({0, 0}, fn %{processed: p, total: t}, {acc_p, acc_t} ->
      {acc_p + p, acc_t + t}
    end)
    |> case do
      {0, 0} -> "width: 0%"
      {processed, total} -> "width: #{min(100, div(processed * 100, total))}%"
    end
  end
end

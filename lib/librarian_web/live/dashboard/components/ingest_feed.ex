defmodule LibrarianWeb.Dashboard.Components.IngestFeed do
  use Phoenix.Component

  import LibrarianWeb.Dashboard.Components.Helpers

  attr(:tenant_id, :string, required: true)
  attr(:ingest_text, :string, required: true)
  attr(:ingest_bucket, :string, required: true)
  attr(:feed_empty, :boolean, required: true)
  attr(:streams, :map, required: true)

  def ingest_feed(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg p-4 overflow-hidden flex flex-col">
      <h2 class="text-sm font-bold text-gray-300 mb-3 uppercase tracking-wider">
        ⚡ Live Ingest Feed
        <span class="text-indigo-400 text-[10px]">[<%= tenant_short(@tenant_id) %>]</span>
      </h2>

      <form phx-submit="manual_ingest" class="mb-4 space-y-2">
        <textarea name="text" value={@ingest_text} rows="2" placeholder="Paste text to ingest..."
          class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-sm text-white placeholder-gray-500 focus:outline-none focus:border-blue-500"></textarea>
        <div class="flex gap-2">
          <select name="bucket" class="bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-sm text-white focus:outline-none focus:border-blue-500">
            <%= for b <- buckets_list() do %>
              <option value={b} selected={@ingest_bucket == b}><%= b %></option>
            <% end %>
          </select>
          <button type="submit"
            class="flex-1 px-3 py-1.5 bg-blue-700 hover:bg-blue-600 rounded text-sm transition">
            Ingest
          </button>
        </div>
      </form>

      <%!--
        File upload form targetting a hidden iframe.
        This keeps the submission on the same page and within the same session,
        so the browser never navigates away from the LiveView.
        The iframe's onload event triggers a page reload once the upload completes,
        so the dashboard picks up the new HOT entry.
      --%>
      <form action="/api/ingest/file" method="post" class="mb-4 space-y-2" enctype="multipart/form-data"
            target="upload-iframe" onsubmit="setTimeout(function(){document.getElementById('file-input').value=''},100)">
        <input type="file" name="file" id="file-input" accept=".pdf,.png,.jpg,.jpeg,.gif,.txt,.md,.json,.csv"
          class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-sm text-white file:text-blue-400 file:cursor-pointer" />
        <button type="submit"
          class="w-full px-3 py-1.5 bg-purple-700 hover:bg-purple-600 rounded text-sm transition">
          📎 Upload File
        </button>
      </form>
      <iframe name="upload-iframe" id="upload-iframe" style="display:none"
              onload="(function(){var f=document.getElementById('upload-iframe');if(f.dataset.loaded){window.location.reload()}else{f.dataset.loaded='1'}})()">
      </iframe>

      <div class="flex-1 overflow-y-auto space-y-2" id="feed" phx-update="stream" style="max-height: 400px;">
        <div :if={@feed_empty} id="feed-empty" class="text-gray-600 text-xs">
          Waiting for ingest events... run Flood Demo or Swarm Demo.
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
end

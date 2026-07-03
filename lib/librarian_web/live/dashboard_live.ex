defmodule LibrarianWeb.DashboardLive do
  use LibrarianWeb, :live_view

  alias Librarian.{WarmStore, HotStore, Flusher}

  @bucket_colors %{
    "project"  => "bg-blue-500",
    "research" => "bg-purple-500",
    "finance"  => "bg-green-500",
    "ideas"    => "bg-yellow-500",
    "thoughts" => "bg-pink-500",
    "inbox"    => "bg-gray-500"
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Librarian.PubSub, "ingest")
      Phoenix.PubSub.subscribe(Librarian.PubSub, "flush")
      :timer.send_interval(2000, self(), :refresh_warm)
    end

    {:ok,
     socket
     |> stream(:feed, [])
     |> assign(:feed_empty, true)
     |> assign(:memories, WarmStore.all() |> Enum.reject(&(&1.superseded_by)))
     |> assign(:hot_counts, hot_counts())
     |> assign(:query, "")
     |> assign(:recall_results, nil)
     |> assign(:bucket_colors, @bucket_colors)}
  end

  @impl true
  def handle_info({:ingested, bucket, source, preview, _user_id}, socket) do
    entry = %{
      id: System.unique_integer([:positive, :monotonic]),
      bucket: bucket,
      source: source,
      preview: preview,
      at: Time.utc_now() |> Time.truncate(:second)
    }

    {:noreply,
     socket
     |> stream_insert(:feed, entry, at: 0, limit: 50)
     |> assign(:feed_empty, false)
     |> assign(:hot_counts, hot_counts())}
  end

  def handle_info({:flushed, _bucket}, socket) do
    {:noreply,
     socket
     |> assign(:memories, WarmStore.all() |> Enum.reject(&(&1.superseded_by)))
     |> assign(:hot_counts, hot_counts())}
  end

  def handle_info(:refresh_warm, socket) do
    {:noreply,
     socket
     |> assign(:memories, WarmStore.all() |> Enum.reject(&(&1.superseded_by)))
     |> assign(:hot_counts, hot_counts())}
  end

  @impl true
  def handle_event("recall", %{"query" => q}, socket) when byte_size(q) > 0 do
    %{warm: warm, related: related} = Librarian.recall(q)
    {:noreply, assign(socket, :recall_results, %{query: q, warm: warm, related: related})}
  end

  def handle_event("recall", _params, socket) do
    {:noreply, assign(socket, :recall_results, nil)}
  end

  def handle_event("flush_all", _params, socket) do
    Flusher.flush_all()
    {:noreply,
     socket
     |> assign(:memories, WarmStore.all() |> Enum.reject(&(&1.superseded_by)))
     |> assign(:hot_counts, hot_counts())
     |> put_flash(:info, "Flushed all buckets")}
  end

  def handle_event("nightly_pass", _params, socket) do
    Task.start(fn ->
      Flusher.nightly_pass()
      Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:flushed, :all})
    end)
    {:noreply, put_flash(socket, :info, "Nightly pass started (async)")}
  end

  defp hot_counts do
    HotStore.buckets()
    |> Enum.map(fn b -> {b, HotStore.count(b)} end)
    |> Enum.into(%{})
  end

  defp bucket_color(bucket, colors), do: Map.get(colors, bucket, "bg-gray-500")
  defp importance_pct(importance), do: "width: #{trunc((importance || 0) * 100)}%"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100 font-mono p-4">

      <%!-- Header --%>
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-2xl font-bold text-white">📚 Librarian</h1>
          <p class="text-gray-400 text-sm">local-first memory daemon · BEAM/OTP</p>
        </div>
        <div class="flex gap-3">
          <button phx-click="flush_all"
            class="px-3 py-1.5 bg-blue-700 hover:bg-blue-600 rounded text-sm transition">
            Flush HOT → WARM
          </button>
          <button phx-click="nightly_pass"
            class="px-3 py-1.5 bg-purple-700 hover:bg-purple-600 rounded text-sm transition">
            Nightly Pass (Qwen)
          </button>
        </div>
      </div>

      <%!-- HOT tier bucket counts --%>
      <div class="flex gap-3 mb-6 flex-wrap">
        <%= for {bucket, count} <- Enum.sort(@hot_counts) do %>
          <div class="flex items-center gap-2 bg-gray-800 rounded px-3 py-1.5">
            <span class={"w-2 h-2 rounded-full #{bucket_color(bucket, @bucket_colors)}"} />
            <span class="text-xs text-gray-300"><%= bucket %></span>
            <span class="text-xs font-bold text-white"><%= count %> HOT</span>
          </div>
        <% end %>
        <div class="flex items-center gap-2 bg-gray-800 rounded px-3 py-1.5">
          <span class="text-xs text-gray-300">WARM</span>
          <span class="text-xs font-bold text-white"><%= length(@memories) %></span>
        </div>
      </div>

      <div class="grid grid-cols-3 gap-4 h-[calc(100vh-200px)]">

        <%!-- Left: live ingest feed --%>
        <div class="bg-gray-900 rounded-lg p-4 overflow-hidden flex flex-col">
          <h2 class="text-sm font-bold text-gray-300 mb-3 uppercase tracking-wider">
            ⚡ Live Ingest Feed
          </h2>
          <div class="flex-1 overflow-y-auto space-y-2" id="feed" phx-update="stream">
            <div :if={@feed_empty} id="feed-empty" class="text-gray-600 text-xs">
              Waiting for ingest events... run the flood script or ingest from iex.
            </div>
            <%= for {dom_id, entry} <- @streams.feed do %>
              <div id={dom_id} class="border-l-2 border-gray-700 pl-3 py-1">
                <div class="flex items-center gap-2 mb-0.5">
                  <span class={"w-2 h-2 rounded-full flex-shrink-0 #{bucket_color(entry.bucket, @bucket_colors)}"} />
                  <span class="text-xs font-bold text-gray-200"><%= entry.bucket %></span>
                  <span class="text-xs text-gray-500"><%= entry.source %></span>
                  <span class="text-xs text-gray-600 ml-auto"><%= entry.at %></span>
                </div>
                <p class="text-xs text-gray-400 truncate"><%= entry.preview %></p>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Middle: WARM memory cards --%>
        <div class="bg-gray-900 rounded-lg p-4 overflow-hidden flex flex-col">
          <h2 class="text-sm font-bold text-gray-300 mb-3 uppercase tracking-wider">
            🧠 WARM Memory Tier
          </h2>
          <div class="flex-1 overflow-y-auto space-y-3">
            <%= for memory <- Enum.sort_by(@memories, &(-&1.importance)) do %>
              <div class="bg-gray-800 rounded p-3 border border-gray-700">
                <div class="flex items-center gap-2 mb-2">
                  <span class={"w-2 h-2 rounded-full flex-shrink-0 #{bucket_color(memory.bucket, @bucket_colors)}"} />
                  <span class="text-xs font-bold text-gray-200"><%= memory.bucket %></span>
                  <span class="text-xs text-gray-500 ml-auto">#<%= memory.id %></span>
                </div>
                <p class="text-xs text-gray-300 mb-2 line-clamp-2"><%= memory.summary %></p>
                <div class="h-1 bg-gray-700 rounded mb-2">
                  <div class="h-1 bg-blue-500 rounded" style={importance_pct(memory.importance)} />
                </div>
                <div class="flex flex-wrap gap-1">
                  <%= for tag <- (memory.tags || []) |> Enum.take(4) do %>
                    <span class="text-xs bg-gray-700 text-gray-300 rounded px-1.5 py-0.5"><%= tag %></span>
                  <% end %>
                  <span :if={memory.embedding} class="text-xs text-blue-400">🔢 embedded</span>
                </div>
              </div>
            <% end %>
            <p :if={@memories == []} class="text-gray-600 text-xs">
              No memories yet. Ingest some data and click Flush HOT → WARM.
            </p>
          </div>
        </div>

        <%!-- Right: recall console --%>
        <div class="bg-gray-900 rounded-lg p-4 overflow-hidden flex flex-col">
          <h2 class="text-sm font-bold text-gray-300 mb-3 uppercase tracking-wider">
            🔍 Recall Console
          </h2>
          <form phx-submit="recall" class="mb-4">
            <div class="flex gap-2">
              <input type="text" name="query" value={@query}
                placeholder="search memories..."
                class="flex-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm text-white placeholder-gray-500 focus:outline-none focus:border-blue-500"
                autofocus />
              <button type="submit"
                class="px-3 py-1.5 bg-blue-700 hover:bg-blue-600 rounded text-sm transition">
                Recall
              </button>
            </div>
          </form>

          <div class="flex-1 overflow-y-auto">
            <%= if @recall_results do %>
              <p class="text-xs text-gray-500 mb-3">
                "<%= @recall_results.query %>" →
                <%= length(@recall_results.warm) %> direct,
                <%= length(@recall_results.related) %> synaptic jumps
              </p>
              <%= for memory <- @recall_results.warm do %>
                <div class="bg-gray-800 rounded p-2 mb-2 border-l-2 border-blue-500">
                  <div class="flex items-center gap-2 mb-1">
                    <span class={"w-1.5 h-1.5 rounded-full #{bucket_color(memory.bucket, @bucket_colors)}"} />
                    <span class="text-xs font-bold text-gray-200"><%= memory.bucket %></span>
                    <span class="text-xs text-gray-500">score=<%= Float.round(memory.importance, 3) %></span>
                  </div>
                  <p class="text-xs text-gray-300 line-clamp-3"><%= memory.summary %></p>
                </div>
              <% end %>
              <%= if @recall_results.related != [] do %>
                <p class="text-xs text-yellow-500 mt-3 mb-2">⚡ Synaptic jumps (cross-bucket)</p>
                <%= for memory <- @recall_results.related do %>
                  <div class="bg-gray-800 rounded p-2 mb-2 border-l-2 border-yellow-500">
                    <div class="flex items-center gap-2 mb-1">
                      <span class={"w-1.5 h-1.5 rounded-full #{bucket_color(memory.bucket, @bucket_colors)}"} />
                      <span class="text-xs font-bold text-gray-200"><%= memory.bucket %></span>
                    </div>
                    <p class="text-xs text-gray-300 line-clamp-2"><%= memory.summary %></p>
                  </div>
                <% end %>
              <% end %>
              <p :if={@recall_results.warm == []} class="text-gray-600 text-xs">
                No memories match "<%= @recall_results.query %>"
              </p>
            <% else %>
              <p class="text-gray-600 text-xs">Enter a query to search WARM memories.</p>
              <p class="text-gray-700 text-xs mt-2">Ranked by cosine similarity + importance.</p>
            <% end %>
          </div>
        </div>

      </div>
    </div>
    """
  end
end

defmodule LibrarianWeb.DashboardLive do
  use LibrarianWeb, :live_view

  alias Librarian.{WarmStore, HotStore, Flusher}

  @bucket_colors %{
    "project" => "bg-blue-500",
    "research" => "bg-purple-500",
    "finance" => "bg-green-500",
    "ideas" => "bg-yellow-500",
    "thoughts" => "bg-pink-500",
    "inbox" => "bg-gray-500"
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
     |> assign(:memories, WarmStore.all() |> Enum.reject(& &1.superseded_by))
     |> assign(:hot_counts, hot_counts())
     |> assign(:query, "")
     |> assign(:recall_results, nil)
     |> assign(:insights, Librarian.morning_briefing(20))
     |> assign(:token_savings, compute_token_savings())
     |> assign(:bucket_colors, @bucket_colors)
      |> assign(:ingest_text, "")
      |> assign(:ingest_bucket, "inbox")
      |> assign(:expanded_memories, MapSet.new())
      |> assign(:flood_running, false)
      |> assign(:flood_count, 0)
      |> assign(:flush_concurrency, Application.get_env(:librarian, :parallel_flush_max_concurrency, 1))
      |> assign(:flood_total, 100)}
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
     |> assign(:memories, WarmStore.all() |> Enum.reject(& &1.superseded_by))
     |> assign(:hot_counts, hot_counts())
     |> assign(:token_savings, compute_token_savings())}
  end

  def handle_info(:refresh_warm, socket) do
    {:noreply,
     socket
     |> assign(:memories, WarmStore.all() |> Enum.reject(& &1.superseded_by))
     |> assign(:hot_counts, hot_counts())
     |> assign(:insights, Librarian.morning_briefing(20))
     |> assign(:token_savings, compute_token_savings())}
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
    Flusher.flush_all(socket.assigns.flush_concurrency)

    {:noreply,
     socket
     |> assign(:memories, WarmStore.all() |> Enum.reject(& &1.superseded_by))
     |> assign(:hot_counts, hot_counts())
     |> assign(:token_savings, compute_token_savings())
     |> put_flash(:info, "Flushed all buckets")}
  end

  def handle_event("nightly_pass", _params, socket) do
    concurrency = socket.assigns.flush_concurrency

    Task.start(fn ->
      Flusher.flush_all(concurrency)
      Flusher.nightly_pass()
      Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:flushed, :all})
    end)

    {:noreply, put_flash(socket, :info, "Nightly pass started (async)")}
  end

  def handle_event("set_flush_concurrency", %{"value" => value}, socket) do
    concurrency = String.to_integer(value)
    {:noreply, assign(socket, :flush_concurrency, concurrency)}
  end

  def handle_event("manual_ingest", %{"text" => text, "bucket" => bucket}, socket) when byte_size(text) > 0 do
    case Librarian.ingest(%{
      "source" => "web_ui",
      "raw_text" => text,
      "hint_tags" => [],
      "metadata" => %{}
    }) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:ingest_text, "")
         |> assign(:ingest_bucket, bucket)
         |> put_flash(:info, "Ingested to #{bucket}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Ingest failed: #{inspect(reason)}")}
    end
  end

  def handle_event("manual_ingest", _params, socket) do
    {:noreply, put_flash(socket, :error, "Text required")}
  end

  def handle_event("toggle_memory", %{"id" => id}, socket) do
    id = String.to_integer(id)
    new_set = if MapSet.member?(socket.assigns.expanded_memories, id),
      do: MapSet.delete(socket.assigns.expanded_memories, id),
      else: MapSet.put(socket.assigns.expanded_memories, id)

    {:noreply, assign(socket, :expanded_memories, new_set)}
  end

  def handle_event("flush_bucket", %{"bucket" => bucket}, socket) do
    case Librarian.Flusher.flush_bucket(bucket) do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:flushed, bucket})
        {:noreply, put_flash(socket, :info, "Flushed #{bucket}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Flush failed: #{inspect(reason)}")}
    end
  end

  def handle_event("flood_demo", _params, socket) do
    if socket.assigns.flood_running do
      {:noreply, socket}
    else
      Task.start(fn ->
        texts = [
          "we decided to deploy the new auth service to production this Friday",
          "switched the project database from postgres to sqlite for the edge nodes",
          "the deploy pipeline now runs mix release before pushing the docker image",
          "fixed the bucket routing bug where we matched inside weather",
          "repo renamed from memory-daemon to librarian, update all the CI configs",
          "Ebbinghaus forgetting curve: retention R = e^(-t/S) where S is memory strength",
          "research shows retrieval practice strengthens memory more than re-reading",
          "spaced repetition systems like Anki use expanding intervals between reviews",
          "the BEAM scheduler uses reduction counting not time slicing for preemption",
          "ETS tables in Elixir are O(1) lookup, stored outside the process heap",
          "Alibaba Cloud gave us $40 credit for the hackathon, use it for ECS or GPU",
          "Qwen API free tier: 1 million tokens, then pay-per-token after that",
          "finance: serverless functions on Alibaba Cloud are cheaper than always-on ECS",
          "budget the $40 coupon: GPU instance for demo day, ECS for the daemon",
          "finance note: embedding API calls are 10x cheaper than chat completions",
          "what if the morning briefing read back synaptic jumps from the night before",
          "idea: per-user memory namespacing so multiple people can share one daemon",
          "could use React Flow to visualize the memory graph, nodes are memories, edges are synaptic jumps",
          "idea: the Chrome extension could capture highlighted text, not just full page",
          "what if decay rate was user-configurable per bucket, not just global",
          "the weather today was perfect for a long walk",
          "picked up coffee beans from the market, the Ethiopian blend is excellent",
          "watched a documentary about octopus cognition, genuinely fascinating",
          "the new keyboard arrived, mechanical switches feel much better",
          "tried the new ramen place downtown, the tonkotsu broth was outstanding"
        ]

        1..100
        |> Task.async_stream(fn i ->
          text = Enum.random(texts)
          Librarian.ingest(%{
            "source" => "flood_ui",
            "raw_text" => text,
            "hint_tags" => [],
            "metadata" => %{"flood_index" => i}
          })
        end, max_concurrency: 4, timeout: 60_000)
        |> Enum.each(fn _ -> :ok end)

        Phoenix.LiveView.send_update(__MODULE__, id: "dashboard", flood_running: false)
      end)

      {:noreply, assign(socket, :flood_running, true)}
    end
  end

  defp hot_counts do
    HotStore.buckets()
    |> Enum.map(fn b -> {b, HotStore.count(b)} end)
    |> Enum.into(%{})
  end

  defp buckets_list, do: ["project", "research", "finance", "ideas", "thoughts", "inbox"]

  defp bucket_color(bucket, colors), do: Map.get(colors, bucket, "bg-gray-500")
  defp importance_pct(importance), do: "width: #{trunc((importance || 0) * 100)}%"

  # Token savings: compare total raw_text length (estimated from summary + facts)
  # vs what the raw capture would have been. Shows the compression ratio.
  defp compute_token_savings do
    memories = WarmStore.all() |> Enum.reject(& &1.superseded_by)

    if memories == [] do
      %{savings_pct: 0, raw_tokens: 0, curated_tokens: 0}
    else
      # Estimate: 1 token ≈ 4 characters for English text
      raw_tokens =
        memories
        |> Enum.map(fn m ->
          # Estimate original raw text length from summary + facts (conservative)
          (String.length(m.summary || "") + String.length(Enum.join(m.facts || [], " ")))
          |> div(4)
        end)
        |> Enum.sum()

      # What the curated memory stores (summary + facts + tags)
      curated_tokens =
        memories
        |> Enum.map(fn m ->
          (String.length(m.summary || "") + String.length(Enum.join(m.facts || [], " ")) +
             String.length(Enum.join(m.tags || [], " ")))
          |> div(4)
        end)
        |> Enum.sum()

      savings_pct =
        if raw_tokens > 0 do
          trunc((1 - curated_tokens / max(raw_tokens, 1)) * 100)
        else
          0
        end

      %{savings_pct: savings_pct, raw_tokens: raw_tokens, curated_tokens: curated_tokens}
    end
  end

  defp insight_icon("supersession"), do: "🔄"
  defp insight_icon("deep_supersession"), do: "⚠️"
  defp insight_icon("deep_cross_connection"), do: "🔗"
  defp insight_icon(_), do: "💡"

  defp insight_summary(%{"kind" => "supersession"} = m) do
    "Superseded: \"#{m["old_summary"]}\" → \"#{m["new_summary"]}\""
  end

  defp insight_summary(%{"kind" => "deep_supersession"} = m) do
    "Qwen flagged contradiction: memory ##{m["old_id"]} superseded by ##{m["new_id"]}"
  end

  defp insight_summary(%{"kind" => "deep_cross_connection"} = m) do
    "Qwen connected ##{m["id_a"]} ↔ ##{m["id_b"]}: #{m["note"]}"
  end

  defp insight_summary(m) do
    inspect(m)
  end

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
        <div class="flex items-center gap-4">
          <%!-- Token savings badge --%>
          <div class="bg-gray-800 rounded px-3 py-1.5 text-xs">
            <span class="text-gray-400">Token savings: </span>
            <span class="text-green-400 font-bold"><%= @token_savings.savings_pct %>%</span>
            <span class="text-gray-600"> | </span>
            <span class="text-gray-400"><%= @token_savings.curated_tokens %> curated</span>
          </div>
          <button phx-click="flush_all"
            class="px-3 py-1.5 bg-blue-700 hover:bg-blue-600 rounded text-sm transition">
            Flush HOT → WARM
          </button>
          <button phx-click="nightly_pass"
            class="px-3 py-1.5 bg-purple-700 hover:bg-purple-600 rounded text-sm transition">
            Nightly Pass (Qwen)
          </button>
          <select phx-change="set_flush_concurrency" name="value"
            class="bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-sm text-white focus:outline-none focus:border-blue-500">
            <%= for c <- [1, 2, 3, 4] do %>
              <option value={c} selected={@flush_concurrency == c}><%= c %>x</option>
            <% end %>
          </select>
          <button phx-click="flood_demo"
            disabled={@flood_running}
            class={if @flood_running, do: "px-3 py-1.5 rounded text-sm transition bg-gray-700 cursor-not-allowed", else: "px-3 py-1.5 rounded text-sm transition bg-green-700 hover:bg-green-600"}>
            <%= if @flood_running, do: "Flooding...", else: "Flood Demo" %>
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
      </div>

      <div class="grid grid-cols-4 gap-4 h-[calc(100vh-200px)]">

        <%!-- Left: live ingest feed + manual ingest --%>
        <div class="bg-gray-900 rounded-lg p-4 overflow-hidden flex flex-col">
          <h2 class="text-sm font-bold text-gray-300 mb-3 uppercase tracking-wider">
            ⚡ Live Ingest Feed
          </h2>

          <%!-- Manual ingest form for testing --%>
          <form phx-submit="manual_ingest" class="mb-4 space-y-2">
            <textarea name="text" value={@ingest_text} rows="3" placeholder="Paste text to ingest..."
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

          <div class="flex-1 overflow-y-auto space-y-2" id="feed" phx-update="stream" style="max-height: 400px;">
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

        <%!-- Second: WARM memory cards --%>
        <div class="bg-gray-900 rounded-lg p-4 overflow-hidden flex flex-col">
          <h2 class="text-sm font-bold text-gray-300 mb-3 uppercase tracking-wider">
            🧠 WARM Memory Tier
          </h2>
          <div class="flex-1 overflow-y-auto space-y-3">
            <%= for memory <- Enum.sort_by(@memories, &(-&1.importance)) do %>
              <div class={"bg-gray-800 rounded p-3 border #{if MapSet.member?(@expanded_memories, memory.id), do: "border-blue-500", else: "border-gray-700"} cursor-pointer"}
                   phx-click="toggle_memory" phx-value-id={memory.id}>
                <div class="flex items-center gap-2 mb-2">
                  <span class={"w-2 h-2 rounded-full flex-shrink-0 #{bucket_color(memory.bucket, @bucket_colors)}"} />
                  <span class="text-xs font-bold text-gray-200"><%= memory.bucket %></span>
                  <span class="text-xs text-gray-500 ml-auto">#<%= memory.id %></span>
                </div>
                <p class="text-xs text-gray-300 mb-2"><%= memory.summary %></p>

                <div class="h-1 bg-gray-700 rounded mb-2">
                  <div class="h-1 bg-blue-500 rounded" style={importance_pct(memory.importance)} />
                </div>

                <%= if MapSet.member?(@expanded_memories, memory.id) do %>
                  <div class="mt-2 pt-2 border-t border-gray-700 space-y-2">
                    <div>
                      <span class="text-xs text-gray-400">Facts:</span>
                      <%= if memory.facts && memory.facts != [] do %>
                        <ul class="text-xs text-gray-300 mt-1 space-y-1 list-disc list-inside">
                          <%= for fact <- memory.facts do %>
                            <li><%= fact %></li>
                          <% end %>
                        </ul>
                      <% else %>
                        <p class="text-xs text-gray-600 mt-1">No facts extracted</p>
                      <% end %>
                    </div>
                    <div class="flex gap-3 text-xs">
                      <span class="text-gray-400">Created: <%= DateTime.to_iso8601(memory.created_at) %></span>
                      <%= if memory.embedding do %>
                        <span class="text-blue-400">🔢 Embedding: <%= length(memory.embedding) %>-dim</span>
                      <% end %>
                    </div>
                    <div class="text-xs">
                      <span class="text-gray-400">Tags: </span>
                      <%= for tag <- (memory.tags || []) do %>
                        <span class="text-xs bg-gray-700 text-gray-300 rounded px-1.5 py-0.5"><%= tag %></span>
                      <% end %>
                    </div>
                    <%= if memory.superseded_by do %>
                      <div class="text-xs text-yellow-400">⚠️ Superseded by #<%= memory.superseded_by %></div>
                    <% end %>
                  </div>
                <% end %>

                <div class="flex flex-wrap gap-1 mt-2">
                  <%= for tag <- (memory.tags || []) |> Enum.take(4) do %>
                    <span class="text-xs bg-gray-700 text-gray-300 rounded px-1.5 py-0.5"><%= tag %></span>
                  <% end %>
                  <span :if={memory.embedding} class="text-xs text-blue-400">🔢 embedded</span>
                </div>
              </div>
            <% end %>
            <p :if={@memories == []} class="text-gray-600 text-xs">
              No memories yet. Use the form above or run the flood script to ingest data.
            </p>
          </div>
        </div>

        <%!-- Third: recall console --%>
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
              <p class="text-gray-700 text-xs mt-2">3-way RRF: keyword + BGE-M3 vector + importance.</p>
            <% end %>
          </div>
        </div>

        <%!-- Fourth: Connections / Insights panel --%>
        <div class="bg-gray-900 rounded-lg p-4 overflow-hidden flex flex-col">
          <h2 class="text-sm font-bold text-gray-300 mb-3 uppercase tracking-wider">
            🔗 Connections & Insights
          </h2>
          <div class="flex-1 overflow-y-auto space-y-3">
            <%= if @insights == [] do %>
              <p class="text-gray-600 text-xs">
                No insights yet. Run the Nightly Pass (Qwen) to discover cross-bucket connections, contradictions, and patterns.
              </p>
              <div class="bg-gray-800 rounded p-3 border border-gray-700 mt-2">
                <p class="text-xs text-gray-400">
                  The Qwen deep pass analyzes all WARM memories together to find:
                </p>
                <ul class="text-xs text-gray-500 mt-2 space-y-1 list-disc list-inside">
                  <li>Cross-bucket connections (synaptic jumps)</li>
                  <li>Contradictions between decisions</li>
                  <li>Repeated patterns across sessions</li>
                  <li>Re-ranking of importance scores</li>
                </ul>
              </div>
            <% else %>
              <%= for insight <- @insights do %>
                <div class="bg-gray-800 rounded p-3 border border-gray-700">
                  <div class="flex items-center gap-2 mb-1">
                    <span class="text-xs"><%= insight_icon(insight["kind"]) %></span>
                    <span class="text-xs text-gray-400"><%= insight["kind"] %></span>
                    <span class="text-xs text-gray-600 ml-auto"><%= insight["logged_at"] %></span>
                  </div>
                  <p class="text-xs text-gray-300"><%= insight_summary(insight) %></p>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>

      </div>
    </div>
    """
  end
end

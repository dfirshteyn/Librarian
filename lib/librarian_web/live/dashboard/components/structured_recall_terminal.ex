defmodule LibrarianWeb.Dashboard.Components.StructuredRecallTerminal do
  use Phoenix.Component

  import LibrarianWeb.Dashboard.Components.Helpers

  attr(:tenant_id, :string, required: true)
  attr(:structured_response, :any, required: true)
  attr(:show, :boolean, default: false)

  def structured_recall_terminal(assigns) do
    ~H"""
    <div class={"fixed inset-0 z-40 flex items-end justify-center pointer-events-none " <> if(@show, do: "", else: "hidden")}>
      <div class="absolute inset-0 bg-black/50 pointer-events-auto" phx-click="toggle_terminal"></div>
      <div class={"relative w-full max-w-4xl bg-gray-900 border border-green-800 rounded-t-xl shadow-2xl pointer-events-auto transition-transform duration-300 " <>
        if(@show, do: "translate-y-0 max-h-[82vh]", else: "translate-y-full")}
        style={if(@show, do: "max-height: 82vh; overflow: hidden;", else: "")}>
        <div class="flex items-center justify-between px-4 py-3 border-b border-green-900">
          <h2 class="text-sm font-bold text-green-300 uppercase tracking-wider">
            💻 Recall Console
            <span class="text-green-600 text-[10px] ml-2">ask, summarize, trace, demo</span>
          </h2>
          <button phx-click="toggle_terminal"
            class="text-gray-500 hover:text-gray-300 transition text-lg leading-none">
            ✕
          </button>
        </div>
        <div class="p-4 overflow-y-auto" style="max-height: calc(70vh - 52px);">
          <div class="grid gap-3 md:grid-cols-[1.2fr_0.8fr] mb-3">
            <div class="rounded-lg border border-green-900/70 bg-green-950/20 p-3">
              <p class="text-green-300 text-xs font-bold uppercase tracking-wider">Demo-friendly memory lookup</p>
              <p class="text-gray-400 text-xs mt-1 leading-relaxed">
                Use this instead of scrolling. After a request flood flushes HOT → WARM and the deep pass consolidates, ask for a bucket summary or trace a topic back to raw captures.
              </p>
            </div>
            <div class="rounded-lg border border-gray-800 bg-gray-950/70 p-3">
              <p class="text-gray-500 text-[10px] uppercase tracking-wider mb-2">Try these live</p>
              <div class="flex flex-wrap gap-1.5">
                <button type="button" phx-click="structured_recall" phx-value-command="/summary all" class="px-2 py-1 rounded bg-emerald-900/50 text-emerald-200 text-[11px] hover:bg-emerald-800/60">/summary all</button>
                <button type="button" phx-click="structured_recall" phx-value-command="/summary project" class="px-2 py-1 rounded bg-emerald-900/50 text-emerald-200 text-[11px] hover:bg-emerald-800/60">/summary project</button>
                <button type="button" phx-click="structured_recall" phx-value-command="/recall latency" class="px-2 py-1 rounded bg-cyan-900/50 text-cyan-200 text-[11px] hover:bg-cyan-800/60">/recall latency</button>
              </div>
            </div>
          </div>

          <form phx-submit="structured_recall" class="mb-3">
            <div class="flex gap-2">
              <span class="text-green-400 text-sm font-bold">$></span>
              <input type="text" name="command"
                placeholder="/summary project | /recall customer auth | /trace deploy | /status"
                class="flex-1 bg-gray-800 border border-green-900 rounded px-3 py-1.5 text-sm text-green-200 placeholder-gray-600 focus:outline-none focus:border-green-500" />
              <button type="submit"
                class="px-3 py-1.5 bg-green-800 hover:bg-green-700 rounded text-sm transition text-green-200">
                Run
              </button>
            </div>
          </form>

          <div class="bg-gray-950 rounded border border-gray-800 p-3 font-mono text-xs max-h-[58vh] overflow-y-auto">
            <%= if @structured_response do %>
              <.structured_response response={@structured_response} tenant_id={@tenant_id} />
            <% else %>
              <p class="text-gray-600">
                Memory as a database. Good demo flow: fire concurrent curl ingests, flush, consolidate, then retrieve the answer here.
              </p>
              <ul class="text-gray-600 mt-2 space-y-1">
                <li><span class="text-emerald-600">/summary [all|bucket]</span> — one screen executive summary by tier and bucket</li>
                <li><span class="text-green-600">/model [query]</span> — structured facts from matching memories</li>
                <li><span class="text-cyan-600">/recall [query]</span> — search summaries with synaptic jumps</li>
                <li><span class="text-violet-600">/trace [query]</span> — progressive disclosure from summary → chunks → raw source</li>
                <li><span class="text-amber-600">/status</span> — tier counts for current session</li>
              </ul>
              <p class="text-gray-700 mt-3 text-[10px]">
                Queries isolated to your session sandbox. Export your data anytime.
              </p>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:response, :map, required: true)
  attr(:tenant_id, :string, required: true)

  def structured_response(assigns) do
    ~H"""
    <%= case @response.type do %>
      <% "model_recall" -> %>
        <div>
          <p class="text-green-400 mb-2">
            <span class="text-green-600">MATCHES:</span>
            <%= @response.count %> memories for "<%= @response.query %>"
          </p>
          <%= for mem <- @response.memories do %>
            <div class="bg-gray-900 rounded p-2 mb-2 border-l-2 border-green-500">
              <div class="flex items-center gap-2 mb-1">
                <span class={"w-1.5 h-1.5 rounded-full #{bucket_color(mem.bucket)}"} />
                <span class="text-gray-200 font-bold"><%= mem.bucket %></span>
                <span class="text-gray-500">#<%= mem.id %></span>
                <span class={"text-[9px] font-bold px-1 rounded " <> if(Map.get(mem, :tier) == "cold", do: "bg-blue-900/60 text-blue-300 border border-blue-700/40", else: "bg-purple-900/60 text-purple-300 border border-purple-700/40")}>
                  <%= String.upcase(Map.get(mem, :tier, "warm")) %>
                </span>
                <span class="text-gray-500 ml-auto">imp=<%= Float.round(mem.importance, 2) %></span>
              </div>
              <p class="text-gray-300 mb-1"><%= mem.summary %></p>
              <%= if mem.facts != [] do %>
                <ul class="text-gray-400 space-y-0.5 list-none">
                  <%= for fact <- mem.facts do %>
                    <li>• <%= fact %></li>
                  <% end %>
                </ul>
              <% end %>
              <div class="flex gap-1 mt-1">
                <%= for tag <- mem.tags do %>
                  <span class="bg-gray-800 text-gray-400 rounded px-1 py-0.5 text-[10px]"><%= tag %></span>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>

      <% "search_recall" -> %>
        <div>
          <p class="text-cyan-400 mb-2">
            <span class="text-cyan-600">SEARCH:</span>
            <%= @response.warm_count %> warm, <%= @response.related_count %> related for "<%= @response.query %>"
          </p>
          <%= if @response.warm != [] do %>
            <p class="text-gray-500 mb-1">WARM (top 5):</p>
            <ul class="text-gray-300 space-y-1">
              <%= for s <- @response.warm do %>
                <li>• <%= s %></li>
              <% end %>
            </ul>
          <% end %>
          <%= if Map.get(@response, :cold) && @response.cold != [] do %>
            <p class="text-blue-400 mb-1 mt-2">COLD (top 3):</p>
            <ul class="text-blue-300 space-y-1">
              <%= for s <- @response.cold do %>
                <li>• <%= s %></li>
              <% end %>
            </ul>
          <% end %>
          <%= if @response.related != [] do %>
            <p class="text-yellow-500 mb-1 mt-2">SYNAPTIC JUMPS:</p>
            <ul class="text-yellow-300 space-y-1">
              <%= for s <- @response.related do %>
                <li>• <%= s %></li>
              <% end %>
            </ul>
          <% end %>
        </div>

      <% "bucket_summary" -> %>
        <div>
          <p class="text-emerald-400 mb-2"><span class="text-emerald-600">SUMMARY:</span> <%= @response.scope %></p>
          <div class="grid grid-cols-3 gap-2 mb-3 not-italic">
            <div class="rounded bg-gray-900 border border-gray-800 p-2"><p class="text-gray-500">HOT</p><p class="text-orange-300 text-lg font-bold"><%= @response.totals.hot %></p></div>
            <div class="rounded bg-gray-900 border border-gray-800 p-2"><p class="text-gray-500">WARM</p><p class="text-purple-300 text-lg font-bold"><%= @response.totals.warm %></p></div>
            <div class="rounded bg-gray-900 border border-gray-800 p-2"><p class="text-gray-500">COLD</p><p class="text-blue-300 text-lg font-bold"><%= @response.totals.cold %></p></div>
          </div>
          <%= for b <- @response.buckets do %>
            <div class="bg-gray-900 rounded p-2 mb-2 border-l-2 border-emerald-600">
              <div class="flex items-center gap-2 mb-1">
                <span class={"w-1.5 h-1.5 rounded-full #{bucket_color(b.name)}"} />
                <span class="text-gray-200 font-bold"><%= b.name %></span>
                <span class="text-gray-500 ml-auto"><%= b.hot %> hot · <%= b.warm %> warm · <%= b.cold %> cold</span>
              </div>
              <%= if b.recent != [] do %>
                <ul class="text-gray-300 space-y-1">
                  <%= for item <- b.recent do %><li>• <%= item %></li><% end %>
                </ul>
              <% else %>
                <p class="text-gray-600">No curated memories yet. Ingest, flush, then summarize again.</p>
              <% end %>
            </div>
          <% end %>
          <%= if @response.insights != [] do %>
            <p class="text-amber-500 mt-3 mb-1">RECENT DEEP-PASS INSIGHTS:</p>
            <ul class="text-amber-200 space-y-1">
              <%= for insight <- @response.insights do %><li>• <%= insight %></li><% end %>
            </ul>
          <% end %>
        </div>

      <% "status" -> %>
        <div>
          <p class="text-amber-400 mb-2">
            <span class="text-amber-600">STATUS:</span> <%= @tenant_id %>
          </p>
          <%= for {bucket, count} <- Enum.sort(Map.to_list(@response.data.hot || %{})) do %>
            <div class="flex items-center gap-2 mb-1">
              <span class={"w-1.5 h-1.5 rounded-full #{bucket_color(bucket)}"} />
              <span class="text-gray-300"><%= bucket %>: <%= count %> HOT</span>
            </div>
          <% end %>
          <p class="text-gray-300 mt-2">WARM total: <%= @response.data.warm_count %></p>
        </div>

      <% "ancestry_recall" -> %>
        <div>
          <p class="text-emerald-400 mb-2">
            <span class="text-emerald-600">ANCESTRY:</span>
            memory #<%= @response.memory_id %> (depth <%= @response.depth %>)
          </p>
          <%= if @response.tree == [] do %>
            <p class="text-gray-500">No ancestry relationships found for this memory.</p>
          <% else %>
            <%= for edge <- @response.tree do %>
              <div class="bg-gray-900 rounded p-2 mb-2 border-l-2 border-emerald-600">
                <p class="text-gray-400 text-[11px] mb-1">
                  <span class="text-emerald-500">Depth <%= edge.depth %></span> ·
                  <span class="text-violet-400"><%= edge.type %></span>
                </p>
                <p class="text-gray-300"><%= inspect(edge.source && Map.get(edge.source, :summary)) %></p>
                <p class="text-gray-500 text-[11px] mt-1">↓ #<%= edge.source_id %> → #<%= edge.target_id %></p>
                <p class="text-gray-500 text-[11px]"><%= inspect(edge.target && Map.get(edge.target, :summary)) %></p>
                <%= if edge.source && Map.get(edge.source, :has_raw_original) do %>
                  <span class="text-emerald-700 text-[10px]">🔗 raw original linked</span>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>

      <% "trace_recall" -> %>
        <div>
          <p class="text-violet-400 mb-2">
            <span class="text-violet-600">TRACE:</span>
            <%= @response.count %> progressive matches for "<%= @response.query %>"
          </p>
          <%= for card <- @response.results do %>
            <div class="bg-gray-900 rounded p-2 mb-3 border-l-2 border-violet-600">
              <p class="text-gray-200 font-bold">#<%= card.summary_card.id %> · <%= card.summary_card.bucket %></p>
              <p class="text-gray-300"><%= card.summary_card.summary %></p>

                          <%= if card.raw_original do %>
                            <details class="mt-1">
                              <summary class="text-emerald-500 text-[11px] cursor-pointer">View raw original</summary>
                              <pre class="text-gray-500 text-[10px] whitespace-pre-wrap mt-1 max-h-48 overflow-y-auto"><%= card.raw_original %></pre>
                            </details>
                          <% end %>

              <%= if card.children != [] do %>
                <p class="text-cyan-400 text-[11px] mt-1">↳ <%= length(card.children) %> chunk(s):</p>
                <%= for c <- card.children do %>
                  <p class="text-gray-500 text-[10px] ml-3">#<%= c.id %> <%= String.slice(c.summary || "", 0, 80) %></p>
                <% end %>
              <% end %>

              <%= if card.cross_links != [] do %>
                <p class="text-amber-400 text-[11px] mt-1">⇄ cross-links:</p>
                <%= for x <- card.cross_links do %>
                  <p class="text-gray-500 text-[10px] ml-3">#<%= x.id %> <%= x.note || "" %></p>
                <% end %>
              <% end %>
            </div>
          <% end %>
        </div>

      <% "error" -> %>
        <p class="text-red-400">
          <span class="text-red-600">ERROR:</span> <%= @response.message %>
        </p>

      <% _ -> %>
        <p class="text-gray-500">Unknown response type</p>
    <% end %>
    """
  end
end

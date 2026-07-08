defmodule LibrarianWeb.Dashboard.Components.StructuredRecallTerminal do
  use Phoenix.Component

  import LibrarianWeb.Dashboard.Components.Helpers

  attr :tenant_id, :string, required: true
  attr :structured_response, :any, required: true

  def structured_recall_terminal(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg p-4 overflow-hidden flex flex-col border border-green-800">
      <h2 class="text-sm font-bold text-green-300 mb-3 uppercase tracking-wider">
        💻 Structured Recall
        <span class="text-green-600 text-[10px]">/model /recall /status</span>
        <span class="text-indigo-400 text-[10px]">[<%= tenant_short(@tenant_id) %>]</span>
      </h2>
      <form phx-submit="structured_recall" class="mb-3">
        <div class="flex gap-2">
          <span class="text-green-400 text-sm font-bold">$></span>
          <input type="text" name="command"
            placeholder="/model database performance | /recall deploy | /status"
            class="flex-1 bg-gray-800 border border-green-900 rounded px-3 py-1.5 text-sm text-green-200 placeholder-gray-600 focus:outline-none focus:border-green-500" />
          <button type="submit"
            class="px-3 py-1.5 bg-green-800 hover:bg-green-700 rounded text-sm transition text-green-200">
            Run
          </button>
        </div>
      </form>

      <div class="flex-1 overflow-y-auto bg-gray-950 rounded border border-gray-800 p-3 font-mono text-xs">
        <%= if @structured_response do %>
          <.structured_response response={@structured_response} tenant_id={@tenant_id} />
        <% else %>
          <p class="text-gray-600">
            Memory as a database. Type a command:
          </p>
          <ul class="text-gray-600 mt-2 space-y-1">
            <li><span class="text-green-600">/model [query]</span> — structured facts from matching memories</li>
            <li><span class="text-cyan-600">/recall [query]</span> — search summaries with synaptic jumps</li>
            <li><span class="text-amber-600">/status</span> — tier counts for current session</li>
          </ul>
          <p class="text-gray-700 mt-3 text-[10px]">
            Queries isolated to your session sandbox. Export your data anytime.
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Structured Response Display ─────────────────────────────────────

  attr :response, :map, required: true
  attr :tenant_id, :string, required: true

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
          <%= if @response.related != [] do %>
            <p class="text-yellow-500 mb-1 mt-2">SYNAPTIC JUMPS:</p>
            <ul class="text-yellow-300 space-y-1">
              <%= for s <- @response.related do %>
                <li>• <%= s %></li>
              <% end %>
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

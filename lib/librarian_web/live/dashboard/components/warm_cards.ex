defmodule LibrarianWeb.Dashboard.Components.WarmCards do
  use Phoenix.Component

  import LibrarianWeb.Dashboard.Components.Helpers

  attr(:tenant_id, :string, required: true)
  attr(:memories, :list, required: true)
  attr(:expanded_memories, :any, required: true)
  attr(:council_pending, :any, required: true)
  attr(:publish_pending, :any, required: true)
  attr(:delegation_progress, :any, required: true)

  def warm_cards(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg p-4 overflow-hidden flex flex-col">
      <h2 class="text-sm font-bold text-gray-300 mb-3 uppercase tracking-wider">
        🧠 WARM Memory Tier
        <span class="text-indigo-400 text-[10px]">[<%= tenant_short(@tenant_id) %>]</span>
      </h2>
      <div class="flex-1 overflow-y-auto space-y-3">
        <%= for memory <- Enum.sort_by(@memories, &(-&1.importance)) do %>
          <.warm_card memory={memory}
            expanded?={MapSet.member?(@expanded_memories, memory.id)}
            delegate_pending?={MapSet.member?(@council_pending, memory.id)}
            publish_pending?={MapSet.member?(@publish_pending, memory.id)}
            progress={Map.get(@delegation_progress, memory.id, nil)}
            tenant_id={@tenant_id} />
        <% end %>
        <p :if={@memories == []} class="text-gray-600 text-xs">
          No memories yet. Run Flood Demo or Swarm Demo to populate.
        </p>
      </div>
    </div>
    """
  end

  # ── Single WARM card (with delegate/publish + progress) ─────────

  attr(:memory, :map, required: true)
  attr(:expanded?, :boolean, required: true)
  attr(:delegate_pending?, :boolean, required: true)
  attr(:publish_pending?, :boolean, required: true)
  attr(:progress, :any, required: false)
  attr(:tenant_id, :string, required: true)

  def warm_card(assigns) do
    memory = assigns.memory

    assigns =
      assigns
      |> assign(:submitted?, not is_nil(memory.council))
      |> assign(:published?, memory.published)
      |> assign(:locked?, memory.locked)
      |> assign(
        :border_class,
        cond do
          memory.published -> "border-emerald-500"
          not is_nil(memory.council) -> "border-violet-500"
          assigns.delegate_pending? or assigns.publish_pending? -> "border-amber-500"
          assigns.expanded? -> "border-blue-500"
          true -> "border-gray-700"
        end
      )

    ~H"""
    <div class={"bg-gray-800 rounded p-3 border #{@border_class} cursor-pointer transition-colors"}
         phx-click="toggle_memory" phx-value-id={@memory.id}>
      <div class="flex items-center gap-2 mb-2">
        <span class={"w-2 h-2 rounded-full flex-shrink-0 #{bucket_color(@memory.bucket)}"} />
        <span class="text-xs font-bold text-gray-200"><%= String.split(@memory.bucket, ":") |> List.last() %></span>

        <%= if @published? do %>
          <span class="text-[10px] text-emerald-400 font-bold ml-1">✅ Published</span>
        <% end %>
        <%= if @submitted? and not @published? do %>
          <span class="text-[10px] text-violet-400 font-bold ml-1">⚖️ Delegated</span>
        <% end %>
        <%= if @locked? and not (@submitted? or @published?) do %>
          <span class="text-[10px] text-amber-400 font-bold ml-1">🔒 Locked</span>
        <% end %>

        <span class="text-xs text-gray-500 ml-auto">#<%= @memory.id %></span>
      </div>

      <p class="text-xs text-gray-300 mb-2"><%= @memory.summary %></p>

      <div class="h-1 bg-gray-700 rounded mb-2">
        <div class="h-1 bg-blue-500 rounded" style={importance_pct(@memory.importance)} />
      </div>

      <%= if @delegate_pending? or @publish_pending? do %>
        <.progress_bar progress={@progress} kind={if(@publish_pending?, do: "publish", else: "council")} />
      <% end %>

      <%= if @expanded? do %>
        <.memory_detail memory={@memory} />
        <%= if @submitted? and not @published? do %>
          <.council_detail memory={@memory} />
          <button phx-click="publish_memory" phx-value-id={@memory.id}
            class="text-xs bg-emerald-700 hover:bg-emerald-600 text-white px-2 py-1.5 rounded transition w-full mt-2 font-bold"
            phx-click-loading-text="Loading…">
            🌐 Review &amp; Publish to Public Graph
          </button>
        <% end %>
        <%= if not @submitted? and not @published? do %>
          <button phx-click="delegate_council" phx-value-id={@memory.id}
            class="text-xs bg-violet-700 hover:bg-violet-600 text-white px-2 py-1.5 rounded transition w-full mt-2 font-bold">
            ⚖️ Delegate to Council
          </button>
        <% end %>
        <.lineage_detail memory={@memory} tenant_id={@tenant_id} />
      <% end %>
    </div>
    """
  end

  # ── Live progress bar (council / publish in flight) ────────────

  attr(:progress, :any, required: false)
  attr(:kind, :string, required: true)

  def progress_bar(assigns) do
    assigns =
      assign(assigns,
        pct: if(is_map(assigns.progress), do: assigns.progress.pct, else: 10),
        label:
          if(assigns.kind == "publish", do: "🌐 Publishing…", else: "⚖️ Delegating to Council…")
      )

    ~H"""
    <div class="mb-2">
      <div class="flex justify-between text-[10px] text-gray-400 mb-1">
        <span><%= @label %></span>
        <span><%= "#{@pct}%" %></span>
      </div>
      <div class="h-1.5 bg-gray-700 rounded overflow-hidden">
        <div class={"h-1.5 rounded transition-all duration-300 " <> if(@kind == "publish", do: "bg-emerald-500", else: "bg-violet-500")}
             style={"width: #{@pct}%"} />
      </div>
    </div>
    """
  end

  # ── Council synthesis detail (after delegate) ─────────────────────

  attr(:memory, :map, required: true)

  def council_detail(assigns) do
    council = assigns.memory.council || %{}

    assigns =
      assign(assigns,
        synthesis: Map.get(council, :synthesis),
        advisory_bucket: Map.get(council, :bucket),
        takes: Map.get(council, :persona_takes, %{})
      )

    ~H"""
    <div class="mt-2 pt-2 border-t border-violet-500/40 space-y-2">
      <div class="text-xs">
        <span class="text-violet-400 font-bold">⚖️ Council Synthesis:</span>
        <p class="text-gray-300 mt-1"><%= @synthesis %></p>
      </div>
      <%= if @advisory_bucket do %>
        <div class="text-[10px] text-violet-300">
          🗂️ Bucket advisory: <span class="font-mono bg-gray-900 px-1 rounded"><%= @advisory_bucket %></span>
          <span class="text-gray-500">(becomes locked at publish)</span>
        </div>
      <% end %>
      <%= if @takes != %{} do %>
        <details class="text-xs">
          <summary class="text-violet-300 cursor-pointer select-none">View persona perspectives</summary>
          <div class="mt-1 space-y-1">
            <%= for {name, take} <- @takes do %>
              <div class="bg-gray-900 rounded p-1.5">
                <span class="text-violet-400 font-bold"><%= name %>:</span>
                <span class="text-gray-300"><%= take %></span>
              </div>
            <% end %>
          </div>
        </details>
      <% end %>
      <%= if @memory.publish_hash do %>
        <div class="text-[10px] text-emerald-400">
          🌐 Node: <span class="font-mono"><%= String.slice(@memory.publish_hash, 0, 16) %></span>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Memory Detail (expanded card) ───────────────────────────────────

  attr(:memory, :map, required: true)

  def memory_detail(assigns) do
    ~H"""
    <div class="mt-2 pt-2 border-t border-gray-700 space-y-2">
      <%= if @memory.raw_original do %>
        <div>
          <span class="text-xs text-gray-400 font-bold">
            📄 Raw Original:
          </span>
          <%= if @memory.stored_path do %>
            <span class="text-[10px] text-gray-600 ml-1">[<%= shorten_path(@memory.stored_path) %>]</span>
          <% end %>
          <%= if @memory.dimensions do %>
            <span class="text-[10px] text-gray-500 ml-1"><%= @memory.dimensions %></span>
          <% end %>
          <div class="mt-1 prose prose-invert prose-xs max-w-none text-xs text-gray-300 bg-gray-900 rounded p-2 overflow-x-auto">
            <%= render_markdown(@memory.raw_original) %>
          </div>
        </div>
        <div class="border-t border-gray-700/50" />
      <% end %>
      <div>
        <span class="text-xs text-gray-400">Facts:</span>
        <%= if @memory.facts && @memory.facts != [] do %>
          <ul class="text-xs text-gray-300 mt-1 space-y-1 list-disc list-inside">
            <%= for fact <- @memory.facts do %>
              <li><%= fact %></li>
            <% end %>
          </ul>
        <% else %>
          <p class="text-xs text-gray-600 mt-1">No facts extracted</p>
        <% end %>
      </div>
      <div class="flex gap-3 text-xs">
        <span class="text-gray-400">Created: <%= DateTime.to_iso8601(@memory.created_at) %></span>
        <%= if @memory.embedding do %>
          <span class="text-blue-400">🔢 Embedding: <%= length(@memory.embedding) %>-dim</span>
        <% end %>
      </div>
      <div class="text-xs">
        <span class="text-gray-400">Tags: </span>
        <%= for tag <- (@memory.tags || []) do %>
          <span class="text-xs bg-gray-700 text-gray-300 rounded px-1.5 py-0.5"><%= tag %></span>
        <% end %>
      </div>
      <%= if @memory.superseded_by do %>
        <div class="text-xs text-yellow-400">🔁 Superseded by #<%= @memory.superseded_by %></div>
      <% end %>
      <button phx-click="open_ancestry" phx-value-id={@memory.id}
        class="text-xs bg-gray-700 hover:bg-gray-600 text-gray-300 px-2 py-1 rounded transition">
        🌳 View Ancestry
      </button>
    </div>
    """
  end

  # ── Lineage Detail (audit trail) ───────────────────────────────────────

  attr(:memory, :map, required: true)
  attr(:tenant_id, :string, required: true)

  def lineage_detail(assigns) do
    # Wrap ColdStore access in try/rescue to prevent UI crashes when DB unavailable
    lineage =
      try do
        Librarian.ColdStore.get_memory_lineage(to_string(assigns.memory.id), assigns.tenant_id)
      rescue
        e ->
          require Logger
          Logger.warning("Lineage lookup failed for memory #{assigns.memory.id}: #{inspect(e)}")
          %{outgoing: [], incoming: []}
      end

    assigns = assign(assigns, :lineage, lineage)

    ~H"""
    <div class="mt-2 pt-2 border-t border-gray-700 space-y-2">
      <div class="text-xs">
        <span class="text-gray-400 font-bold">🔗 Lineage:</span>
      </div>

      <%= if @lineage.outgoing != [] do %>
        <div class="border-l-2 border-fuchsia-500 pl-2">
          <%= for rel <- @lineage.outgoing do %>
            <div class="text-xs mb-1">
              <span class="text-fuchsia-400"><%= relationship_badge(rel.type) %></span>
              <span class="text-gray-400 ml-1">#<%= rel.target_id %></span>
              <%= if rel.metadata && rel.metadata["similarity"] do %>
                <span class="text-gray-600">(sim: <%= Float.round(rel.metadata["similarity"], 2) %>)</span>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>

      <%= if @lineage.incoming != [] do %>
        <div class="border-l-2 border-emerald-500 pl-2">
          <%= for rel <- @lineage.incoming do %>
            <div class="text-xs mb-1">
              <span class="text-emerald-400"><%= relationship_badge(rel.type) %></span>
              <span class="text-gray-400 ml-1">from #<%= rel.source_id %></span>
            </div>
          <% end %>
        </div>
      <% end %>

      <%= if @lineage.outgoing == [] && @lineage.incoming == [] do %>
        <p class="text-xs text-gray-600">No lineage relationships yet.</p>
      <% end %>
    </div>
    """
  end
end

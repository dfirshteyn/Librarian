defmodule LibrarianWeb.Dashboard.Components.Header do
  use Phoenix.Component

  attr(:tenant_id, :string, required: true)
  attr(:tier, :atom, default: :anon)
  attr(:force_local, :boolean, default: false)
  attr(:demo_running, :boolean, required: true)
  attr(:telemetry, :map, required: true)

  def header(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-3">
      <div class="flex items-center gap-3">
        <h1 class="text-xl font-bold text-white">📚 Librarian Beam Memory Layer</h1>
        <code class="text-xs bg-gray-800 px-2 py-0.5 rounded text-indigo-300 font-mono"><%= @tenant_id %></code>
        <button data-tenant-id={@tenant_id}
          onclick="var tid=this.getAttribute('data-tenant-id');navigator.clipboard.writeText(tid);this.textContent='Copied!';setTimeout(()=>this.textContent='📋 Copy',1500)"
          class="text-[10px] bg-indigo-700 hover:bg-indigo-600 text-white px-1.5 py-0.5 rounded transition">
          📋 Copy
        </button>
        <span class={"text-[10px] text-white px-1.5 py-0.5 rounded font-bold " <> tier_badge_color(@tier, @force_local)}>
          <%= tier_label(@tier, @force_local) %>
        </span>
      </div>
      <div class="flex items-center gap-2 flex-wrap justify-end">
        <div class="hidden xl:flex items-stretch gap-1.5 mr-1">
          <.telemetry_pill icon="💸" label="saved" value={format_int(@telemetry.tokens_saved)} accent="text-emerald-300" title={"Raw ingest minus consolidated memory tokens · #{@telemetry.raw_tokens} raw / #{@telemetry.consolidated_tokens} warm"} />
          <.telemetry_pill icon="🧬" label="lineage" value={"D#{@telemetry.lineage_depth} · #{@telemetry.lineage_raw_chunks} chunks"} accent="text-cyan-300" title={"Recursive ancestry max depth and raw chunk edges · #{@telemetry.lineage_edges} total edges"} />
          <.telemetry_pill icon="🌊" label="drift" value={format_percent(@telemetry.synaptic_drift)} accent="text-fuchsia-300" title="Average embedding distance across active WARM cards" />
          <.telemetry_pill icon="🛡️" label="guards" value={format_int(@telemetry.grounding_interventions)} accent="text-amber-300" title="Grounding/fabrication interventions logged by the memory layer" />
        </div>
        <button phx-click="seed_demo"
          disabled={@demo_running}
          class={if @demo_running,
            do: "text-xs px-2 py-1 rounded bg-gray-700 cursor-not-allowed text-gray-500",
            else: "text-xs px-2 py-1 rounded bg-emerald-700 hover:bg-emerald-600 text-white transition font-bold"}>
          <%= if @demo_running, do: "Seeding...", else: "🌱 Seed Demo" %>
        </button>
      </div>
    </div>
    """
  end

  defp tier_label(:judge, false), do: "JUDGE · QWEN API"
  defp tier_label(_tier, true), do: "QWEN API · HACKATHON"
  defp tier_label(_tier, false), do: "QWEN API · HACKATHON"

  defp tier_badge_color(:judge, false), do: "bg-fuchsia-600"
  defp tier_badge_color(_tier, true), do: "bg-amber-600"
  defp tier_badge_color(_tier, false), do: "bg-emerald-600"

  attr(:icon, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:accent, :string, default: "text-indigo-300")
  attr(:title, :string, default: nil)

  defp telemetry_pill(assigns) do
    ~H"""
    <div title={@title} class="bg-gray-900/90 border border-gray-700 rounded-lg px-2 py-1 min-w-[92px] shadow-inner">
      <div class="text-[9px] uppercase tracking-widest text-gray-500"><%= @icon %> <%= @label %></div>
      <div class={"text-[11px] font-black leading-tight " <> @accent}><%= @value %></div>
    </div>
    """
  end

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_int(_), do: "0"

  defp format_percent(nil), do: "n/a"
  defp format_percent(value), do: "#{round(value * 100)}%"
end

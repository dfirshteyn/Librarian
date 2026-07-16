defmodule LibrarianWeb.Dashboard.Components.Helpers do
  @bucket_colors %{
    "project" => "bg-blue-500",
    "research" => "bg-purple-500",
    "finance" => "bg-green-500",
    "ideas" => "bg-yellow-500",
    "thoughts" => "bg-pink-500",
    "inbox" => "bg-gray-500"
  }

  def bucket_colors, do: @bucket_colors

  def buckets_list, do: ["project", "research", "finance", "ideas", "thoughts", "inbox"]

  def bucket_color(bucket),
    do: Map.get(@bucket_colors, String.split(bucket, ":") |> List.last(), "bg-gray-500")

  def importance_pct(importance), do: "width: #{trunc((importance || 0) * 100)}%"

  def tenant_short(tenant_id), do: String.slice(tenant_id, 10, 6)

  # ── Insight Icons ────────────────────────────────────────────────────
  def insight_icon("supersession"), do: "🔄"
  def insight_icon("deep_supersession"), do: "⚠️"
  def insight_icon("deep_cross_connection"), do: "🔗"
  def insight_icon(_), do: "💡"

  def insight_summary(%{"kind" => "supersession"} = m),
    do: "Superseded: \"#{m["old_summary"]}\" → \"#{m["new_summary"]}\""

  def insight_summary(%{"kind" => "deep_supersession"} = m),
    do: "Qwen flagged contradiction: memory ##{m["old_id"]} superseded by ##{m["new_id"]}"

  def insight_summary(%{"kind" => "deep_cross_connection"} = m),
    do: "Qwen connected ##{m["id_a"]} ↔ ##{m["id_b"]}: #{m["note"]}"

  def insight_summary(m), do: inspect(m)

  # ── Relationship Badges ───────────────────────────────────────────────

  @doc """
  Returns distinct badges for memory relationship types.
  Used in warm_cards lineage display.
  """
  def relationship_badge("merged_into"), do: "🛠️ Merged"
  def relationship_badge("superseded_by"), do: "🔁 Superseded"
  def relationship_badge("cross_connected"), do: "🌙 Cross-Connect"
  def relationship_badge("derived_from"), do: "🌙 Derived"
  def relationship_badge(_type), do: "🔗 Link"

  @doc """
  Render markdown to safe HTML using MDEx.
  Used to display extracted PDF content and vision model descriptions
  as formatted HTML in the dashboard.
  """
  def render_markdown(md) when is_binary(md) and md != "" do
    {:safe, MDEx.to_html!(md, render: %{hardbreaks: true})}
  rescue
    _ -> {:safe, md}
  end

  def render_markdown(_), do: {:safe, ""}

  @doc """
  Human-readable file type badge for media attachments.
  """
  def file_badge(nil), do: ""
  def file_badge(mime) when is_binary(mime) do
    cond do
      String.starts_with?(mime, "image/") -> "📷 Image"
      mime == "application/pdf" -> "📄 PDF"
      true -> "📎 #{mime}"
    end
  end

  @doc "Shorten a stored_path for display."
  def shorten_path(nil), do: ""
  def shorten_path(path), do: String.slice(path, -30, 30) |> String.replace_prefix("", "…")
end

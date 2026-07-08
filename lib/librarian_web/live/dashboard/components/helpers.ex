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
end

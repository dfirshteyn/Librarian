defmodule Librarian.McpServer do
  @moduledoc """
  MCP (Model Context Protocol) server for Librarian.

  Runs as a stdio-based MCP server so any MCP-compatible client
  (Claude Desktop, Cline, etc.) can use Librarian as its persistent
  memory backend.

  Tools exposed:
    - `ingest`   — save text to a user's memory store
    - `recall`   — search memories by query
    - `status`   — show tier counts for a user
    - `forget`   — remove memories matching a query
    - `flush`    — drain HOT tier to WARM (curator pass)
    - `briefing` — morning briefing (recent insights)
    - `nightly_pass` — trigger full curation cycle

  Start with:
      Librarian.McpServer.start_link()

  Or via supervisor (recommended for production).
  """

  use GenServer

  # ── public API ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ── GenServer callbacks ──

  @impl true
  def init(_opts) do
    IO.puts(:stderr, "MCP server started — listening on stdin")
    spawn_link(fn -> read_stdin_loop() end)
    {:ok, %{}}
  end

  # ── MCP protocol ──

  defp read_stdin_loop do
    IO.stream(:stdio, :line)
    |> Enum.each(fn line ->
      line = String.trim(line)
      if line != "" do
        case Librarian.Json.decode(line) do
          {:ok, msg} -> handle_message(msg)
          {:error, _} -> :ok
        end
      end
    end)
  end

  # ── Message dispatch ──

  defp handle_message(%{"method" => "initialize", "id" => id}) do
    write_response(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "librarian-mcp", "version" => "0.1.0"}
      }
    })
  end

  defp handle_message(%{"method" => "notifications/initialized"}), do: :ok

  defp handle_message(%{"method" => "tools/list", "id" => id}) do
    tools = [
      %{
        "name" => "ingest",
        "description" => "Save text into the Librarian memory store. Use this to remember facts, decisions, preferences, or any information the user wants persisted across sessions.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "text" => %{"type" => "string", "description" => "The text content to remember"},
            "source" => %{"type" => "string", "description" => "Source identifier (e.g., 'claude', 'chat', 'note')", "default" => "mcp"},
            "tags" => %{"type" => "array", "items" => %{"type" => "string"}, "description" => "Optional hint tags for classification", "default" => []},
            "user_id" => %{"type" => "string", "description" => "User/agent identifier for multi-tenant isolation", "default" => "local"}
          },
          "required" => ["text"]
        }
      },
      %{
        "name" => "recall",
        "description" => "Search memories by query. Returns ranked results with cosine similarity + importance scoring, plus cross-bucket synaptic jumps (connections to related memories in different categories).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search query"},
            "user_id" => %{"type" => "string", "description" => "User/agent identifier", "default" => "local"}
          },
          "required" => ["query"]
        }
      },
      %{
        "name" => "status",
        "description" => "Show memory tier counts (HOT and WARM) for a user.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "user_id" => %{"type" => "string", "description" => "User/agent identifier", "default" => "local"}
          }
        }
      },
      %{
        "name" => "forget",
        "description" => "Remove memories matching a query. Use with caution — this permanently deletes from WARM.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Query to find memories to forget"},
            "user_id" => %{"type" => "string", "description" => "User/agent identifier", "default" => "local"}
          },
          "required" => ["query"]
        }
      },
      %{
        "name" => "flush",
        "description" => "Manually drain HOT buffers to WARM tier through the curator. Converts raw capture text into structured memories (summary, facts, tags, importance score).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "bucket" => %{"type" => "string", "description" => "Specific bucket to flush, or 'all' for all buckets", "default" => "all"}
          }
        }
      },
      %{
        "name" => "briefing",
        "description" => "Get the morning briefing — recent cross-bucket insights and supersessions logged during the last curator pass.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "limit" => %{"type" => "number", "description" => "Number of recent insights to return", "default" => 5}
          }
        }
      },
      %{
        "name" => "nightly_pass",
        "description" => "Trigger the full nightly curation cycle: decay, archive stale memories, and run Qwen deep reasoning pass (when Hybrid curator is configured).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{}
        }
      }
    ]

    write_response(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}})
  end

  defp handle_message(%{"method" => "tools/call", "id" => id, "params" => %{"name" => name, "arguments" => args}}) do
    result = call_tool(name, args || %{})
    write_response(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  # Fallback for unhandled methods
  defp handle_message(%{"method" => method, "id" => id}) do
    write_response(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32601, "message" => "Method not found: #{method}"}
    })
  end

  defp handle_message(_), do: :ok

  # ── Tool dispatch ──

  defp call_tool("ingest", args) do
    text = args["text"]
    source = args["source"] || "mcp"
    tags = args["tags"] || []
    user_id = args["user_id"] || "local"

    case Librarian.ingest(%{"source" => source, "raw_text" => text, "hint_tags" => tags}, user_id) do
      {:ok, bucket} ->
        tool_result(%{
          "ok" => true,
          "bucket" => bucket,
          "user_id" => user_id,
          "note" => "Saved to #{bucket}. Flush to curate into structured memory."
        })

      {:error, reason} ->
        tool_result(%{"ok" => false, "error" => inspect(reason)})
    end
  end

  defp call_tool("recall", args) do
    query = args["query"]
    user_id = args["user_id"] || "local"

    %{warm: warm, related: related} = Librarian.recall(query, user_id)

    tool_result(%{
      "query" => query,
      "user_id" => user_id,
      "direct_memories" => Enum.map(warm, &serialize_memory/1),
      "synaptic_jumps" => Enum.map(related, &serialize_memory/1)
    })
  end

  defp call_tool("status", args) do
    user_id = args["user_id"] || "local"
    tool_result(Librarian.status(user_id))
  end

  defp call_tool("forget", args) do
    query = args["query"]
    user_id = args["user_id"] || "local"
    forgotten = Librarian.command("forget #{query}", user_id)
    tool_result(%{"ok" => true, "forgotten_count" => length(forgotten), "ids" => forgotten})
  end

  defp call_tool("flush", args) do
    bucket = args["bucket"] || "all"

    results =
      case bucket do
        "all" -> Librarian.Flusher.flush_all()
        b -> [Librarian.Flusher.flush_bucket(b)]
      end

    tool_result(%{"ok" => true, "results" => inspect(results)})
  end

  defp call_tool("briefing", args) do
    limit = args["limit"] || 5
    tool_result(%{"insights" => Librarian.morning_briefing(limit)})
  end

  defp call_tool("nightly_pass", _args) do
    tool_result(%{"ok" => true, "result" => Librarian.Flusher.nightly_pass()})
  end

  defp call_tool(name, _args) do
    %{
      "content" => [
        %{"type" => "text", "text" => "Unknown tool: #{name}"}
      ]
    }
  end

  # ── helpers ──

  defp tool_result(data) do
    %{
      "content" => [
        %{"type" => "text", "text" => Librarian.Json.encode(data)}
      ]
    }
  end

  defp serialize_memory(m) do
    %{
      id: m.id,
      bucket: m.bucket,
      summary: m.summary,
      tags: m.tags,
      importance: m.importance,
      facts: m.facts
    }
  end

  defp write_response(response) do
    IO.puts(Librarian.Json.encode(response))
  end
end

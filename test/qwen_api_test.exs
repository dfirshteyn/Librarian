defmodule Librarian.Curator.QwenApiTest do
  use ExUnit.Case, async: false

  alias Librarian.Curator.QwenApi
  alias Librarian.Capture.Payload

  # --- parse logic (no real HTTP) ---

  describe "parse_result/1 (via summarize with mocked HTTP)" do
    test "parses a well-formed Qwen response into a Result struct" do
      result =
        call_parse_result(%{
          "summary" => "switched db to sqlite",
          "facts" => ["team chose sqlite over postgres"],
          "tags" => ["sqlite", "database", "decision"],
          "importance" => 0.8,
          "bucket" => "project"
        })

      assert result.summary == "switched db to sqlite"
      assert result.facts == ["team chose sqlite over postgres"]
      assert result.tags == ["sqlite", "database", "decision"]
      assert result.importance == 0.8
      assert result.bucket == "project"
    end

    test "tolerates missing optional keys with safe defaults" do
      result = call_parse_result(%{"summary" => "minimal response"})

      assert result.summary == "minimal response"
      assert result.facts == []
      assert result.tags == []
      assert result.importance == 0.5
      assert result.bucket == "inbox"
    end

    test "normalizes an unknown model-provided bucket down to inbox" do
      result = call_parse_result(%{"summary" => "x", "bucket" => "not-a-real-bucket"})
      assert result.bucket == "inbox"
    end

    test "coerces integer importance to float" do
      result = call_parse_result(%{"summary" => "s", "importance" => 1})
      assert result.importance == 1.0
    end
  end

  # --- LeakGuard wiring ---

  describe "LeakGuard scrubbing" do
    test "an API key in the raw_text is scrubbed before the prompt is built" do
      test_pid = self()

      plug = fn conn ->
        # body_params is already decoded by Req's plug adapter
        content = get_in(conn.body_params, ["messages", Access.at(0), "content"])
        send(test_pid, {:prompt, content})
        respond_ok(conn, "scrub confirmed")
      end

      with_mock_req(plug, fn ->
        chunk = [%Payload{source: "test", raw_text: "my key is sk-supersecretkey12345678901234"}]
        assert {:ok, result} = QwenApi.summarize(chunk)
        assert result.summary == "scrub confirmed"
      end)

      assert_received {:prompt, prompt}
      refute String.contains?(prompt, "sk-supersecretkey12345678901234")
      assert String.contains?(prompt, "[REDACTED_API_KEY]")
    end
  end

  # --- full HTTP path ---

  describe "summarize/1 full path" do
    test "returns a Result struct on a 200 response" do
      plug = fn conn -> respond_ok(conn, "we switched to sqlite") end

      with_mock_req(plug, fn ->
        chunk = [%Payload{source: "test", raw_text: "we decided to switch to sqlite"}]
        assert {:ok, result} = QwenApi.summarize(chunk)
        assert result.summary == "we switched to sqlite"
        assert is_list(result.tags)
        assert is_float(result.importance)
      end)
    end

    test "returns an error tuple on a non-200 response" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, ~s({"error":"invalid api key"}))
      end

      with_mock_req(plug, fn ->
        chunk = [%Payload{source: "test", raw_text: "some text"}]
        assert {:error, {:api_error, 401, _}} = QwenApi.summarize(chunk)
      end)
    end
  end

  # --- helpers ---

  defp respond_ok(conn, summary) do
    content =
      Jason.encode!(%{
        "summary" => summary,
        "facts" => ["fact one"],
        "tags" => ["tag1", "tag2"],
        "importance" => 0.7
      })

    body =
      Jason.encode!(%{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}]
      })

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, body)
  end

  defp call_parse_result(map) do
    plug = fn conn ->
      content = Jason.encode!(map)

      body =
        Jason.encode!(%{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}]
        })

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end

    with_mock_req(plug, fn ->
      chunk = [%Payload{source: "test", raw_text: "test input"}]
      {:ok, result} = QwenApi.summarize(chunk)
      result
    end)
  end

  defp with_mock_req(plug, fun) do
    Application.put_env(:librarian, :dashscope_api_key, "test-key")
    Application.put_env(:librarian, :req_module, Req.new(plug: plug))

    try do
      fun.()
    after
      Application.delete_env(:librarian, :req_module)
      Application.delete_env(:librarian, :dashscope_api_key)
    end
  end
end

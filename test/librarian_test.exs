defmodule Librarian.JsonTest do
  use ExUnit.Case, async: true
  alias Librarian.Json

  test "round-trips a representative payload" do
    payload = %{
      "source" => "chrome_ext",
      "raw_text" => "quotes \"inside\" and a\nnewline",
      "tags" => ["a", "b"],
      "n" => 42,
      "f" => 1.5,
      "ok" => true,
      "x" => nil
    }

    encoded = Json.encode(payload)
    assert {:ok, decoded} = Json.decode(encoded)
    assert decoded == payload
  end

  test "decodes nested objects and arrays" do
    assert {:ok, %{"a" => [1, 2, %{"b" => "c"}]}} = Json.decode(~s({"a":[1,2,{"b":"c"}]}))
  end

  test "returns an error tuple for malformed input instead of raising" do
    assert {:error, _} = Json.decode("{not json")
  end
end

defmodule Librarian.RouterTest do
  use ExUnit.Case, async: true
  alias Librarian.{Router, Capture.Payload}

  # Ingest-time routing is just namespacing: everything lands in inbox.
  # Semantic classification is deferred to the curator at flush time.
  test "route/2 assigns every payload to the per-user inbox buffer" do
    payload = %Payload{source: "test", raw_text: "we need to fix the deploy script for this repo"}
    assert {"local:inbox", _tags} = Router.route(payload)
  end

  test "routes uncategorized text to inbox without blocking" do
    payload = %Payload{source: "test", raw_text: "the weather today was nice and sunny"}
    assert {"local:inbox", []} = Router.route(payload)
  end

  test "hint_tags carry through even when no keyword rule fires" do
    payload = %Payload{source: "test", raw_text: "nothing matches", hint_tags: ["custom"]}
    assert {"local:inbox", ["custom"]} = Router.route(payload)
  end

  # The keyword classifier is still the deterministic fallback used by the
  # Stub curator (tests). It must use word-boundary matching.
  test "classify_bucket picks the best keyword bucket, defaulting to inbox" do
    assert "project" = Router.classify_bucket("we decided to deploy the new router for this repo")
    assert "research" = Router.classify_bucket("ebbinghaus forgetting curve and spaced retrieval")
    assert "finance" = Router.classify_bucket("alibaba cloud billing and token spend")
    assert "inbox" = Router.classify_bucket("the weather today was nice and sunny")
  end

  test "classify_bucket word-boundary match: 'we' does not match inside 'weather'" do
    assert "inbox" = Router.classify_bucket("the weather was wet")
  end

  test "normalize_bucket rejects unknown buckets and falls back to inbox" do
    assert "project" = Router.normalize_bucket("project")
    assert "inbox" = Router.normalize_bucket("nonsense")
    assert "inbox" = Router.normalize_bucket(nil)
  end
end

defmodule Librarian.Curator.StubTest do
  use ExUnit.Case, async: true
  alias Librarian.Curator.Stub
  alias Librarian.Capture.Payload

  test "summarize extracts a summary, decision-like facts, and tags" do
    chunk = [
      %Payload{
        source: "test",
        raw_text:
          "We decided to switch the database from Postgres to SQLite. It was a long discussion."
      }
    ]

    assert {:ok, result} = Stub.summarize(chunk)
    assert is_binary(result.summary) and result.summary != ""
    assert Enum.any?(result.facts, &String.contains?(&1, "switch"))
    assert is_list(result.tags) and result.tags != []
    assert result.importance >= 0.0 and result.importance <= 1.0
  end

  test "embed returns a deterministic, normalized vector" do
    assert {:ok, v1} = Stub.embed("hello world")
    assert {:ok, v2} = Stub.embed("hello world")
    assert v1 == v2

    norm = v1 |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
    assert_in_delta norm, 1.0, 0.001
  end

  test "similar text embeds more similarly than unrelated text" do
    {:ok, a} = Stub.embed("genserver router bucket elixir")
    {:ok, b} = Stub.embed("genserver router bucket elixir hackathon")
    {:ok, c} = Stub.embed("banana smoothie recipe tropical fruit")

    sim_ab = Stub.cosine_similarity(a, b)
    sim_ac = Stub.cosine_similarity(a, c)
    assert sim_ab > sim_ac
  end
end

defmodule LibrarianPipelineTest do
  use ExUnit.Case, async: false

  # Under Option B all HOT payloads land in the per-user inbox buffer. The
  # semantic bucket is decided by the curator at flush time and written to
  # WARM, so recall/forget must target that WARM bucket (here "local:project").
  test "ingest -> flush -> recall -> forget round trip" do
    {:ok, bucket} =
      Librarian.ingest(%{
        "source" => "test",
        "raw_text" => "we decided to deploy the new router today, fixing the bucket bug"
      })

    # Ingest now namespaces to inbox; the semantic bucket is decided at flush.
    assert bucket == "local:inbox"
    assert Librarian.HotStore.count("local:inbox") >= 1

    assert {:ok, [memory]} = Librarian.Flusher.flush_bucket("local:inbox")
    # Stub classifies the deploy/repo text as "project" — curator wins.
    assert memory.bucket == "local:project"
    assert Librarian.HotStore.count("local:inbox") == 0

    %{warm: warm} = Librarian.recall("deploy")
    assert Enum.any?(warm, &(&1.id == memory.id))

    Librarian.command("forget deploy")
    %{warm: warm_after} = Librarian.recall("deploy")
    refute Enum.any?(warm_after, &(&1.id == memory.id))
  end

  test "crash isolation: killing one bucket's process doesn't affect other buckets" do
    # Kill the "local:inbox" process and verify other buckets still work
    original_hot = Librarian.HotStore.buckets()

    # Create a new bucket by ingesting to it
    test_user = "crash_test_#{:erlang.unique_integer([:positive])}"
    test_inbox = "#{test_user}:inbox"
    Librarian.ingest(%{"source" => "test", "raw_text" => "isolated bucket test"}, test_user)

    # Get the pid for local:inbox and kill it
    [{local_pid, _} | _] = Registry.lookup(Librarian.BucketRegistry, "local:inbox")
    Process.exit(local_pid, :kill)
    Process.sleep(100)

    # The test user's bucket should still be alive and operational
    [{test_pid, _}] = Registry.lookup(Librarian.BucketRegistry, test_inbox)
    assert is_pid(test_pid)

    # Can still ingest to the isolated bucket
    Librarian.ingest(%{"source" => "test", "raw_text" => "still works"}, test_user)
    assert Librarian.HotStore.count(test_inbox) >= 2

    on_exit(fn ->
      Librarian.HotStore.drain(test_inbox)
      Path.wildcard("priv/wal/#{test_user}*.wal") |> Enum.each(&File.rm!/1)
    end)
  end

  setup do
    # Isolate from any other module that wrote to the shared local:inbox HOT
    # buffer (e.g. IngestRouterTest leftovers) before we flush it ourselves.
    Librarian.HotStore.drain("local:inbox")
    Librarian.Wal.truncate("local:inbox")

    on_exit(fn ->
      Enum.each(Librarian.WarmStore.all(), &Librarian.WarmStore.forget(&1.id))
    end)

    :ok
  end
end

defmodule Librarian.WarmStore.DecayPolicyTest do
  use ExUnit.Case, async: false
  alias Librarian.{WarmStore, Curator}

  setup do
    on_exit(fn ->
      Enum.each(WarmStore.all(), &WarmStore.forget(&1.id))
    end)
  end

  test "a :supersede-policy bucket does not decay with time" do
    Application.put_env(:librarian, :decay_policies, %{"local:project" => :supersede})

    memory =
      WarmStore.put("local:project", %Curator.Result{
        summary: "s",
        facts: [],
        tags: ["x"],
        importance: 0.8
      })

    :ets.insert(
      :warm_memories,
      {memory.id, %{memory | last_accessed_at: DateTime.add(DateTime.utc_now(), -10_000_000)}}
    )

    WarmStore.decay_all(60)

    [reloaded] = WarmStore.all()
    assert reloaded.importance == 0.8
  end

  test "a :decay-policy bucket with higher access_count decays slower (retrieval strength)" do
    Application.put_env(:librarian, :decay_policies, %{})
    Application.put_env(:librarian, :default_decay_policy, :decay)

    fresh =
      WarmStore.put("local:ideas", %Curator.Result{
        summary: "a",
        facts: [],
        tags: ["x"],
        importance: 0.8
      })

    often_recalled =
      WarmStore.put("local:ideas", %Curator.Result{
        summary: "b",
        facts: [],
        tags: ["y"],
        importance: 0.8
      })

    long_ago = DateTime.add(DateTime.utc_now(), -300)

    :ets.insert(
      :warm_memories,
      {fresh.id, %{fresh | last_accessed_at: long_ago, access_count: 0}}
    )

    :ets.insert(
      :warm_memories,
      {often_recalled.id, %{often_recalled | last_accessed_at: long_ago, access_count: 20}}
    )

    WarmStore.decay_all(60)

    rarely = WarmStore.all() |> Enum.find(&(&1.id == fresh.id))
    often = WarmStore.all() |> Enum.find(&(&1.id == often_recalled.id))

    assert often.importance > rarely.importance
  end

  test "supersede keeps the old memory but flags it and excludes it from recall by default" do
    Application.put_env(:librarian, :decay_policies, %{"local:project" => :supersede})

    old =
      WarmStore.put("local:project", %Curator.Result{
        summary: "using postgres",
        facts: [],
        tags: ["db"],
        importance: 0.7
      })

    new =
      WarmStore.put("local:project", %Curator.Result{
        summary: "switched to sqlite",
        facts: [],
        tags: ["db"],
        importance: 0.7
      })

    WarmStore.supersede(old.id, new.id)

    # With 3-way RRF, no hard keyword filter — "postgres" recall returns the
    # new memory (ranked by importance + keyword signal), but never the
    # superseded old one (it's still in ETS but filtered out by default)
    result = WarmStore.recall("postgres")
    refute Enum.any?(result, &(&1.id == old.id))

    # include_superseded: true surfaces all memories including superseded ones.
    # Find the old one specifically by id to verify it was flagged.
    all_with_superseded = WarmStore.recall("postgres", "local", include_superseded: true)
    reloaded_old = Enum.find(all_with_superseded, &(&1.id == old.id))
    assert reloaded_old != nil
    assert reloaded_old.superseded_by == new.id
  end
end

defmodule Librarian.FlusherSupersessionTest do
  use ExUnit.Case, async: false

  setup do
    # Isolate from any other module that wrote to the shared local:inbox HOT
    # buffer before we flush it ourselves.
    Librarian.HotStore.drain("local:inbox")
    Librarian.Wal.truncate("local:inbox")

    on_exit(fn ->
      Enum.each(Librarian.WarmStore.all(), &Librarian.WarmStore.forget(&1.id))
    end)

    # "project" => :supersede. After Option B the curator assigns the WARM
    # bucket ("local:project") at flush time; maybe_supersede checks the
    # WARM bucket name, so it correctly applies the :supersede policy.
    Application.put_env(:librarian, :decay_policies, %{"project" => :supersede})
    :ok
  end

  test "flushing a contradicting decision in a :supersede bucket auto-supersedes the prior one" do
    # Ingest lands in local:inbox (HOT buffer); flush routes to curator bucket.
    Librarian.ingest(%{
      "source" => "test",
      "raw_text" => "we decided to deploy using the postgres database for the project"
    })

    {:ok, [first]} = Librarian.Flusher.flush_bucket("local:inbox")

    Librarian.ingest(%{
      "source" => "test",
      "raw_text" => "we decided to deploy using the sqlite database for the project"
    })

    {:ok, [second]} = Librarian.Flusher.flush_bucket("local:inbox")

    # Both land in the curator-chosen project WARM bucket and supersede.
    assert first.bucket == "local:project"
    assert second.bucket == "local:project"
    reloaded_first = Librarian.WarmStore.all() |> Enum.find(&(&1.id == first.id))
    assert reloaded_first.superseded_by == second.id
  end
end

defmodule Librarian.SynapticJumpTest do
  use ExUnit.Case, async: false

  setup do
    on_exit(fn ->
      Enum.each(Librarian.WarmStore.all(), &Librarian.WarmStore.forget(&1.id))
    end)

    Application.put_env(:librarian, :decay_policies, %{})
    :ok
  end

  test "recall surfaces a related memory from a DIFFERENT bucket sharing a tag" do
    Librarian.WarmStore.put("local:project", %Librarian.Curator.Result{
      summary: "deploy uses sqlite now",
      facts: [],
      tags: ["sqlite", "deploy"],
      importance: 0.6
    })

    Librarian.WarmStore.put("local:ideas", %Librarian.Curator.Result{
      summary: "what if we brainstormed an sqlite-based offline cache months ago",
      facts: [],
      tags: ["sqlite", "offline"],
      importance: 0.4
    })

    %{warm: warm, related: related} = Librarian.recall("deploy")

    # With 3-way RRF, both memories appear in warm results even though "ideas"
    # doesn't contain the keyword "deploy" — it's ranked by importance.
    # The project memory ranks first (keyword "deploy" match + higher importance).
    assert length(warm) == 2
    assert hd(warm).bucket == "local:project"
    assert hd(warm).summary == "deploy uses sqlite now"

    # The ideas memory is also surfaced as a cross-bucket synaptic jump via
    # tag overlap with the top project result (shared tag: "sqlite").
    assert length(related) == 1
    assert hd(related).bucket == "local:ideas"
  end
end

defmodule Librarian.LeakGuardTest do
  use ExUnit.Case, async: true
  alias Librarian.LeakGuard

  test "scrubs OpenAI-style sk- API keys" do
    {scrubbed, count} = LeakGuard.scrub("my key is sk-abcdefghijklmnopqrstuvwxyz123456")
    assert count >= 1
    refute String.contains?(scrubbed, "sk-abcdefghijklmnopqrstuvwxyz")
    assert String.contains?(scrubbed, "[REDACTED_API_KEY]")
  end

  test "scrubs AWS access key IDs" do
    {scrubbed, count} = LeakGuard.scrub("export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE")
    assert count >= 1
    assert String.contains?(scrubbed, "[REDACTED_AWS_ACCESS_KEY]")
  end

  test "scrubs Bearer tokens but preserves surrounding text" do
    text = "curl -H \"Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.longtoken\" https://example.com"
    {scrubbed, count} = LeakGuard.scrub(text)
    assert count >= 1
    assert String.contains?(scrubbed, "curl")
    assert String.contains?(scrubbed, "https://example.com")
    refute String.contains?(scrubbed, "eyJhbGciOiJIUzI1NiJ9")
  end

  test "scrubs env-var password assignments but preserves the key name" do
    {scrubbed, count} = LeakGuard.scrub("DATABASE_URL=postgres://user:hunter2@localhost/mydb")
    assert count >= 1
    # The db URL scrubber should catch this
    refute String.contains?(scrubbed, "hunter2")
  end

  test "clean text passes through unchanged with zero count" do
    text = "we decided to switch the project database to sqlite"
    assert {^text, 0} = LeakGuard.scrub(text)
  end

  test "contains_secret? returns true for text with secrets" do
    assert LeakGuard.contains_secret?("sk-abcdefghijklmnopqrstuvwxyz123456")
  end

  test "contains_secret? returns false for clean text" do
    refute LeakGuard.contains_secret?("ordinary project notes about a bug fix")
  end
end

defmodule Librarian.WalTest do
  use ExUnit.Case, async: false
  alias Librarian.{Wal, Capture.Payload}

  @test_bucket "wal_test_#{:erlang.unique_integer([:positive])}"

  setup do
    on_exit(fn ->
      wal_path = "priv/wal/#{@test_bucket}.wal"
      if File.exists?(wal_path), do: File.rm!(wal_path)
    end)
  end

  test "append writes a line that replay reads back as an equivalent payload" do
    payload = %Payload{
      source: "test",
      raw_text: "we decided to use sqlite for this project",
      occurred_at: DateTime.utc_now(),
      hint_tags: ["sqlite"],
      metadata: %{}
    }

    Wal.append(@test_bucket, payload)

    replayed = Wal.replay(@test_bucket) |> Enum.to_list()
    assert length(replayed) == 1
    assert hd(replayed).raw_text == payload.raw_text
    assert hd(replayed).source == payload.source
    assert hd(replayed).hint_tags == payload.hint_tags
  end

  test "replay uses File.stream so it works for multiple entries without reading all at once" do
    for i <- 1..5 do
      Wal.append(@test_bucket, %Payload{source: "test", raw_text: "entry #{i}"})
    end

    replayed = Wal.replay(@test_bucket) |> Enum.to_list()
    assert length(replayed) == 5
    assert Enum.map(replayed, & &1.raw_text) == Enum.map(1..5, &"entry #{&1}")
  end

  test "truncate clears the WAL so replay returns nothing" do
    Wal.append(@test_bucket, %Payload{source: "test", raw_text: "something"})
    assert Wal.pending?(@test_bucket)

    Wal.truncate(@test_bucket)
    refute Wal.pending?(@test_bucket)
    assert Wal.replay(@test_bucket) |> Enum.to_list() == []
  end

  test "pending? returns false for a bucket with no WAL file" do
    refute Wal.pending?("nonexistent_bucket_xyz")
  end
end

defmodule Librarian.WalCrashRecoveryTest do
  use ExUnit.Case, async: false

  @recovery_bucket "recovery_test"

  setup do
    on_exit(fn ->
      wal_path = "priv/wal/#{@recovery_bucket}.wal"
      if File.exists?(wal_path), do: File.rm!(wal_path)

      case Registry.lookup(Librarian.BucketRegistry, @recovery_bucket) do
        [{pid, _}] -> Process.exit(pid, :kill)
        [] -> :ok
      end

      Process.sleep(30)
    end)
  end

  test "HOT bucket recovers unflushed payloads from WAL after a GenServer crash" do
    Librarian.HotStore.put(@recovery_bucket, %Librarian.Capture.Payload{
      source: "test",
      raw_text: "important note that must survive a crash"
    })

    assert Librarian.HotStore.count(@recovery_bucket) == 1
    assert Librarian.Wal.pending?(@recovery_bucket)

    # kill the GenServer — simulates a crash
    [{pid, _}] = Registry.lookup(Librarian.BucketRegistry, @recovery_bucket)
    Process.exit(pid, :kill)
    Process.sleep(100)

    # DynamicSupervisor restarts it; init/1 replays the WAL
    count = Librarian.HotStore.count(@recovery_bucket)
    assert count == 1
    [recovered] = Librarian.HotStore.all(@recovery_bucket)
    assert recovered.raw_text == "important note that must survive a crash"
    assert recovered.metadata["replayed"] == true
  end
end

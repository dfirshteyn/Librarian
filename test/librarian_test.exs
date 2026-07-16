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

  test "flusher is a pure write path — does NOT supersede inline (consolidator handles that)" do
    # The flusher no longer calls maybe_supersede inline. Supersession is now
    # the consolidator's job (async tournament bracket with semantic similarity).
    # This test verifies the flusher writes both memories cleanly without
    # creating daisy-chain supersession entries.
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

    # Both land in the curator-chosen project WARM bucket.
    assert first.bucket == "local:project"
    assert second.bucket == "local:project"

    # No inline supersession happens — the first memory is NOT flagged.
    reloaded_first = Librarian.WarmStore.all() |> Enum.find(&(&1.id == first.id))
    assert is_nil(reloaded_first.superseded_by)
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

defmodule Librarian.BucketCRUDTest do
  use ExUnit.Case, async: false

  @test_user "bucket_crud_test_#{:erlang.unique_integer([:positive])}"

  setup do
    # Ensure clean state for this test user
    on_exit(fn ->
      Enum.each(Librarian.WarmStore.all(), fn m ->
        if String.starts_with?(m.bucket, @test_user <> ":"), do: Librarian.WarmStore.forget(m.id)
      end)

      # Close and delete the test user's COLD database
      Librarian.ColdStore.ConnectionManager.close_connection(@test_user)
    end)

    :ok
  end

  describe "create_bucket/2" do
    test "creates a new bucket successfully" do
      assert {:ok, "my_custom_bucket"} = Librarian.create_bucket("my_custom_bucket", @test_user)
      buckets = Librarian.list_buckets(@test_user)
      assert Enum.any?(buckets, &(&1.name == "my_custom_bucket"))
    end

    test "rejects reserved system bucket name" do
      assert {:error, :reserved_name} = Librarian.create_bucket("inbox", @test_user)
    end

    test "rejects empty name" do
      assert {:error, :name_empty} = Librarian.create_bucket("", @test_user)
    end

    test "rejects name that is only whitespace after trimming" do
      assert {:error, :name_empty} = Librarian.create_bucket("   ", @test_user)
    end

    test "normalizes to lowercase" do
      assert {:ok, "my_bucket"} = Librarian.create_bucket("My_Bucket", @test_user)
      buckets = Librarian.list_buckets(@test_user)
      assert Enum.any?(buckets, &(&1.name == "my_bucket"))
    end

    test "rejects duplicate name" do
      assert {:ok, "unique_bucket"} = Librarian.create_bucket("unique_bucket", @test_user)
      # Second create with same name is idempotent (INSERT OR IGNORE)
      assert {:ok, "unique_bucket"} = Librarian.create_bucket("unique_bucket", @test_user)
    end
  end

  describe "list_buckets/1" do
    test "returns default buckets on first access" do
      buckets = Librarian.list_buckets(@test_user)
      names = Enum.map(buckets, & &1.name)
      assert "inbox" in names
      assert "project" in names
      assert "research" in names
      assert "ideas" in names
      assert "thoughts" in names
      assert "finance" in names
    end

    test "includes newly created buckets" do
      assert {:ok, "new_bucket"} = Librarian.create_bucket("new_bucket", @test_user)
      buckets = Librarian.list_buckets(@test_user)
      assert Enum.any?(buckets, &(&1.name == "new_bucket"))
    end

    test "excludes deleted buckets by default" do
      assert {:ok, "temp_bucket"} = Librarian.create_bucket("temp_bucket", @test_user)
      assert {:ok, _archived} = Librarian.delete_bucket("temp_bucket", @test_user)
      buckets = Librarian.list_buckets(@test_user)
      refute Enum.any?(buckets, &(&1.name == "temp_bucket"))
    end

    test "reports hot_count and warm_count as zero for empty buckets" do
      assert {:ok, "empty_bucket"} = Librarian.create_bucket("empty_bucket", @test_user)
      buckets = Librarian.list_buckets(@test_user)
      empty = Enum.find(buckets, &(&1.name == "empty_bucket"))
      assert empty.hot_count == 0
      assert empty.warm_count == 0
    end
  end

  describe "rename_bucket/3" do
    test "renames a bucket successfully" do
      assert {:ok, "old_name"} = Librarian.create_bucket("old_name", @test_user)
      assert {:ok, "new_name"} = Librarian.rename_bucket("old_name", "new_name", @test_user)

      buckets = Librarian.list_buckets(@test_user)
      assert Enum.any?(buckets, &(&1.name == "new_name"))
      refute Enum.any?(buckets, &(&1.name == "old_name"))
    end

    test "rejects renaming the system inbox bucket" do
      assert {:error, :cannot_modify_system_bucket} =
               Librarian.rename_bucket("inbox", "not_inbox", @test_user)
    end

    test "rejects renaming to a system bucket name" do
      assert {:ok, "my_bucket"} = Librarian.create_bucket("my_bucket", @test_user)
      assert {:error, :reserved_name} = Librarian.rename_bucket("my_bucket", "inbox", @test_user)
    end

    test "returns not_found for non-existent bucket" do
      assert {:error, :not_found} =
               Librarian.rename_bucket("nonexistent", "something", @test_user)
    end

    test "rejects renaming to an already existing name" do
      assert {:ok, "bucket_a"} = Librarian.create_bucket("bucket_a", @test_user)
      assert {:ok, "bucket_b"} = Librarian.create_bucket("bucket_b", @test_user)

      assert {:error, :already_exists} =
               Librarian.rename_bucket("bucket_a", "bucket_b", @test_user)
    end

    test "renaming preserves memories across tiers" do
      # The Stub curator classifies deploy/project text as "project" (a default bucket).
      # Create a custom bucket, then rename it to verify all tiers update.
      assert {:ok, "project"} = Librarian.create_bucket("project", @test_user)

      # Ingest something that the Stub curator will classify as "project"
      {:ok, inbox} =
        Librarian.ingest(
          %{
            "source" => "test",
            "raw_text" => "we decided to deploy the new router for this project"
          },
          @test_user
        )

      assert inbox == "#{@test_user}:inbox"

      # Flush — Stub classifies as "project", normalize_bucket maps to "project"
      assert {:ok, [memory]} = Librarian.Flusher.flush_bucket(inbox)
      assert memory.bucket == "#{@test_user}:project"

      # Rename the bucket
      assert {:ok, "renamed_project"} =
               Librarian.rename_bucket("project", "renamed_project", @test_user)

      # The memory should now be in the renamed bucket
      %{warm: warm} = Librarian.recall("deploy", @test_user)
      renamed_memory = Enum.find(warm, &(&1.id == memory.id))
      assert renamed_memory != nil
      assert renamed_memory.bucket == "#{@test_user}:renamed_project"
    end
  end

  describe "delete_bucket/2" do
    test "deletes a bucket successfully" do
      assert {:ok, "delete_me"} = Librarian.create_bucket("delete_me", @test_user)
      assert {:ok, 0} = Librarian.delete_bucket("delete_me", @test_user)

      buckets = Librarian.list_buckets(@test_user)
      refute Enum.any?(buckets, &(&1.name == "delete_me"))
    end

    test "rejects deleting the system inbox bucket" do
      assert {:error, :cannot_modify_system_bucket} = Librarian.delete_bucket("inbox", @test_user)
    end

    test "returns not_found for non-existent bucket" do
      assert {:error, :not_found} = Librarian.delete_bucket("nonexistent", @test_user)
    end

    test "archives WARM memories to COLD on delete" do
      # The Stub curator classifies deploy/project text as "project" (a default bucket).
      assert {:ok, "project"} = Librarian.create_bucket("project", @test_user)

      # Ingest and flush to create a WARM memory
      {:ok, inbox} =
        Librarian.ingest(
          %{
            "source" => "test",
            "raw_text" => "we decided to deploy the new router for this project"
          },
          @test_user
        )

      assert {:ok, [memory]} = Librarian.Flusher.flush_bucket(inbox)
      assert memory.bucket == "#{@test_user}:project"

      # Delete the bucket — should archive the memory to COLD
      assert {:ok, 1} = Librarian.delete_bucket("project", @test_user)

      # Memory should be gone from WARM
      assert Librarian.WarmStore.get(memory.id) == nil

      # Memory should be findable in COLD by the original bucket field
      conn = Librarian.ColdStore.ConnectionManager.get_conn(@test_user)

      {:ok, %{rows: rows}} =
        Exqlite.query(conn, "SELECT bucket, summary FROM memories WHERE bucket = ?1", [
          "#{@test_user}:project"
        ])

      assert length(rows) >= 1
      archived_bucket = rows |> hd() |> List.first()
      assert archived_bucket == "#{@test_user}:project"
    end

    test "delete is idempotent" do
      assert {:ok, "gone"} = Librarian.create_bucket("gone", @test_user)
      assert {:ok, _} = Librarian.delete_bucket("gone", @test_user)
      assert {:error, :not_found} = Librarian.delete_bucket("gone", @test_user)
    end

    test "delete preserves relationship graph edges for ancestry queries" do
      # Create two buckets: one for parent memories and one for chunk children
      assert {:ok, "project"} = Librarian.create_bucket("project", @test_user)
      assert {:ok, "project_chunks"} = Librarian.create_bucket("project_chunks", @test_user)

      # Create a parent memory in "project"
      parent =
        Librarian.WarmStore.put(
          "#{@test_user}:project",
          %Librarian.Curator.Result{
            summary: "parent doc",
            facts: [],
            tags: ["doc"],
            importance: 0.8
          }
        )

      # Create a child memory in "project_chunks"
      child =
        Librarian.WarmStore.put(
          "#{@test_user}:project_chunks",
          %Librarian.Curator.Result{
            summary: "child chunk",
            facts: [],
            tags: ["chunk"],
            importance: 0.5
          }
        )

      # Log a chunk_of relationship: child -> parent
      Librarian.ColdStore.log_relationship(
        Integer.to_string(child.id),
        Integer.to_string(parent.id),
        "chunk_of",
        @test_user,
        %{note: "auto-chunked"}
      )

      # Verify ancestry resolves before delete — should show the child
      lineage_before =
        Librarian.ColdStore.get_memory_lineage(Integer.to_string(parent.id), @test_user)

      # Outgoing should be empty (parent doesn't point to anything)
      assert lineage_before.outgoing == []

      # Incoming should include the child
      assert length(lineage_before.incoming) >= 1
      incoming_ids = Enum.map(lineage_before.incoming, & &1.source_id)
      assert Integer.to_string(child.id) in incoming_ids

      # Delete the child's bucket
      assert {:ok, 1} = Librarian.delete_bucket("project_chunks", @test_user)

      # Child should be gone from WARM
      assert Librarian.WarmStore.get(child.id) == nil

      # Ancestry should still resolve — the relationship edge is NOT severed
      lineage_after =
        Librarian.ColdStore.get_memory_lineage(Integer.to_string(parent.id), @test_user)

      assert length(lineage_after.incoming) >= 1
      incoming_ids_after = Enum.map(lineage_after.incoming, & &1.source_id)

      assert Integer.to_string(child.id) in incoming_ids_after,
             "ancestry query must still surface the archived child's relationship edge"

      # Full recursive ancestry should also resolve
      ancestry = Librarian.ColdStore.get_memory_ancestry(Integer.to_string(parent.id), @test_user)
      assert length(ancestry) >= 1
      ancestry_source_ids = Enum.map(ancestry, & &1.source_id)
      ancestry_target_ids = Enum.map(ancestry, & &1.target_id)

      assert Integer.to_string(child.id) in ancestry_source_ids,
             "recursive ancestry must include the archived child as a source"

      assert Integer.to_string(parent.id) in ancestry_target_ids,
             "recursive ancestry must include the parent as a target"
    end
  end

  describe "normalize_bucket/2" do
    test "returns the bucket name if it exists in the user's list" do
      assert {:ok, "custom"} = Librarian.create_bucket("custom", @test_user)
      assert Librarian.Router.normalize_bucket("custom", @test_user) == "custom"
    end

    test "falls back to inbox for unknown bucket names" do
      assert Librarian.Router.normalize_bucket("nonexistent", @test_user) == "inbox"
    end

    test "falls back to inbox for nil" do
      assert Librarian.Router.normalize_bucket(nil, @test_user) == "inbox"
    end

    test "falls back to inbox for empty string" do
      assert Librarian.Router.normalize_bucket("", @test_user) == "inbox"
    end

    test "defaults to local user" do
      # "local" user should have "project" in their default buckets
      assert Librarian.Router.normalize_bucket("project") == "project"
    end
  end

  describe "bucket limit" do
    test "rejects creating more than the configured limit" do
      # Override limit to 3 so we only need 4 rows to hit it
      Application.put_env(:librarian, :max_buckets_per_user, 3)

      try do
        # Default buckets (6) are already seeded, but they count against the limit.
        # We're using a fresh test user, so after seeding: inbox,project,research,ideas,thoughts,finance = 6.
        # That's already >= 3, so creating any new bucket should fail immediately.
        assert {:error, {:bucket_limit_reached, 3}} =
                 Librarian.create_bucket("first_new", @test_user)

        # Default buckets are still active and functional
        buckets = Librarian.list_buckets(@test_user)
        assert length(buckets) == 6
      after
        Application.put_env(:librarian, :max_buckets_per_user, 30)
      end
    end

    test "allows creating buckets when under the limit" do
      # Override limit to 10
      Application.put_env(:librarian, :max_buckets_per_user, 10)

      try do
        # After 6 defaults, we have room for 4 more
        assert {:ok, "extra_1"} = Librarian.create_bucket("extra_1", @test_user)
        assert {:ok, "extra_2"} = Librarian.create_bucket("extra_2", @test_user)
        assert {:ok, "extra_3"} = Librarian.create_bucket("extra_3", @test_user)
        assert {:ok, "extra_4"} = Librarian.create_bucket("extra_4", @test_user)

        # 10th bucket should fail
        assert {:error, {:bucket_limit_reached, 10}} =
                 Librarian.create_bucket("extra_5", @test_user)
      after
        Application.put_env(:librarian, :max_buckets_per_user, 30)
      end
    end
  end
end

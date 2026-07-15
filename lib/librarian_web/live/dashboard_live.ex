defmodule LibrarianWeb.DashboardLive do
  use LibrarianWeb, :live_view

  import LibrarianWeb.Dashboard.Components.Header
  import LibrarianWeb.Dashboard.Components.TenantBanner
  import LibrarianWeb.Dashboard.Components.TierBar
  import LibrarianWeb.Dashboard.Components.IngestFeed
  import LibrarianWeb.Dashboard.Components.WarmCards
  import LibrarianWeb.Dashboard.Components.StructuredRecallTerminal
  import LibrarianWeb.Dashboard.Components.InsightsPanel
  import LibrarianWeb.Dashboard.Components.AncestryModal
  alias Librarian.{WarmStore, HotStore, Flusher}
  require Logger

  # ── Swarm / Flood demo texts ─────────────────────────────────────────
  @demo_texts [
    "deployed the new Phoenix LiveView endpoint to production after load testing",
    "switched the primary database from Postgres to SQLite for the edge nodes",
    "fixed the N+1 query in the user dashboard that was causing 5s page loads",
    "refactored the GenServer pool to use a DynamicSupervisor for better fault isolation",
    "added ETS caching for the session lookup, cut latency from 50ms to 0.2ms",
    "the BEAM processes 1M concurrent WebSocket connections on a single 8GB node",
    "upgraded to OTP 27 for the new partition detector and improved process monitoring",
    "implemented a CircuitBreaker for the payment gateway API calls",
    "shipped the new React component library with 30 accessible components",
    "the TypeScript strict mode migration caught 47 type errors in the router",
    "optimized the bundle size from 2.4MB to 480KB with code splitting and tree shaking",
    "implemented the virtual list component that renders 10k rows at 60fps",
    "the BGE-M3 embedding model achieves 0.92 recall on the retrieval benchmark",
    "fine-tuned the 1.5B Qwen model on domain-specific code documentation",
    "the cosine similarity search over 50k embeddings completes in 12ms with hnswlib",
    "implemented the RAG pipeline with hybrid search: BM25 keyword + dense vector retrieval",
    "the CI pipeline now runs 4 parallel test shards, cutting build time from 18m to 5m",
    "migrated the Docker base image from Debian to Alpine, saving 340MB per image",
    "the Kubernetes rollout strategy uses canary deployments with 10% traffic shifting",
    "the Terraform module now manages 3 environments with remote state locking",
    "the Grafana dashboard monitors 47 metrics across all services with 15s scrape intervals",
    "the GitHub Actions workflow deploys to staging on every PR merge automatically",
    "the Prometheus alert rules catch 90% of production incidents within 30 seconds",
    "the Ansible playbook provisions a new node in 4 minutes with zero manual steps",
    "the ELK stack ingests 50GB of logs daily with 7-day retention and hot-warm architecture",
    "the Docker Compose setup spawns 12 services for the local development environment",
    "the SRE runbook for database failover was tested: RTO is 90 seconds, RPO is 5 seconds",
    "the Helm chart packages the microservice with configurable resource limits and autoscaling",
    "the ArgoCD sync policy uses automated pruning with self-healing enabled",
    "the PagerDuty integration routes critical alerts to the on-call engineer within 2 minutes",
    "the SSL certificate renewal is automated via cert-manager with Let's Encrypt",
    "the React Native app now supports dark mode and dynamic type across all screens",
    "the SwiftUI migration is 60% complete with 12 screens converted from UIKit",
    "the app launch time improved from 3.2s to 0.8s with lazy module loading",
    "implemented the offline-first architecture with SQLite sync and conflict resolution",
    "the push notification system handles 5 different event types with rich media attachments",
    "the Kotlin Multiplatform module shares 70% of business logic between iOS and Android",
    "the app size was reduced from 120MB to 45MB with asset optimization and code stripping",
    "the crash rate dropped from 0.8% to 0.05% after the memory leak fix in the image cache",
    "the Airflow DAG now processes 5M events daily with 6 parallel task pipelines",
    "the dbt models transformed the raw event stream into 12 analytics tables",
    "the Spark streaming job reads from 3 Kafka topics with exactly-once semantics",
    "the data quality checks catch 99.2% of anomalies before they reach the dashboard",
    "the BigQuery partition pruning reduced query costs by 65% on the 2TB events table",
    "the ETL pipeline latency dropped from 45 minutes to 90 seconds with the streaming rewrite",
    "the ClickHouse columnar storage compresses the 10TB dataset to 1.2TB on disk",
    "the schema evolution handling supports backward-compatible changes across 50 table versions",
    "the real-time analytics dashboard refreshes every 5 seconds with sub-second query times",
    "the data lakehouse architecture uses Iceberg tables with ACID transactions on S3",
    "the data profiling job runs nightly and detects 15 types of data quality issues",
    "the Flink job processes 100k events/second with 100ms end-to-end latency",
    "the time-series database stores 90 days of metrics at 10-second granularity",
    "the data catalog indexes 2,000 tables with column-level lineage tracking",
    "the A/B testing pipeline computes statistical significance for 50 concurrent experiments",
    "the OAuth 2.0 implementation passes all 47 security conformance tests",
    "the penetration test found 3 medium-severity issues in the API authentication layer",
    "the secrets rotation policy enforces 90-day rotation for all service accounts",
    "the SBOM generation is now part of the CI pipeline, tracking 340 dependencies",
    "the rate limiting middleware blocks 99.5% of brute force attempts on the login endpoint",
    "the CSP headers prevent XSS attacks across all 15 content types served by the app",
    "the API key hashing uses bcrypt with cost factor 12, taking 250ms per verification",
    "the Q2 roadmap prioritizes the memory graph visualization feature for the hackathon demo",
    "the user research study found that 73% of developers want local-first memory storage",
    "the competitive analysis shows our memory stack is 10x cheaper than Pinecone at scale",
    "the feature request for multi-tenant isolation was the #1 ask from enterprise customers",
    "the retention metric improved by 34% after adding the recall console to the dashboard",
    "the pricing model is usage-based: $0.50 per 1M tokens curated, no per-seat license",
    "the beta users reported 92% satisfaction with the BEAM-based concurrent ingest pipeline",
    "the partnership with the Elixir community targets the real-time agent infrastructure market",
    "the go-to-market strategy focuses on agent swarms and edge computing use cases",
    "the hackathon pitch highlights three pillars: concurrency, isolation, and local-first",
    "the customer interview feedback: they want to run this on a Raspberry Pi for field agents",
    "the MVP milestone is 100 concurrent users with sub-100ms recall latency on a single node",
    "the integration with Claude Code and VS Code extensions is planned for Q3 release",
    "the unit economics: $0.002 per memory per month, 95% gross margin at 10M memories",
    "the demo script walks through: flood ingest, multi-tenant isolation, nightly deep pass",
    "the load balancer handles 50k concurrent connections with 10ms p99 latency",
    "the auto-scaling policy spawns a new node within 45 seconds when CPU hits 75%",
    "the CDN cache hit rate is 87% for static assets, reducing origin load by 6x",
    "the failover test between availability zones completed in 30 seconds with zero data loss",
    "the network throughput between nodes averages 40Gbps with kernel bypass (DPDK)",
    "the DNS resolution for the service mesh uses Consul with 10ms lookups at 99th percentile",
    "the storage backend uses NVMe RAID-10 arrays with 500k IOPS and 100μs latency",
    "the Redis cluster handles 200k ops/second across 12 nodes with automatic failover",
    "the nginx reverse proxy terminates TLS for 15 upstream services with OCSP stapling",
    "the anycast routing distributes traffic across 5 global regions with automatic failover",
    "the memory-mapped file I/O achieves 5GB/s read throughput on the NVMe storage layer",
    "the systemd service units enforce CPU and memory cgroups with OOM protection",
    "the automated test suite runs 1,200 tests in 4 minutes with 98% pass rate",
    "the regression test suite caught 3 bugs in the latest deploy that were immediately fixed",
    "the property-based testing found 2 edge cases in the memory decay algorithm",
    "the load test simulated 10k concurrent users with 200ms p95 response time",
    "the E2E test suite covers 45 critical user journeys across the web dashboard",
    "the A/B test results show the new recall algorithm is 23% more accurate at finding relevant memories",
    "the chaos engineering test killed 3 random processes and verified the supervisor tree recovery",
    "the mutation testing scored 82%, identifying 15 untested code paths in the curator module",
    "the API contract tests validate 50 endpoints with request/response schema enforcement",
    "the performance regression benchmark runs nightly and alerts on >5% latency increase",
    "the fuzz testing on the ingest endpoint found 0 crashes after 1M random inputs",
    "the integration test verifies the HOT→WARM→COLD pipeline with 100 sample memories",
    "the stress test maintained 99.9% uptime with 5x the expected production load",
    "the smoke test suite runs in 30 seconds and validates all 12 critical system functions",
    "the test coverage report shows 91% line coverage across the core library modules",
    "the weather today was perfect for a long walk",
    "picked up coffee beans from the market, the Ethiopian blend is excellent",
    "watched a documentary about octopus cognition, genuinely fascinating",
    "the new keyboard arrived, mechanical switches feel much better",
    "tried the new ramen place downtown, the tonkotsu broth was outstanding"
  ]

  @impl true
  def mount(_params, session, socket) do
    # Identity comes from the signed, server-verified claim persisted in the
    # session by Librarian.Auth.Plug — never from a client-supplied URL param.
    # A forged or hand-edited ?tid= simply fails verification and falls back to
    # a fresh anonymous sandbox, so tier escalation is impossible.
    tenant_id =
      case session do
        %{"sandbox_id" => sid} when is_binary(sid) and byte_size(sid) > 0 ->
          sid

        _ ->
          # Fallback (e.g. unit tests) — never happens in the browser pipeline.
          Librarian.Auth.generate_anon_id()
      end

    # Tier is part of the signed claim, so it is authentic.
    tier = Map.get(session, "tier", :anon)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Librarian.PubSub, "ingest")
      Phoenix.PubSub.subscribe(Librarian.PubSub, "flush")
      Phoenix.PubSub.subscribe(Librarian.PubSub, "delegation:#{tenant_id}")
      :timer.send_interval(2000, self(), :refresh_warm)
    end

    {:ok,
     socket
     |> stream(:feed, [])
     |> assign(:feed_empty, true)
     |> assign(:tenant_id, tenant_id)
     |> assign(:tier, tier)
     |> assign(:force_local, false)
     |> assign_memories(tenant_id)
     |> assign(:hot_counts, hot_counts(tenant_id))
     |> assign(:query, "")
     |> assign(:recall_results, nil)
     |> assign(:insights, Librarian.morning_briefing(20))
     |> assign(:token_savings, compute_token_savings(tenant_id))
     |> assign(:ingest_text, "")
     |> assign(:ingest_bucket, "inbox")
     |> assign(:expanded_memories, MapSet.new())
     |> assign(:demo_running, false)
     |> assign(:demo_total, 0)
     |> assign(:ancestry_memory_id, nil)
     |> assign(:ancestry_tree, [])
     |> assign(:structured_response, nil)
     |> assign(:council_pending, MapSet.new())
     |> assign(:publish_pending, MapSet.new())
     |> assign(:delegation_progress, %{})
     |> assign(:publish_confirm_id, nil)
     |> assign(:publish_confirm_synthesis, nil)
     |> assign(
       :flush_concurrency,
       Application.get_env(:librarian, :parallel_flush_max_concurrency, 1)
     )}
  end

  # ── PubSub handlers ─────────────────────────────────────────────────

  @impl true
  def handle_info({:ingested, bucket, source, preview, user_id}, socket) do
    entry = %{
      id: System.unique_integer([:positive, :monotonic]),
      bucket: bucket,
      source: source,
      preview: preview,
      user_id: user_id,
      at: Time.utc_now() |> Time.truncate(:second)
    }

    tid = socket.assigns.tenant_id

    {:noreply,
     socket
     |> stream_insert(:feed, entry, at: 0, limit: 50)
     |> assign(:feed_empty, false)
     |> assign(:hot_counts, hot_counts(tid))}
  end

  def handle_info({:flushed, _bucket}, socket) do
    tid = socket.assigns.tenant_id

    {:noreply,
     socket
     |> assign_memories(tid)
     |> assign(:hot_counts, hot_counts(tid))
     |> assign(:token_savings, compute_token_savings(tid))}
  end

  def handle_info(:refresh_warm, socket) do
    tid = socket.assigns.tenant_id

    {:noreply,
     socket
     |> assign_memories(tid)
     |> assign(:hot_counts, hot_counts(tid))
     |> assign(:insights, Librarian.morning_briefing(20))
     |> assign(:token_savings, compute_token_savings(tid))}
  end

  # ── PublicGraph refresh tick ───────────────────────────────────────────
  # :timer.send_interval in a LiveComponent's mount/1 sends to self(), which
  # resolves to the *parent LiveView* PID (components share the LV process).
  # We catch the tick here and forward it to the component via send_update/2,
  # which triggers PublicGraph.update/2 and reloads graph data.
  def handle_info(:refresh_graph, socket) do
    send_update(LibrarianWeb.Dashboard.Components.PublicGraph, id: "public_graph")
    {:noreply, socket}
  end

  # ── Delegation / Publish progress ─────────────────────────────────

  def handle_info({:council_progress, id, stage, pct}, socket) do
    socket = update_progress(socket, :delegation_progress, id, stage, pct)

    socket =
      if stage == :done or stage == :error do
        socket
        |> update(:council_pending, &MapSet.delete(&1, id))
        |> assign_memories(socket.assigns.tenant_id)
      else
        update(socket, :council_pending, &MapSet.put(&1, id))
      end

    {:noreply, socket}
  end

  def handle_info({:publish_progress, id, stage, pct}, socket) do
    socket = update_progress(socket, :delegation_progress, id, stage, pct)

    socket =
      if stage == :done or stage == :error do
        socket
        |> update(:publish_pending, &MapSet.delete(&1, id))
        |> assign_memories(socket.assigns.tenant_id)
      else
        update(socket, :publish_pending, &MapSet.put(&1, id))
      end

    {:noreply, socket}
  end

  defp update_progress(socket, key, id, stage, pct) do
    current = socket.assigns[key]
    assign(socket, key, Map.put(current, id, %{stage: stage, pct: pct}))
  end

  # ── Structured recall commands ─────────────────────────────────────

  @impl true
  def handle_event("structured_recall", %{"command" => cmd}, socket) do
    tid = socket.assigns.tenant_id

    case String.split(String.trim(cmd)) do
      ["/model" | query_parts] ->
        query = Enum.join(query_parts, " ")
        results = Librarian.recall(query, tid, force_local: socket.assigns.force_local)

        response = %{
          type: "model_recall",
          query: query,
          count: length(results.warm),
          memories:
            Enum.map(results.warm, fn m ->
              %{
                id: m.id,
                bucket: m.bucket,
                summary: m.summary,
                facts: m.facts || [],
                tags: m.tags || [],
                importance: m.importance,
                created: DateTime.to_iso8601(m.created_at)
              }
            end)
        }

        {:noreply, assign(socket, :structured_response, response)}

      ["/recall" | query_parts] ->
        query = Enum.join(query_parts, " ")
        results = Librarian.recall(query, tid, force_local: socket.assigns.force_local)

        response = %{
          type: "search_recall",
          query: query,
          warm_count: length(results.warm),
          related_count: length(results.related),
          warm: Enum.take(Enum.map(results.warm, & &1.summary), 5),
          related: Enum.take(Enum.map(results.related, & &1.summary), 3)
        }

        {:noreply, assign(socket, :structured_response, response)}

      ["/status"] ->
        status = Librarian.status(tid)
        response = %{type: "status", data: Map.delete(status, [:user_id])}
        {:noreply, assign(socket, :structured_response, response)}

      _ ->
        response = %{
          type: "error",
          message: "Unknown command. Use /model [query], /recall [query], or /status"
        }

        {:noreply, assign(socket, :structured_response, response)}
    end
  end

  # ── Event handlers ──────────────────────────────────────────────────

  @impl true
  def handle_event("recall", %{"query" => q}, socket) when byte_size(q) > 0 do
    tid = socket.assigns.tenant_id
    results = Librarian.recall(q, tid, force_local: socket.assigns.force_local)

    {:noreply,
     assign(socket, :recall_results, %{query: q, warm: results.warm, related: results.related})}
  end

  def handle_event("recall", _params, socket) do
    {:noreply, assign(socket, :recall_results, nil)}
  end

  def handle_event("flush_all", _params, socket) do
    Flusher.flush_all(socket.assigns.tenant_id, socket.assigns.flush_concurrency,
      force_local: socket.assigns.force_local
    )
    tid = socket.assigns.tenant_id

    {:noreply,
     socket
     |> assign_memories(tid)
     |> assign(:hot_counts, hot_counts(tid))
     |> assign(:token_savings, compute_token_savings(tid))
     |> put_flash(:info, "Flushed all buckets")}
  end

  def handle_event("nightly_pass", _params, socket) do
    concurrency = socket.assigns.flush_concurrency
    force_local = socket.assigns.force_local

    Task.start(fn ->
      Flusher.flush_all(concurrency, force_local: force_local)
      Flusher.nightly_pass()
      Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:flushed, :all})
    end)

    {:noreply, put_flash(socket, :info, "Nightly pass started (async)")}
  end

  def handle_event("set_flush_concurrency", %{"value" => value}, socket) do
    concurrency = String.to_integer(value)
    {:noreply, assign(socket, :flush_concurrency, concurrency)}
  end

  # Toggle: force the local 1.7B model even for judge accounts (lets you
  # show the speed/clarity difference side-by-side during the demo).
  def handle_event("toggle_force_local", _params, socket) do
    {:noreply, assign(socket, :force_local, not socket.assigns.force_local)}
  end

  # Force an explicit consolidation sweep using the tier-resolved curator.
  # Judges (and anyone not forcing local) get the premium cloud re-curation;
  # free tier uses the local model. This is the same engine the background
  # AutomationServer polls on, just triggered on-demand from the dashboard.
  def handle_event("force_consolidation", _params, socket) do
    tid = socket.assigns.tenant_id
    force_local = socket.assigns.force_local

    Task.start(fn ->
      Librarian.Consolidator.consolidate(tid, force_local: force_local)
      Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:flushed, tid})
    end)

    {:noreply, put_flash(socket, :info, "Consolidation sweep started for #{tid}")}
  end

  # ── Delegate to Council (single memory) ──────────────────────────
  # Runs one memory at a time. Spawns async + broadcasts live progress
  # over `delegation:#{tid}` so the card renders a loading bar. The
  # memory is hard-locked inside Librarian.Delegation for the duration.
  def handle_event("delegate_council", %{"id" => id}, socket) do
    tid = socket.assigns.tenant_id
    memory_id = String.to_integer(id)

    # Skip if already in flight (idempotent against double-clicks)
    if MapSet.member?(socket.assigns.council_pending, memory_id) do
      {:noreply, socket}
    else
      socket = update(socket, :council_pending, &MapSet.put(&1, memory_id))

      Task.start(fn ->
        case Librarian.Delegation.delegate_to_council(memory_id, tid) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Phoenix.PubSub.broadcast(
              Librarian.PubSub,
              "delegation:#{tid}",
              {:council_progress, memory_id, :error, 0}
            )

            Phoenix.LiveView.send_update(__MODULE__,
              id: "dashboard",
              flash: %{error: "Delegate failed: #{inspect(reason)}"}
            )
        end
      end)

      {:noreply, socket}
    end
  end

  # ── Publish confirm modal state ─────────────────────────────────────
  # The user must explicitly confirm publishing after seeing the actual
  # synthesis text that will go public (with a privacy warning). Clicking
  # "Publish" on the card just opens the modal; the async work only fires
  # after the user clicks "Confirm Publish" inside the modal.

  def handle_event("publish_memory", %{"id" => id}, socket) do
    memory_id = String.to_integer(id)

    # Guard: skip if already in flight or already published
    if MapSet.member?(socket.assigns.publish_pending, memory_id) do
      {:noreply, socket}
    else
      # Load the memory and open the confirm modal — do NOT publish yet.
      memory = Librarian.WarmStore.get(memory_id)

      if memory && memory.council && is_binary(memory.council[:synthesis]) do
        {:noreply,
         socket
         |> assign(:publish_confirm_id, memory_id)
         |> assign(:publish_confirm_synthesis, memory.council[:synthesis])}
      else
        {:noreply, put_flash(socket, :error, "Memory has no Council synthesis — delegate first.")}
      end
    end
  end

  def handle_event("cancel_publish", _params, socket) do
    {:noreply,
     socket
     |> assign(:publish_confirm_id, nil)
     |> assign(:publish_confirm_synthesis, nil)}
  end

  # ── Confirmed publish — this is where the actual async work fires ────
  def handle_event("confirm_publish", %{"id" => id}, socket) do
    tid = socket.assigns.tenant_id
    memory_id = String.to_integer(id)

    socket =
      socket
      |> assign(:publish_confirm_id, nil)
      |> assign(:publish_confirm_synthesis, nil)
      |> update(:publish_pending, &MapSet.put(&1, memory_id))

    Task.start(fn ->
      case Librarian.Delegation.publish_memory(memory_id, tid) do
        {:ok, hash_id} ->
          Phoenix.PubSub.broadcast(
            Librarian.PubSub,
            "delegation:#{tid}",
            {:publish_progress, memory_id, :done, 100}
          )

          Phoenix.LiveView.send_update(__MODULE__,
            id: "dashboard",
            flash: %{info: "Published to public graph (#{String.slice(hash_id, 0, 12)})"}
          )

        {:error, reason} ->
          Phoenix.PubSub.broadcast(
            Librarian.PubSub,
            "delegation:#{tid}",
            {:publish_progress, memory_id, :error, 0}
          )

          Phoenix.LiveView.send_update(__MODULE__,
            id: "dashboard",
            flash: %{error: "Publish failed: #{inspect(reason)}"}
          )
      end
    end)

    {:noreply, socket}
  end

  def handle_event("manual_ingest", %{"text" => text, "bucket" => bucket}, socket)
      when byte_size(text) > 0 do
    tid = socket.assigns.tenant_id

    case Librarian.IngestRouter.process(
           %{
             "source" => "web_ui",
             "raw_text" => text,
             "hint_tags" => [],
             "metadata" => %{}
           },
           tid
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:ingest_text, "")
         |> assign(:ingest_bucket, bucket)
         |> put_flash(:info, "Ingested to #{bucket}")}

      {:ok, _, chunk_count} ->
        {:noreply,
         socket
         |> assign(:ingest_text, "")
         |> assign(:ingest_bucket, bucket)
         |> put_flash(:info, "Ingested (auto-chunked into #{chunk_count} pieces) to #{bucket}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Ingest failed: #{inspect(reason)}")}
    end
  end

  def handle_event("manual_ingest", _params, socket) do
    {:noreply, put_flash(socket, :error, "Text required")}
  end

  def handle_event("toggle_memory", %{"id" => id}, socket) do
    id = String.to_integer(id)

    new_set =
      if MapSet.member?(socket.assigns.expanded_memories, id),
        do: MapSet.delete(socket.assigns.expanded_memories, id),
        else: MapSet.put(socket.assigns.expanded_memories, id)

    {:noreply, assign(socket, :expanded_memories, new_set)}
  end

  def handle_event("open_ancestry", %{"id" => id}, socket) do
    memory_id = String.to_integer(id)
    tid = socket.assigns.tenant_id
    tree = Librarian.ColdStore.get_memory_ancestry(to_string(memory_id), tid)
    {:noreply, assign(socket, ancestry_memory_id: memory_id, ancestry_tree: tree)}
  end

  def handle_event("close_ancestry", _params, socket) do
    {:noreply, assign(socket, ancestry_memory_id: nil, ancestry_tree: [])}
  end

  def handle_event("flush_bucket", %{"bucket" => bucket}, socket) do
    case Librarian.Flusher.flush_bucket(bucket, force_local: socket.assigns.force_local) do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:flushed, bucket})
        {:noreply, put_flash(socket, :info, "Flushed #{bucket}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Flush failed: #{inspect(reason)}")}
    end
  end

  def handle_event("flood_demo", _params, socket) do
    if socket.assigns.demo_running do
      {:noreply, socket}
    else
      tid = socket.assigns.tenant_id

      Task.start(fn ->
        1..100
        |> Task.async_stream(
          fn i ->
            text = Enum.random(@demo_texts)

            Librarian.ingest(
              %{
                "source" => "flood",
                "raw_text" => text,
                "hint_tags" => [],
                "metadata" => %{"flood_index" => i}
              },
              tid
            )
          end,
          max_concurrency: 8,
          timeout: 60_000
        )
        |> Enum.each(fn _ -> :ok end)

        Phoenix.LiveView.send_update(__MODULE__, id: "dashboard", demo_running: false)
      end)

      {:noreply,
       socket
       |> assign(:demo_running, true)
       |> assign(:demo_total, 100)}
    end
  end

  def handle_event("swarm_demo", _params, socket) do
    if socket.assigns.demo_running do
      {:noreply, socket}
    else
      tid = socket.assigns.tenant_id
      total = 50

      Task.start(fn ->
        1..total
        |> Task.async_stream(
          fn i ->
            text = Enum.random(@demo_texts)

            Librarian.ingest(
              %{
                "source" => "swarm_agent_#{i}",
                "raw_text" => text,
                "hint_tags" => [],
                "metadata" => %{"swarm_index" => i}
              },
              tid
            )
          end,
          max_concurrency: 50,
          timeout: 120_000,
          ordered: false
        )
        |> Enum.to_list()

        Phoenix.LiveView.send_update(__MODULE__, id: "dashboard", demo_running: false)
      end)

      {:noreply,
       socket
       |> assign(:demo_running, true)
       |> assign(:demo_total, total)}
    end
  end

  # Catch-all fallback for other events to prevent GenServer crashes (e.g. __noop)
  @impl true
  def handle_event(event, params, socket) do
    Logger.debug("Unhandled event #{inspect(event)} with params #{inspect(params)}")
    {:noreply, socket}
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp assign_memories(socket, tenant_id) do
    socket
    |> assign(:memories, all_memories(tenant_id))
    |> assign(:superseded_count, WarmStore.superseded_count_for_user(tenant_id))
  end

  defp all_memories(tenant_id) do
    WarmStore.all_for_user(tenant_id) |> Enum.reject(& &1.superseded_by)
  end

  defp hot_counts(tenant_id) do
    prefix = tenant_id <> ":"

    HotStore.buckets()
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(fn b -> {b, HotStore.count(b)} end)
    |> Enum.into(%{})
  end

  defp compute_token_savings(tenant_id) do
    memories = WarmStore.all_for_user(tenant_id) |> Enum.reject(& &1.superseded_by)

    if memories == [] do
      %{savings_pct: 0, raw_tokens: 0, curated_tokens: 0}
    else
      raw_tokens =
        memories
        |> Enum.map(fn m ->
          (String.length(m.summary || "") + String.length(Enum.join(m.facts || [], " ")))
          |> div(4)
        end)
        |> Enum.sum()

      curated_tokens =
        memories
        |> Enum.map(fn m ->
          (String.length(m.summary || "") + String.length(Enum.join(m.facts || [], " ")) +
             String.length(Enum.join(m.tags || [], " ")))
          |> div(4)
        end)
        |> Enum.sum()

      savings_pct =
        if raw_tokens > 0 do
          trunc((1 - curated_tokens / max(raw_tokens, 1)) * 100)
        else
          0
        end

      %{savings_pct: savings_pct, raw_tokens: raw_tokens, curated_tokens: curated_tokens}
    end
  end

  # ── Publish confirm modal ─────────────────────────────────────────────
  # This is the deliberate UI gate: the user sees the actual synthesis text
  # (exactly what will be written to Postgres as the public node summary)
  # before anything is committed. The privacy warning is explicit: scrubbing
  # reduces but does not guarantee zero leaked detail.

  attr(:memory_id, :integer, required: true)
  attr(:synthesis, :string, required: true)

  def publish_confirm_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/70 flex items-center justify-center z-50 p-4"
         phx-key="Escape" phx-window-keydown="cancel_publish">
      <div class="bg-gray-900 border border-emerald-600 rounded-xl shadow-2xl max-w-lg w-full p-6 space-y-4">
        <h2 class="text-sm font-bold text-emerald-400 uppercase tracking-wider">
          🌐 Confirm Publish to Public Graph
        </h2>

        <p class="text-xs text-gray-400">
          The following synthesis text will be written to the immutable public graph as
          a permanent node. <strong class="text-amber-300">Review carefully</strong> — once
          published this cannot be unpublished.
        </p>

        <div class="bg-gray-800 border border-gray-700 rounded p-3 max-h-48 overflow-y-auto">
          <p class="text-xs text-gray-200 leading-relaxed"><%= @synthesis %></p>
        </div>

        <div class="bg-amber-950/60 border border-amber-700 rounded p-3">
          <p class="text-[11px] text-amber-300 leading-relaxed">
            ⚠️ <strong>Privacy notice:</strong> LeakGuard scrubs common secret patterns
            (API keys, tokens, DB URLs) from this text before it was used by the Council.
            Scrubbing <em>reduces</em> the risk of accidental leakage but is not a guarantee
            against all personal or sensitive detail. You are responsible for the content
            you publish to the public graph.
          </p>
        </div>

        <div class="flex gap-3">
          <button phx-click="cancel_publish"
            class="flex-1 text-xs bg-gray-700 hover:bg-gray-600 text-gray-300 px-3 py-2 rounded font-bold transition">
            Cancel
          </button>
          <button phx-click="confirm_publish" phx-value-id={@memory_id}
            class="flex-1 text-xs bg-emerald-700 hover:bg-emerald-600 text-white px-3 py-2 rounded font-bold transition">
            ✅ Confirm Publish
          </button>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100 font-mono p-4">
      <.header token_savings={@token_savings} flush_concurrency={@flush_concurrency} demo_running={@demo_running} demo_total={@demo_total} />
      <.tenant_banner tenant_id={@tenant_id} tier={@tier} force_local={@force_local} />
      <.tier_bar hot_counts={@hot_counts} memories={@memories} tenant_id={@tenant_id} superseded_count={@superseded_count} />

      <div class="flex gap-2 mb-4 items-center">
        <button phx-click="force_consolidation"
          class="text-xs bg-fuchsia-700 hover:bg-fuchsia-600 text-white px-3 py-1.5 rounded font-bold transition">
          ⚡ Force Consolidation Sweep
        </button>

        <%= if @tier == :judge do %>
          <%!-- Judges can switch between Cloud Qwen API and Local 1.7B --%>
          <button phx-click="toggle_force_local"
            class={"text-xs px-3 py-1.5 rounded font-bold transition border " <>
              if(@force_local,
                do: "bg-amber-600 hover:bg-amber-500 text-white border-amber-400",
                else: "bg-violet-700 hover:bg-violet-600 text-white border-violet-500")}>
            <%= if @force_local, do: "🖥️ Local 1.7B Active", else: "☁️ Cloud Qwen API Active" %>
          </button>
        <% else %>
          <%!-- Free/anon users always use the local model — no toggle visible --%>
          <span class="text-xs text-gray-600 px-2 py-1.5 rounded border border-gray-800 select-none">
            🖥️ Local Model
          </span>
        <% end %>
      </div>

      <div class="grid grid-cols-3 gap-4 mb-4" style="height: calc(50vh - 160px);">
        <.ingest_feed tenant_id={@tenant_id} ingest_text={@ingest_text} ingest_bucket={@ingest_bucket} feed_empty={@feed_empty} streams={@streams} />
        <.warm_cards tenant_id={@tenant_id} memories={@memories} expanded_memories={@expanded_memories} council_pending={@council_pending} publish_pending={@publish_pending} delegation_progress={@delegation_progress} />
        <.insights_panel insights={@insights} />
      </div>

      <div class="grid grid-cols-2 gap-4" style="height: calc(50vh - 160px);">
        <.structured_recall_terminal tenant_id={@tenant_id} structured_response={@structured_response} />
        <.live_component module={LibrarianWeb.Dashboard.Components.PublicGraph} id="public_graph" />
      </div>

      <%= if @ancestry_memory_id do %>
        <.ancestry_modal memory_id={@ancestry_memory_id} tenant_id={@tenant_id} ancestry={@ancestry_tree} />
      <% end %>

      <%= if @publish_confirm_id do %>
        <.publish_confirm_modal memory_id={@publish_confirm_id} synthesis={@publish_confirm_synthesis} />
      <% end %>
    </div>
    """
  end
end

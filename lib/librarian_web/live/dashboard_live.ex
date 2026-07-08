defmodule LibrarianWeb.DashboardLive do
  use LibrarianWeb, :live_view

  alias Librarian.{WarmStore, HotStore, Flusher}

  @bucket_colors %{
    "project" => "bg-blue-500",
    "research" => "bg-purple-500",
    "finance" => "bg-green-500",
    "ideas" => "bg-yellow-500",
    "thoughts" => "bg-pink-500",
    "inbox" => "bg-gray-500"
  }

  @valid_users ["manager"] ++ Enum.map(1..10, &"dev#{&1}")

  # ── Persona data for the Swarm Demo ─────────────────────────────────
  # Each user has role-appropriate texts so the curator assigns different
  # buckets, producing diverse WARM memories that demonstrate multi-tenant
  # isolation.

  @personas %{
    "dev1" => %{
      role: "Backend Engineer",
      texts: [
        "deployed the new Phoenix LiveView endpoint to production after load testing",
        "switched the primary database from Postgres to SQLite for the edge nodes",
        "fixed the N+1 query in the user dashboard that was causing 5s page loads",
        "refactored the GenServer pool to use a DynamicSupervisor for better fault isolation",
        "added ETS caching for the session lookup, cut latency from 50ms to 0.2ms",
        "the BEAM processes 1M concurrent WebSocket connections on a single 8GB node",
        "upgraded to OTP 27 for the new partition detector and improved process monitoring",
        "implemented a CircuitBreaker for the payment gateway API calls",
        "migrated the monolith to a supervised process tree with proper restart strategies",
        "the database migration took 47 seconds for 2M rows — acceptable for the deploy window",
        "added telemetry events to all critical GenServer calls for observability",
        "optimized the ETS table to use :ordered_set for range queries on timestamps",
        "replaced the REST API with a Phoenix Channel for real-time dashboard updates",
        "set up the Broadway pipeline to ingest 10k events/second from the message queue",
        "the release deployment to staging uses hot code reloading for zero-downtime updates"
      ]
    },
    "dev2" => %{
      role: "Frontend Engineer",
      texts: [
        "shipped the new React component library with 30 accessible components",
        "the TypeScript strict mode migration caught 47 type errors in the router",
        "optimized the bundle size from 2.4MB to 480KB with code splitting and tree shaking",
        "implemented the virtual list component that renders 10k rows at 60fps",
        "the CSS Grid layout refactor reduced the stylesheet by 60% and fixed layout shifts",
        "added Storybook stories for all 30 components with interaction tests",
        "the WebSocket reconnection logic now uses exponential backoff with jitter",
        "migrated the state management from Redux to Zustand for simpler APIs",
        "the lighthouse score improved from 45 to 92 after the performance audit fixes",
        "implemented the dark mode theme with CSS custom properties and system preference detection",
        "the form validation library handles 15 field types with async server-side checks",
        "added the drag-and-drop kanban board with optimistic UI updates",
        "the animation system uses requestAnimationFrame for smooth 120fps transitions",
        "implemented the infinite scroll with intersection observer for the feed page",
        "the accessibility audit resolved all 23 WCAG 2.1 AA violations"
      ]
    },
    "dev3" => %{
      role: "ML Engineer",
      texts: [
        "the BGE-M3 embedding model achieves 0.92 recall on the retrieval benchmark",
        "fine-tuned the 1.5B Qwen model on domain-specific code documentation",
        "the cosine similarity search over 50k embeddings completes in 12ms with hnswlib",
        "implemented the RAG pipeline with hybrid search: BM25 keyword + dense vector retrieval",
        "the nightly clustering pass discovered 47 related memory groups across 3 buckets",
        "the embedding dimension reduction from 1024 to 256 improved search speed by 4x",
        "the small 0.6B model can extract structured facts from chat logs with 87% accuracy",
        "implemented reciprocal rank fusion for combining keyword, vector, and importance signals",
        "the model quantization from fp16 to int8 reduced memory usage by 50% with 2% accuracy loss",
        "the training data augmentation pipeline generates 10k synthetic examples per hour",
        "the on-device inference runs 15 tokens/second on the Raspberry Pi 5",
        "the embedding cache hit rate is 78% for repeated queries within the same session",
        "the HNSW index rebuilds in 3 seconds for 100k vectors on the production server",
        "implemented the cross-encoder re-ranker that improved top-5 accuracy from 0.84 to 0.93",
        "the distillation pipeline shrank the teacher model from 7B to 1.5B with 95% knowledge retention"
      ]
    },
    "dev4" => %{
      role: "DevOps Engineer",
      texts: [
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
        "the SSL certificate renewal is automated via cert-manager with Let's Encrypt"
      ]
    },
    "dev5" => %{
      role: "Mobile Engineer",
      texts: [
        "the React Native app now supports dark mode and dynamic type across all screens",
        "the SwiftUI migration is 60% complete with 12 screens converted from UIKit",
        "the app launch time improved from 3.2s to 0.8s with lazy module loading",
        "implemented the offline-first architecture with SQLite sync and conflict resolution",
        "the push notification system handles 5 different event types with rich media attachments",
        "the Kotlin Multiplatform module shares 70% of business logic between iOS and Android",
        "the app size was reduced from 120MB to 45MB with asset optimization and code stripping",
        "the crash rate dropped from 0.8% to 0.05% after the memory leak fix in the image cache",
        "the gesture handler supports swipe-to-delete, pinch-to-zoom, and long-press context menus",
        "the biometric authentication uses Face ID and fingerprint with local keychain storage",
        "the app localization supports 12 languages with RTL layout for Arabic and Hebrew",
        "the incremental updates via CodePush deploy fixes without App Store review",
        "the network layer retries failed requests 3 times with exponential backoff",
        "the widget extension shows the 3 most recent notifications on the home screen",
        "the deep linking router handles 20 different URL schemes with parameter validation"
      ]
    },
    "dev6" => %{
      role: "Data Engineer",
      texts: [
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
        "the A/B testing pipeline computes statistical significance for 50 concurrent experiments"
      ]
    },
    "dev7" => %{
      role: "Security Engineer",
      texts: [
        "the OAuth 2.0 implementation passes all 47 security conformance tests",
        "the penetration test found 3 medium-severity issues in the API authentication layer",
        "the secrets rotation policy enforces 90-day rotation for all service accounts",
        "the SBOM generation is now part of the CI pipeline, tracking 340 dependencies",
        "the rate limiting middleware blocks 99.5% of brute force attempts on the login endpoint",
        "the CSP headers prevent XSS attacks across all 15 content types served by the app",
        "the API key hashing uses bcrypt with cost factor 12, taking 250ms per verification",
        "the audit log captures all admin actions with immutable storage in the cold tier",
        "the vulnerability scanner runs weekly and cross-references the CVE database",
        "the TLS 1.3 migration is complete across all internal service mesh endpoints",
        "the dependency scanning flagged 4 critical vulnerabilities in the npm packages",
        "the RBAC model defines 8 roles with granular permission sets for each resource",
        "the incident response runbook covers 12 scenarios with verified recovery procedures",
        "the WebAuthn implementation supports hardware security keys and platform authenticators",
        "the threat model review identified 5 attack vectors that were mitigated in the architecture"
      ]
    },
    "dev8" => %{
      role: "Product Manager",
      texts: [
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
        "the demo script walks through: flood ingest, multi-tenant isolation, nightly deep pass"
      ]
    },
    "dev9" => %{
      role: "Infrastructure Engineer",
      texts: [
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
        "the kernel parameter tuning for the database server: 100k max connections, 1M socket backlog",
        "the network policy engine blocks 200k malicious IPs with 0.1ms per-packet inspection",
        "the hardware monitoring stack tracks CPU, memory, disk, network, and temperature sensors"
      ]
    },
    "dev10" => %{
      role: "QA Engineer",
      texts: [
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
        "the test coverage report shows 91% line coverage across the core library modules"
      ]
    }
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Librarian.PubSub, "ingest")
      Phoenix.PubSub.subscribe(Librarian.PubSub, "flush")
      :timer.send_interval(2000, self(), :refresh_warm)
    end

    {:ok,
     socket
     |> stream(:feed, [])
     |> assign(:feed_empty, true)
     |> assign(:selected_user, "manager")
     |> assign(:memories, all_memories("manager"))
     |> assign(:hot_counts, hot_counts("manager"))
     |> assign(:query, "")
     |> assign(:recall_results, nil)
     |> assign(:insights, Librarian.morning_briefing(20))
     |> assign(:token_savings, compute_token_savings())
     |> assign(:bucket_colors, @bucket_colors)
     |> assign(:ingest_text, "")
     |> assign(:ingest_bucket, "inbox")
     |> assign(:expanded_memories, MapSet.new())
     |> assign(:flood_running, false)
     |> assign(:flood_count, 0)
     |> assign(:swarm_running, false)
     |> assign(:swarm_stats, %{})
     |> assign(:swarm_total, 0)
     |> assign(:swarm_agents, 0)
     |> assign(:swarm_started_at, nil)
     |> assign(:valid_users, @valid_users)
     |> assign(:personas, @personas)
     |> assign(:flush_concurrency, Application.get_env(:librarian, :parallel_flush_max_concurrency, 1))
     |> assign(:flood_total, 100)}
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

    selected = socket.assigns.selected_user
    # Update swarm stats if this is a swarm ingest
    swarm_stats = update_swarm_stats(socket.assigns.swarm_stats, user_id)
    swarm_total = socket.assigns.swarm_total + 1

    {:noreply,
     socket
     |> stream_insert(:feed, entry, at: 0, limit: 50)
     |> assign(:feed_empty, false)
     |> assign(:hot_counts, hot_counts(selected))
     |> assign(:swarm_stats, swarm_stats)
     |> assign(:swarm_total, swarm_total)}
  end

  def handle_info({:flushed, _bucket}, socket) do
    selected = socket.assigns.selected_user
    {:noreply,
     socket
     |> assign(:memories, all_memories(selected))
     |> assign(:hot_counts, hot_counts(selected))
     |> assign(:token_savings, compute_token_savings())}
  end

  def handle_info(:refresh_warm, socket) do
    selected = socket.assigns.selected_user
    {:noreply,
     socket
     |> assign(:memories, all_memories(selected))
     |> assign(:hot_counts, hot_counts(selected))
     |> assign(:insights, Librarian.morning_briefing(20))
     |> assign(:token_savings, compute_token_savings())}
  end

  # ── Event handlers ──────────────────────────────────────────────────

  @impl true
  def handle_event("select_user", %{"user" => user}, socket) when user in @valid_users do
    {:noreply,
     socket
     |> assign(:selected_user, user)
     |> assign(:memories, all_memories(user))
     |> assign(:hot_counts, hot_counts(user))
     |> assign(:recall_results, nil)}
  end

  @impl true
  def handle_event("recall", %{"query" => q}, socket) when byte_size(q) > 0 do
    user = socket.assigns.selected_user
    results = if user == "manager", do: Librarian.recall(q), else: Librarian.recall(q, user)
    {:noreply, assign(socket, :recall_results, %{query: q, warm: results.warm, related: results.related})}
  end

  def handle_event("recall", _params, socket) do
    {:noreply, assign(socket, :recall_results, nil)}
  end

  def handle_event("flush_all", _params, socket) do
    Flusher.flush_all(socket.assigns.flush_concurrency)
    selected = socket.assigns.selected_user

    {:noreply,
     socket
     |> assign(:memories, all_memories(selected))
     |> assign(:hot_counts, hot_counts(selected))
     |> assign(:token_savings, compute_token_savings())
     |> put_flash(:info, "Flushed all buckets")}
  end

  def handle_event("nightly_pass", _params, socket) do
    concurrency = socket.assigns.flush_concurrency

    Task.start(fn ->
      Flusher.flush_all(concurrency)
      Flusher.nightly_pass()
      Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:flushed, :all})
    end)

    {:noreply, put_flash(socket, :info, "Nightly pass started (async)")}
  end

  def handle_event("set_flush_concurrency", %{"value" => value}, socket) do
    concurrency = String.to_integer(value)
    {:noreply, assign(socket, :flush_concurrency, concurrency)}
  end

  def handle_event("manual_ingest", %{"text" => text, "bucket" => bucket}, socket) when byte_size(text) > 0 do
    user = socket.assigns.selected_user
    actual_user = if user == "manager", do: "local", else: user

    case Librarian.ingest(%{
      "source" => "web_ui",
      "raw_text" => text,
      "hint_tags" => [],
      "metadata" => %{}
    }, actual_user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:ingest_text, "")
         |> assign(:ingest_bucket, bucket)
         |> put_flash(:info, "Ingested to #{actual_user}:#{bucket}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Ingest failed: #{inspect(reason)}")}
    end
  end

  def handle_event("manual_ingest", _params, socket) do
    {:noreply, put_flash(socket, :error, "Text required")}
  end

  def handle_event("toggle_memory", %{"id" => id}, socket) do
    id = String.to_integer(id)
    new_set = if MapSet.member?(socket.assigns.expanded_memories, id),
      do: MapSet.delete(socket.assigns.expanded_memories, id),
      else: MapSet.put(socket.assigns.expanded_memories, id)

    {:noreply, assign(socket, :expanded_memories, new_set)}
  end

  def handle_event("flush_bucket", %{"bucket" => bucket}, socket) do
    case Librarian.Flusher.flush_bucket(bucket) do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(Librarian.PubSub, "flush", {:flushed, bucket})
        {:noreply, put_flash(socket, :info, "Flushed #{bucket}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Flush failed: #{inspect(reason)}")}
    end
  end

  def handle_event("flood_demo", _params, socket) do
    if socket.assigns.flood_running do
      {:noreply, socket}
    else
      Task.start(fn ->
        texts = [
          "we decided to deploy the new auth service to production this Friday",
          "switched the project database from postgres to sqlite for the edge nodes",
          "the deploy pipeline now runs mix release before pushing the docker image",
          "fixed the bucket routing bug where we matched inside weather",
          "repo renamed from memory-daemon to librarian, update all the CI configs",
          "Ebbinghaus forgetting curve: retention R = e^(-t/S) where S is memory strength",
          "research shows retrieval practice strengthens memory more than re-reading",
          "spaced repetition systems like Anki use expanding intervals between reviews",
          "the BEAM scheduler uses reduction counting not time slicing for preemption",
          "ETS tables in Elixir are O(1) lookup, stored outside the process heap",
          "Alibaba Cloud gave us $40 credit for the hackathon, use it for ECS or GPU",
          "Qwen API free tier: 1 million tokens, then pay-per-token after that",
          "finance: serverless functions on Alibaba Cloud are cheaper than always-on ECS",
          "budget the $40 coupon: GPU instance for demo day, ECS for the daemon",
          "finance note: embedding API calls are 10x cheaper than chat completions",
          "what if the morning briefing read back synaptic jumps from the night before",
          "idea: per-user memory namespacing so multiple people can share one daemon",
          "could use React Flow to visualize the memory graph, nodes are memories, edges are synaptic jumps",
          "idea: the Chrome extension could capture highlighted text, not just full page",
          "what if decay rate was user-configurable per bucket, not just global",
          "the weather today was perfect for a long walk",
          "picked up coffee beans from the market, the Ethiopian blend is excellent",
          "watched a documentary about octopus cognition, genuinely fascinating",
          "the new keyboard arrived, mechanical switches feel much better",
          "tried the new ramen place downtown, the tonkotsu broth was outstanding"
        ]

        1..100
        |> Task.async_stream(fn i ->
          text = Enum.random(texts)
          Librarian.ingest(%{
            "source" => "flood_ui",
            "raw_text" => text,
            "hint_tags" => [],
            "metadata" => %{"flood_index" => i}
          })
        end, max_concurrency: 4, timeout: 60_000)
        |> Enum.each(fn _ -> :ok end)

        Phoenix.LiveView.send_update(__MODULE__, id: "dashboard", flood_running: false)
      end)

      {:noreply, assign(socket, :flood_running, true)}
    end
  end

  @doc """
  Swarm Demo: simulate 10 devs × 5 agents each = 50 concurrent agents.

  Each agent ingests 5 role-appropriate texts into its user's isolated
  namespace. This demonstrates:
    - Multi-tenant isolation (devs cannot see each other's data)
    - BEAM concurrency (50 agents running simultaneously)
    - Small-model curation on each text
    - Manager cross-query capability
  """
  def handle_event("swarm_demo", _params, socket) do
    if socket.assigns.swarm_running do
      {:noreply, socket}
    else
      start_time = System.monotonic_time(:millisecond)

      Task.start(fn ->
        # Each user spawns 5 agents; each agent ingests 5 texts
        agent_defs =
          for user_id <- Enum.map(1..10, &"dev#{&1}"),
              agent_num <- 1..5,
              do: %{user_id: user_id, agent_id: "agent-#{user_id}-#{agent_num}"}

        total_agents = length(agent_defs)
        texts_per_agent = 5

        # Broadcast initial stats
        Phoenix.PubSub.broadcast(
          Librarian.PubSub,
          "ingest",
          {:swarm_status, total_agents, total_agents * texts_per_agent}
        )

        # Run all agents concurrently with high parallelism
        agent_defs
        |> Task.async_stream(
          fn %{user_id: user_id, agent_id: agent_id} ->
            persona = @personas[user_id]
            texts = if persona, do: persona.texts, else: []

            # Each agent ingests 5 texts from their persona
            Enum.each(1..texts_per_agent, fn _ ->
              text = Enum.random(texts)
              Librarian.ingest(%{
                "source" => "agent_#{agent_id}",
                "raw_text" => text,
                "hint_tags" => [],
                "metadata" => %{"agent_id" => agent_id, "user_id" => user_id}
              }, user_id)
            end)
          end,
          max_concurrency: 50,
          timeout: 120_000,
          ordered: false
        )
        |> Enum.to_list()

        elapsed = System.monotonic_time(:millisecond) - start_time

        # Broadcast completion
        Phoenix.PubSub.broadcast(
          Librarian.PubSub,
          "ingest",
          {:swarm_complete, total_agents, total_agents * texts_per_agent, elapsed}
        )

        Phoenix.LiveView.send_update(__MODULE__, id: "dashboard", swarm_running: false)
      end)

      {:noreply,
       socket
       |> assign(:swarm_running, true)
       |> assign(:swarm_stats, %{})
       |> assign(:swarm_total, 0)
       |> assign(:swarm_agents, 50)
       |> assign(:swarm_started_at, Time.utc_now() |> Time.truncate(:second))}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp all_memories("manager") do
    WarmStore.all() |> Enum.reject(& &1.superseded_by)
  end

  defp all_memories(user_id) when is_binary(user_id) do
    WarmStore.all_for_user(user_id) |> Enum.reject(& &1.superseded_by)
  end

  defp hot_counts("manager") do
    HotStore.buckets()
    |> Enum.map(fn b -> {b, HotStore.count(b)} end)
    |> Enum.into(%{})
  end

  defp hot_counts(user_id) when is_binary(user_id) do
    prefix = user_id <> ":"

    HotStore.buckets()
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(fn b -> {b, HotStore.count(b)} end)
    |> Enum.into(%{})
  end

  defp update_swarm_stats(stats, user_id) do
    Map.update(stats, user_id, 1, &(&1 + 1))
  end

  defp role_for(user_id), do: @personas[user_id][:role] || "Unknown"

  defp buckets_list, do: ["project", "research", "finance", "ideas", "thoughts", "inbox"]

  defp bucket_color(bucket, colors), do: Map.get(colors, bucket, "bg-gray-500")
  defp importance_pct(importance), do: "width: #{trunc((importance || 0) * 100)}%"

  defp compute_token_savings do
    memories = WarmStore.all() |> Enum.reject(& &1.superseded_by)

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

  defp insight_icon("supersession"), do: "🔄"
  defp insight_icon("deep_supersession"), do: "⚠️"
  defp insight_icon("deep_cross_connection"), do: "🔗"
  defp insight_icon(_), do: "💡"

  defp insight_summary(%{"kind" => "supersession"} = m) do
    "Superseded: \"#{m["old_summary"]}\" → \"#{m["new_summary"]}\""
  end

  defp insight_summary(%{"kind" => "deep_supersession"} = m) do
    "Qwen flagged contradiction: memory ##{m["old_id"]} superseded by ##{m["new_id"]}"
  end

  defp insight_summary(%{"kind" => "deep_cross_connection"} = m) do
    "Qwen connected ##{m["id_a"]} ↔ ##{m["id_b"]}: #{m["note"]}"
  end

  defp insight_summary(m) do
    inspect(m)
  end

  defp warm_count_for(user_id) do
    WarmStore.all_for_user(user_id) |> Enum.reject(& &1.superseded_by) |> length()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100 font-mono p-4">

      <%!-- Header --%>
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-2xl font-bold text-white">📚 Librarian</h1>
          <p class="text-gray-400 text-sm">local-first memory daemon · BEAM/OTP</p>
        </div>
        <div class="flex items-center gap-4">
          <%!-- Token savings badge --%>
          <div class="bg-gray-800 rounded px-3 py-1.5 text-xs">
            <span class="text-gray-400">Token savings: </span>
            <span class="text-green-400 font-bold"><%= @token_savings.savings_pct %>%</span>
            <span class="text-gray-600"> | </span>
            <span class="text-gray-400"><%= @token_savings.curated_tokens %> curated</span>
          </div>
          <button phx-click="flush_all"
            class="px-3 py-1.5 bg-blue-700 hover:bg-blue-600 rounded text-sm transition">
            Flush HOT → WARM
          </button>
          <button phx-click="nightly_pass"
            class="px-3 py-1.5 bg-purple-700 hover:bg-purple-600 rounded text-sm transition">
            Nightly Pass (Qwen)
          </button>
          <select phx-change="set_flush_concurrency" name="value"
            class="bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-sm text-white focus:outline-none focus:border-blue-500">
            <%= for c <- [1, 2, 3, 4] do %>
              <option value={c} selected={@flush_concurrency == c}><%= c %>x</option>
            <% end %>
          </select>
          <button phx-click="flood_demo"
            disabled={@flood_running}
            class={if @flood_running, do: "px-3 py-1.5 rounded text-sm transition bg-gray-700 cursor-not-allowed", else: "px-3 py-1.5 rounded text-sm transition bg-green-700 hover:bg-green-600"}>
            <%= if @flood_running, do: "Flooding...", else: "Flood Demo" %>
          </button>
          <button phx-click="swarm_demo"
            disabled={@swarm_running}
            class={if @swarm_running, do: "px-3 py-1.5 rounded text-sm transition bg-gray-700 cursor-not-allowed", else: "px-3 py-1.5 rounded text-sm transition bg-amber-600 hover:bg-amber-500"}>
            <%= if @swarm_running, do: "Swarming...", else: "🐝 Swarm Demo" %>
          </button>
        </div>
      </div>

      <%!-- User selector --%>
      <div class="flex items-center gap-3 mb-4">
        <span class="text-xs text-gray-500 uppercase tracking-wider">View as:</span>
        <select phx-change="select_user" name="user"
          class="bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm text-white focus:outline-none focus:border-blue-500">
          <option value="manager" selected={@selected_user == "manager"}>
            👑 Manager (all users)
          </option>
          <option disabled class="text-gray-600">───</option>
          <%= for u <- Enum.map(1..10, &"dev#{&1}") do %>
            <option value={u} selected={@selected_user == u}>
              <%= case u do %>
                <% "dev1" -> %>🖥️  dev1 — Backend
                <% "dev2" -> %>🎨 dev2 — Frontend
                <% "dev3" -> %>🧠 dev3 — ML
                <% "dev4" -> %>⚙️  dev4 — DevOps
                <% "dev5" -> %>📱 dev5 — Mobile
                <% "dev6" -> %>📊 dev6 — Data
                <% "dev7" -> %>🔒 dev7 — Security
                <% "dev8" -> %>📋 dev8 — Product
                <% "dev9" -> %>🌐 dev9 — Infra
                <% "dev10" -> %>🔬 dev10 — QA
              <% end %>
            </option>
          <% end %>
        </select>

        <%= if @selected_user != "manager" do %>
          <span class="text-xs text-gray-500">
            role: <span class="text-gray-300"><%= role_for(@selected_user) %></span>
          </span>
        <% end %>

        <%= if @swarm_running do %>
          <span class="text-xs text-amber-400 animate-pulse">
            Spawning 50 agents, 250 texts...
          </span>
        <% end %>
      </div>

      <%!-- Swarm stats bar (visible when swarm has data) --%>
      <%= if @swarm_stats != %{} do %>
        <div class="bg-gray-900 rounded-lg p-3 mb-4 border border-amber-800">
          <div class="flex items-center justify-between mb-2">
            <span class="text-xs font-bold text-amber-400 uppercase tracking-wider">
              🐝 Swarm Demo Stats
            </span>
            <span class="text-xs text-gray-500">
              <%= @swarm_agents %> agents · <%= @swarm_total %> texts ingested
            </span>
          </div>
          <div class="grid grid-cols-10 gap-1 text-[10px]">
            <%= for user_id <- Enum.map(1..10, &"dev#{&1}") do %>
              <div class="bg-gray-800 rounded p-1.5 text-center">
                <div class="text-gray-400 truncate"><%= user_id %></div>
                <div class="text-white font-bold"><%= Map.get(@swarm_stats, user_id, 0) %></div>
                <div class="text-gray-600 truncate"><%= warm_count_for(user_id) %> WARM</div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <%!-- Tier bar --%>
      <div class="flex gap-3 mb-6 flex-wrap">
        <%= for {bucket, count} <- Enum.sort(@hot_counts) do %>
          <div class="flex items-center gap-2 bg-gray-800 rounded px-3 py-1.5">
            <span class={"w-2 h-2 rounded-full #{bucket_color(bucket, @bucket_colors)}"} />
            <span class="text-xs text-gray-300"><%= bucket %></span>
            <span class="text-xs font-bold text-white"><%= count %> HOT</span>
            <button phx-click="flush_bucket" phx-value-bucket={bucket}
              class="ml-1 text-xs text-blue-400 hover:text-blue-300">[flush]</button>
          </div>
        <% end %>
        <div class="flex items-center gap-2 bg-gray-800 rounded px-3 py-1.5">
          <span class="text-xs text-gray-300">WARM</span>
          <span class="text-xs font-bold text-white"><%= length(@memories) %></span>
        </div>
        <div class="flex items-center gap-2 bg-gray-800 rounded px-3 py-1.5">
          <span class="text-xs text-gray-300">🔢 embedded</span>
          <span class="text-xs font-bold text-white"><%= Enum.count(@memories, &(not is_nil(&1.embedding))) %></span>
        </div>
        <%= if @selected_user != "manager" do %>
          <div class="flex items-center gap-2 bg-amber-900/50 rounded px-3 py-1.5 border border-amber-700">
            <span class="text-xs text-amber-300">🔒 isolated: <%= @selected_user %> only</span>
          </div>
        <% end %>
      </div>

      <div class="grid grid-cols-4 gap-4 h-[calc(100vh-280px)]">

        <%!-- Left: live ingest feed --%>
        <div class="bg-gray-900 rounded-lg p-4 overflow-hidden flex flex-col">
          <h2 class="text-sm font-bold text-gray-300 mb-3 uppercase tracking-wider">
            ⚡ Live Ingest Feed
            <span :if={@selected_user != "manager"} class="text-amber-400 text-[10px]">[<%= @selected_user %>]</span>
          </h2>

          <%!-- Manual ingest form --%>
          <form phx-submit="manual_ingest" class="mb-4 space-y-2">
            <textarea name="text" value={@ingest_text} rows="2" placeholder="Paste text to ingest..."
              class="w-full bg-gray-800 border border-gray-700 rounded px-3 py-2 text-sm text-white placeholder-gray-500 focus:outline-none focus:border-blue-500"></textarea>
            <div class="flex gap-2">
              <select name="bucket" class="bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-sm text-white focus:outline-none focus:border-blue-500">
                <%= for b <- buckets_list() do %>
                  <option value={b} selected={@ingest_bucket == b}><%= b %></option>
                <% end %>
              </select>
              <button type="submit"
                class="flex-1 px-3 py-1.5 bg-blue-700 hover:bg-blue-600 rounded text-sm transition">
                Ingest
              </button>
            </div>
          </form>

          <div class="flex-1 overflow-y-auto space-y-2" id="feed" phx-update="stream" style="max-height: 400px;">
            <div :if={@feed_empty} id="feed-empty" class="text-gray-600 text-xs">
              Waiting for ingest events... run Flood Demo or Swarm Demo.
            </div>
            <%= for {dom_id, entry} <- @streams.feed do %>
              <div id={dom_id} class="border-l-2 border-gray-700 pl-3 py-1">
                <div class="flex items-center gap-2 mb-0.5">
                  <span class={"w-2 h-2 rounded-full flex-shrink-0 #{bucket_color(entry.bucket, @bucket_colors)}"} />
                  <span class="text-xs font-bold text-gray-200"><%= entry.bucket %></span>
                  <span class="text-xs text-gray-500"><%= entry.source %></span>
                  <span :if={entry.user_id} class="text-xs text-amber-600"><%= entry.user_id %></span>
                  <span class="text-xs text-gray-600 ml-auto"><%= entry.at %></span>
                </div>
                <p class="text-xs text-gray-400 truncate"><%= entry.preview %></p>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Second: WARM memory cards --%>
        <div class="bg-gray-900 rounded-lg p-4 overflow-hidden flex flex-col">
          <h2 class="text-sm font-bold text-gray-300 mb-3 uppercase tracking-wider">
            🧠 WARM Memory Tier
            <span :if={@selected_user != "manager"} class="text-amber-400 text-[10px]">[<%= @selected_user %>]</span>
          </h2>
          <div class="flex-1 overflow-y-auto space-y-3">
            <%= for memory <- Enum.sort_by(@memories, &(-&1.importance)) do %>
              <div class={"bg-gray-800 rounded p-3 border #{if MapSet.member?(@expanded_memories, memory.id), do: "border-blue-500", else: "border-gray-700"} cursor-pointer"}
                   phx-click="toggle_memory" phx-value-id={memory.id}>
                <div class="flex items-center gap-2 mb-2">
                  <span class={"w-2 h-2 rounded-full flex-shrink-0 #{bucket_color(memory.bucket, @bucket_colors)}"} />
                  <span class="text-xs font-bold text-gray-200"><%= memory.bucket %></span>
                  <span class="text-xs text-gray-500 ml-auto">#<%= memory.id %></span>
                </div>
                <p class="text-xs text-gray-300 mb-2"><%= memory.summary %></p>

                <div class="h-1 bg-gray-700 rounded mb-2">
                  <div class="h-1 bg-blue-500 rounded" style={importance_pct(memory.importance)} />
                </div>

                <%= if MapSet.member?(@expanded_memories, memory.id) do %>
                  <div class="mt-2 pt-2 border-t border-gray-700 space-y-2">
                    <div>
                      <span class="text-xs text-gray-400">Facts:</span>
                      <%= if memory.facts && memory.facts != [] do %>
                        <ul class="text-xs text-gray-300 mt-1 space-y-1 list-disc list-inside">
                          <%= for fact <- memory.facts do %>
                            <li><%= fact %></li>
                          <% end %>
                        </ul>
                      <% else %>
                        <p class="text-xs text-gray-600 mt-1">No facts extracted</p>
                      <% end %>
                    </div>
                    <div class="flex gap-3 text-xs">
                      <span class="text-gray-400">Created: <%= DateTime.to_iso8601(memory.created_at) %></span>
                      <%= if memory.embedding do %>
                        <span class="text-blue-400">🔢 Embedding: <%= length(memory.embedding) %>-dim</span>
                      <% end %>
                    </div>
                    <div class="text-xs">
                      <span class="text-gray-400">Tags: </span>
                      <%= for tag <- (memory.tags || []) do %>
                        <span class="text-xs bg-gray-700 text-gray-300 rounded px-1.5 py-0.5"><%= tag %></span>
                      <% end %>
                    </div>
                    <%= if memory.superseded_by do %>
                      <div class="text-xs text-yellow-400">⚠️ Superseded by #<%= memory.superseded_by %></div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
            <p :if={@memories == []} class="text-gray-600 text-xs">
              No memories yet<%= if @selected_user != "manager", do: " for #{@selected_user}" %>.
            </p>
          </div>
        </div>

        <%!-- Third: recall console --%>
        <div class="bg-gray-900 rounded-lg p-4 overflow-hidden flex flex-col">
          <h2 class="text-sm font-bold text-gray-300 mb-3 uppercase tracking-wider">
            🔍 Recall Console
            <span :if={@selected_user != "manager"} class="text-amber-400 text-[10px]">[<%= @selected_user %>]</span>
          </h2>
          <form phx-submit="recall" class="mb-4">
            <div class="flex gap-2">
              <input type="text" name="query" value={@query}
                placeholder={if @selected_user == "manager", do: "search across all users...", else: "search #{@selected_user} memories..."}
                class="flex-1 bg-gray-800 border border-gray-700 rounded px-3 py-1.5 text-sm text-white placeholder-gray-500 focus:outline-none focus:border-blue-500"
                autofocus />
              <button type="submit"
                class="px-3 py-1.5 bg-blue-700 hover:bg-blue-600 rounded text-sm transition">
                Recall
              </button>
            </div>
          </form>

          <div class="flex-1 overflow-y-auto">
            <%= if @recall_results do %>
              <p class="text-xs text-gray-500 mb-3">
                "<%= @recall_results.query %>" →
                <%= length(@recall_results.warm) %> direct,
                <%= length(@recall_results.related) %> synaptic jumps
              </p>
              <%= for memory <- @recall_results.warm do %>
                <div class="bg-gray-800 rounded p-2 mb-2 border-l-2 border-blue-500">
                  <div class="flex items-center gap-2 mb-1">
                    <span class={"w-1.5 h-1.5 rounded-full #{bucket_color(memory.bucket, @bucket_colors)}"} />
                    <span class="text-xs font-bold text-gray-200"><%= memory.bucket %></span>
                    <span class="text-xs text-gray-500">score=<%= Float.round(memory.importance, 3) %></span>
                  </div>
                  <p class="text-xs text-gray-300 line-clamp-3"><%= memory.summary %></p>
                </div>
              <% end %>
              <%= if @recall_results.related != [] do %>
                <p class="text-xs text-yellow-500 mt-3 mb-2">⚡ Synaptic jumps (cross-bucket)</p>
                <%= for memory <- @recall_results.related do %>
                  <div class="bg-gray-800 rounded p-2 mb-2 border-l-2 border-yellow-500">
                    <div class="flex items-center gap-2 mb-1">
                      <span class={"w-1.5 h-1.5 rounded-full #{bucket_color(memory.bucket, @bucket_colors)}"} />
                      <span class="text-xs font-bold text-gray-200"><%= memory.bucket %></span>
                    </div>
                    <p class="text-xs text-gray-300 line-clamp-2"><%= memory.summary %></p>
                  </div>
                <% end %>
              <% end %>
              <p :if={@recall_results.warm == []} class="text-gray-600 text-xs">
                No memories match "<%= @recall_results.query %>"<%= if @selected_user != "manager", do: " for #{@selected_user}" %>
              </p>
            <% else %>
              <p class="text-gray-600 text-xs">Enter a query to search WARM memories.</p>
              <p class="text-gray-700 text-xs mt-2">
                <%= if @selected_user == "manager" do %>
                  Querying across all 10 users. Switch to a dev to see isolated results.
                <% else %>
                  3-way RRF: keyword + BGE-M3 vector + importance. Isolated to <%= @selected_user %>.
                <% end %>
              </p>
            <% end %>
          </div>
        </div>

        <%!-- Fourth: Connections / Insights panel --%>
        <div class="bg-gray-900 rounded-lg p-4 overflow-hidden flex flex-col">
          <h2 class="text-sm font-bold text-gray-300 mb-3 uppercase tracking-wider">
            🔗 Connections & Insights
          </h2>
          <div class="flex-1 overflow-y-auto space-y-3">
            <%= if @insights == [] do %>
              <p class="text-gray-600 text-xs">
                No insights yet. Run the Nightly Pass (Qwen) to discover cross-bucket connections, contradictions, and patterns.
              </p>
              <div class="bg-gray-800 rounded p-3 border border-gray-700 mt-2">
                <p class="text-xs text-gray-400">
                  The Qwen deep pass analyzes all WARM memories together to find:
                </p>
                <ul class="text-xs text-gray-500 mt-2 space-y-1 list-disc list-inside">
                  <li>Cross-bucket connections (synaptic jumps)</li>
                  <li>Contradictions between decisions</li>
                  <li>Repeated patterns across sessions</li>
                  <li>Re-ranking of importance scores</li>
                </ul>
              </div>
            <% else %>
              <%= for insight <- @insights do %>
                <div class="bg-gray-800 rounded p-3 border border-gray-700">
                  <div class="flex items-center gap-2 mb-1">
                    <span class="text-xs"><%= insight_icon(insight["kind"]) %></span>
                    <span class="text-xs text-gray-400"><%= insight["kind"] %></span>
                    <span class="text-xs text-gray-600 ml-auto"><%= insight["logged_at"] %></span>
                  </div>
                  <p class="text-xs text-gray-300"><%= insight_summary(insight) %></p>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>

      </div>
    </div>
    """
  end
end

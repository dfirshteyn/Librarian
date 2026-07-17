defmodule Librarian.Demo do
  @moduledoc """
  Helper module for seeding sandboxes with demo memories.
  """

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

  def demo_texts, do: @demo_texts

  @doc """
  Seeds a user's sandbox with a specified number of diverse memories
  from the demo set. Ingests them to the HOT tier.
  """
  def seed_sandbox(user_id, count \\ 10) when is_binary(user_id) and is_integer(count) do
    # Select count diverse or random items
    items = Enum.take_random(@demo_texts, count)

    Enum.each(items, fn text ->
      Librarian.ingest(
        %{
          "source" => "seed_demo",
          "raw_text" => text,
          "hint_tags" => [],
          "metadata" => %{"demo" => "seed"}
        },
        user_id
      )
    end)
  end
end

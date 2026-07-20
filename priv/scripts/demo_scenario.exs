Application.ensure_all_started(:librarian)

defmodule DemoScenario do
  @moduledoc """
  Multi-agent simulation script that spawns 50 concurrent virtual callers
  making rapid REST API POST requests to the Librarian ingest endpoint.

  Agents are distributed across 5 domain-themed profiles, each sending
  20-30 heavily redundant payloads to force the automated consolidation
  threshold to fire naturally.
  """

  @base_url "http://localhost:4000"
  @agents_per_profile %{
    "sales" => 10,
    "support" => 15,
    "billing" => 10,
    "onboarding" => 10,
    "technical" => 5
  }

  @payloads %{
    "sales" => [
      "customer asking about enterprise pricing tier options and volume discounts",
      "pricing tier confusion between pro and enterprise plans",
      "need clarification on the enterprise pricing structure for the sales call",
      "contract hesitation around the annual commitment for enterprise tier",
      "SLA terms discussion for the enterprise agreement renewal",
      "volume discount request for 50+ seats on the enterprise plan",
      "pricing comparison between pro and enterprise tiers for the client",
      "contract terms negotiation for the enterprise SLA agreement",
      "enterprise pricing inquiry with questions about tier features",
      "SLA uptime guarantees needed for the enterprise contract",
      "discount structure for multi-year enterprise commitment",
      "pricing tier features comparison for the sales presentation",
      "contract renewal terms for existing enterprise customer",
      "volume pricing for enterprise deployment across multiple teams",
      "SLA response time requirements for the enterprise support tier",
      "enterprise pricing approval needed for the sales opportunity",
      "contract terms review for the enterprise agreement",
      "pricing escalation for enterprise tier with custom features",
      "SLA compliance reporting for enterprise customers",
      "volume discount structure for enterprise seat licenses",
      "enterprise contract renewal with upgraded SLA terms",
      "pricing tier migration from pro to enterprise for growing team",
      "SLA penalty clauses in the enterprise agreement",
      "volume pricing negotiation for enterprise-wide rollout",
      "enterprise pricing tier with custom integration support"
    ],
    "support" => [
      "authentication token expired and user cannot login to the dashboard",
      "token expiration issue causing 401 errors on API calls",
      "JWT token refresh flow broken after the latest deployment",
      "Next.js routing bug in the dashboard navigation menu",
      "Next.js dynamic route not rendering correctly for user profiles",
      "Next.js page routing broken after upgrading to version 14",
      "ECS pipeline timeout during the staging deployment process",
      "ECS container deployment stuck in pending state for hours",
      "ECS task definition update causing rolling restart failures",
      "token refresh endpoint returning 500 internal server error",
      "Next.js static generation failing for the analytics pages",
      "ECS service auto-scaling not triggering under load",
      "authentication token validation failing intermittently",
      "Next.js middleware routing to wrong page for authenticated users",
      "ECS pipeline failing at the migration step consistently",
      "token expiry not being handled gracefully in the mobile app",
      "Next.js image optimization breaking on production build",
      "ECS container health check failing after configuration change",
      "token refresh race condition causing duplicate login prompts",
      "Next.js server-side rendering timeout for complex pages",
      "ECS deployment rollback procedure not documented",
      "authentication token not being refreshed on page navigation",
      "Next.js client-side navigation broken after route change",
      "ECS pipeline environment variable injection not working",
      "token validation middleware causing performance degradation"
    ],
    "billing" => [
      "stripe webhook failure not processing subscription payments",
      "stripe webhook signature verification failing intermittently",
      "stripe webhook event handling missing for invoice payments",
      "invoice seat dispute from customer about overcharging",
      "invoice billing dispute for extra seats added mid-cycle",
      "seat-based billing dispute from enterprise customer",
      "refund request for duplicate charge on subscription",
      "stripe webhook timeout causing delayed payment processing",
      "invoice generation error for monthly billing cycle",
      "seat count mismatch in billing invoice for the account",
      "refund processing failure in the stripe integration",
      "stripe webhook retry mechanism not idempotent",
      "invoice payment failed notification not reaching customer",
      "seat-based pricing calculation error in billing system",
      "refund request for service outage period credit",
      "stripe webhook endpoint not receiving events after deploy",
      "invoice PDF generation failing for large seat counts",
      "billing cycle alignment issue for mid-month upgrades",
      "refund processing delay exceeding SLA commitment",
      "stripe webhook secret rotation causing auth failures",
      "invoice line item description missing for seat charges",
      "seat addition not reflected in next billing invoice",
      "refund amount calculation error for partial month",
      "stripe webhook event ordering causing state inconsistency",
      "invoice tax calculation incorrect for international customers"
    ],
    "onboarding" => [
      "environment variable configuration confusion during setup",
      "DATABASE_URL environment variable not being picked up by the app",
      "environment variable naming convention confusion in the docs",
      "API key location unclear in the onboarding documentation",
      "where to find the API key in the dashboard settings",
      "API key generation process not documented clearly",
      "environment variable setup for local development confusing",
      "API key permissions not explained in the getting started guide",
      "environment variable validation failing on application start",
      "API key rotation process not documented for security",
      "environment variable template missing required variables",
      "API key scope configuration unclear for different endpoints",
      "environment variable override mechanism not working as expected",
      "API key rate limit information missing from documentation",
      "environment variable encryption requirements not specified",
      "API key integration example code has syntax errors",
      "environment variable loading order causing configuration conflicts",
      "API key revocation process not documented for compromised keys",
      "environment variable documentation outdated for latest version",
      "API key header name confusion between v1 and v2 API",
      "environment variable setup script failing on Windows",
      "API key environment variable name mismatch in examples",
      "environment variable secret management best practices unclear",
      "API key usage tracking not visible in the dashboard",
      "environment variable configuration for Docker deployment unclear"
    ],
    "technical" => [
      "GenServer concurrency load crash under high request volume",
      "GenServer process crashing due to mailbox overflow under load",
      "GenServer concurrent access causing state corruption in production",
      "WAL file truncation error during hot store recovery process",
      "WAL file corruption after unexpected process termination",
      "WAL truncation race condition during concurrent bucket flushes",
      "GenServer load testing reveals bottleneck in handle_call handler",
      "WAL file growth unbounded under continuous ingestion load",
      "GenServer timeout errors during long-running curator operations",
      "WAL file recovery failing after disk space exhaustion",
      "GenServer process leak under sustained memory pressure",
      "WAL truncation not releasing disk space after successful flush",
      "GenServer concurrent call handling causing request queue buildup",
      "WAL file format version mismatch after application upgrade",
      "GenServer state serialization error during hot code upgrade",
      "WAL file integrity check failing after system crash",
      "GenServer load shedding not working under peak traffic",
      "WAL file cleanup not triggered after bucket deletion",
      "GenServer process monitoring not detecting silent crashes",
      "WAL file replay taking too long after application restart",
      "GenServer concurrent write contention under high throughput",
      "WAL file truncation leaving orphaned segments on disk",
      "GenServer memory usage growing unbounded over time",
      "WAL file recovery producing duplicate entries after crash",
      "GenServer process registration collision under rapid restart"
    ]
  }

  def run do
    IO.puts("=" <> String.duplicate("=", 70))
    IO.puts("  Librarian Multi-Agent Simulation Demo")
    IO.puts("=" <> String.duplicate("=", 70))
    IO.puts("")

    total_agents = Enum.sum(Map.values(@agents_per_profile))
    total_payloads_per_agent = 25
    total_payloads = total_agents * total_payloads_per_agent

    IO.puts("  Agents: #{total_agents}")
    IO.puts("  Payloads per agent: #{total_payloads_per_agent}")
    IO.puts("  Total payloads: #{total_payloads}")
    IO.puts("")

    # Check if server is reachable
    case http_get("#{@base_url}/api/status") do
      {:ok, _} ->
        IO.puts("  Server reachable at #{@base_url}")
        IO.puts("")

      {:error, reason} ->
        IO.puts("  WARNING: Server not reachable at #{@base_url}: #{inspect(reason)}")
        IO.puts("  Starting simulation anyway (errors expected if server is down)")
        IO.puts("")
    end

    start_time = System.monotonic_time(:millisecond)

    # Build agent tasks
    agent_tasks =
      @agents_per_profile
      |> Enum.flat_map(fn {profile, count} ->
        Enum.map(1..count, fn agent_num ->
          user_id = "#{profile}_agent_#{agent_num}"
          payloads = @payloads[profile] |> Enum.shuffle() |> Enum.take(total_payloads_per_agent)
          {user_id, profile, payloads}
        end)
      end)

    # Run agents concurrently
    results =
      agent_tasks
      |> Task.async_stream(
        fn {user_id, profile, payloads} ->
          send_payloads(user_id, profile, payloads)
        end,
        max_concurrency: 50,
        timeout: :infinity
      )
      |> Enum.to_list()

    end_time = System.monotonic_time(:millisecond)
    elapsed_ms = end_time - start_time
    throughput = if elapsed_ms > 0, do: round(total_payloads / (elapsed_ms / 1000)), else: 0

    # Collect stats
    {successes, failures} =
      Enum.reduce(results, {0, 0}, fn
        {:ok, {s, f}}, {acc_s, acc_f} -> {acc_s + s, acc_f + f}
        _, {acc_s, acc_f} -> {acc_s, acc_f + 1}
      end)

    IO.puts("")
    IO.puts("=" <> String.duplicate("=", 70))
    IO.puts("  Simulation Complete")
    IO.puts("=" <> String.duplicate("=", 70))
    IO.puts("")
    IO.puts("  Total payloads sent: #{total_payloads}")
    IO.puts("  Successful: #{successes}")
    IO.puts("  Failed: #{failures}")
    IO.puts("  Total time: #{elapsed_ms}ms")
    IO.puts("  Throughput: #{throughput} payloads/second")
    IO.puts("")

    # Print per-profile stats
    IO.puts("  Per-Profile Summary:")
    IO.puts("")

    @agents_per_profile
    |> Enum.each(fn {profile, count} ->
      profile_results =
        results
        |> Enum.zip(agent_tasks)
        |> Enum.filter(fn {_result, {uid, p, _}} -> p == profile end)
        |> Enum.map(fn {result, _} -> result end)

      profile_successes =
        Enum.reduce(profile_results, 0, fn
          {:ok, {s, _}}, acc -> acc + s
          _, acc -> acc
        end)

      IO.puts("    #{String.pad_trailing(profile, 15)} #{count} agents, #{profile_successes} payloads")
    end)

    IO.puts("")
    IO.puts("  Now check the WARM store for consolidation activity:")
    IO.puts("    iex> Librarian.WarmStore.all() |> Enum.count()")
    IO.puts("    iex> Librarian.WarmStore.all() |> Enum.map(& &1.summary)")
    IO.puts("")
  end

   defp send_payloads(user_id, profile, payloads) do
     # Map profiles to their target buckets
     profile_to_bucket = %{
       "sales" => "finance",
       "support" => "project",
       "billing" => "finance",
       "onboarding" => "project",
       "technical" => "research"
     }

     target_bucket = profile_to_bucket[profile] || "inbox"

     results =
       Enum.map(payloads, fn text ->
         # Random delay between 100-500ms
         delay = :rand.uniform(400) + 100
         Process.sleep(delay)

         body = %{
           source: "demo_#{profile}",
           raw_text: text,
           hint_tags: [profile],
           target_bucket: target_bucket,
           metadata: %{agent: user_id, profile: profile}
         }

         http_post("#{@base_url}/api/ingest", body, user_id)
       end)

     successes = Enum.count(results, fn {:ok, _} -> true; _ -> false end)
     failures = Enum.count(results, fn {:error, _} -> true; _ -> false end)

     {successes, failures}
   end

  defp http_get(url) do
    case :httpc.request(:get, {url, []}, [], []) do
      {:ok, {{_version, 200, _}, _headers, _body}} -> {:ok, :reachable}
      {:ok, {{_version, code, _}, _headers, _body}} -> {:error, "HTTP #{code}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp http_post(url, body, user_id) do
    encoded = Jason.encode!(body)
    headers = [
      {'content-type', 'application/json'},
      {'x-user-id', String.to_charlist(user_id)}
    ]

    case :httpc.request(:post, {url, headers, 'application/json', String.to_charlist(encoded)}, [], []) do
      {:ok, {{_version, code, _}, _headers, _body}} when code in [200, 201, 202] ->
        {:ok, :ingested}

      {:ok, {{_version, code, _}, _headers, body}} ->
        {:error, "HTTP #{code}: #{body}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

DemoScenario.run()

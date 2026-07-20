defmodule LibrarianWeb.WelcomeLive do
  use LibrarianWeb, :live_view

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:tenant_id, Map.get(session, "sandbox_id", "unknown"))
     |> assign(:tier, Map.get(session, "tier", :anon))
     |> assign(:sandbox_token, Map.get(session, "sandbox_token", ""))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen overflow-hidden bg-slate-950 text-slate-100">
      <section class="relative isolate min-h-screen px-6 py-8 sm:px-10 lg:px-16">
        <div class="absolute inset-0 -z-10 opacity-70" style="background: radial-gradient(circle at 18% 18%, rgba(34,211,238,.22), transparent 30%), radial-gradient(circle at 78% 8%, rgba(168,85,247,.20), transparent 28%), radial-gradient(circle at 65% 82%, rgba(16,185,129,.16), transparent 24%), #020617;"></div>
        <div class="absolute inset-0 -z-10 opacity-[0.18]" style="background-image: linear-gradient(rgba(148,163,184,.35) 1px, transparent 1px), linear-gradient(90deg, rgba(148,163,184,.35) 1px, transparent 1px); background-size: 42px 42px;"></div>

        <nav class="mx-auto flex max-w-7xl items-center justify-between">
          <div class="flex items-center gap-3">
            <div class="grid h-11 w-11 place-items-center rounded-2xl border border-cyan-300/30 bg-cyan-300/10 text-2xl shadow-lg shadow-cyan-950/50">📚</div>
            <div>
              <p class="text-lg font-black tracking-tight text-white">Librarian</p>
              <p class="text-[10px] font-bold uppercase tracking-[0.3em] text-cyan-200/80">BEAM memory layer</p>
            </div>
          </div>
          <a href="/dashboard" class="rounded-full border border-slate-700 bg-slate-900/70 px-4 py-2 text-xs font-bold uppercase tracking-widest text-slate-200 transition hover:border-cyan-300 hover:text-cyan-100">Open dashboard</a>
        </nav>

        <div class="mx-auto grid max-w-7xl gap-10 py-16 lg:grid-cols-[1.1fr_.9fr] lg:items-center lg:py-24">
          <div class="space-y-8">
            <div class="inline-flex items-center gap-2 rounded-full border border-emerald-300/25 bg-emerald-300/10 px-4 py-2 text-[11px] font-black uppercase tracking-[0.28em] text-emerald-200">
              <span class="h-2 w-2 animate-pulse rounded-full bg-emerald-300"></span>
              Local-first memory runtime for the agentic era
            </div>

            <div class="space-y-5">
              <h1 class="max-w-5xl text-5xl font-black tracking-[-0.05em] text-white sm:text-6xl lg:text-7xl">
                Give every agent a memory that survives the tab.
              </h1>
              <p class="max-w-3xl text-lg leading-8 text-slate-300">
                Librarian is a pure Elixir/OTP memory layer that collapses cache, queue, orchestration, and local vector recall into isolated BEAM processes designed for hackathon-speed demos and production-grade agent sessions.
              </p>
            </div>

            <div class="flex flex-col gap-3 sm:flex-row">
              <a href="/dashboard" class="rounded-2xl bg-cyan-300 px-6 py-4 text-center text-sm font-black uppercase tracking-widest text-slate-950 shadow-xl shadow-cyan-950/50 transition hover:bg-white">Start a sandbox</a>
              <a href="#restore" class="rounded-2xl border border-violet-300/30 bg-violet-300/10 px-6 py-4 text-center text-sm font-black uppercase tracking-widest text-violet-100 transition hover:border-violet-200 hover:bg-violet-300/20">Restore with token</a>
            </div>

            <div class="grid gap-3 sm:grid-cols-3">
              <.tier_card label="HOT" value="1–5µs" body="In-process ETS buffers per tenant." />
              <.tier_card label="WARM" value="RRF" body="Curated facts ranked by text, vectors, and importance." />
              <.tier_card label="COLD" value="SQLite" body="Durable local archive with lineage." />
            </div>
          </div>

          <aside id="restore" class="rounded-[2rem] border border-white/10 bg-slate-900/75 p-6 shadow-2xl shadow-indigo-950/50 backdrop-blur">
            <p class="text-[11px] font-black uppercase tracking-[0.3em] text-cyan-200">Return to a session</p>
            <h2 class="mt-3 text-2xl font-black text-white">Paste a user or judge token</h2>
            <p class="mt-2 text-sm leading-6 text-slate-400">
              Tokens are signed by Phoenix and carry the sandbox id plus tier, so judges can recover premium demo access without accounts and users can resume their own local memory.
            </p>

            <form action="/dashboard" method="get" class="mt-6 space-y-3">
              <input name="tid" type="password" autocomplete="off" placeholder="Paste signed sandbox token" class="w-full rounded-2xl border border-slate-700 bg-slate-950 px-4 py-4 text-sm text-slate-100 outline-none transition placeholder:text-slate-600 focus:border-cyan-300 focus:ring-2 focus:ring-cyan-300/20" />
              <button type="submit" class="w-full rounded-2xl bg-emerald-300 px-4 py-4 text-sm font-black uppercase tracking-widest text-slate-950 transition hover:bg-white">Restore session</button>
            </form>

            <div class="mt-6 rounded-2xl border border-slate-800 bg-black/30 p-4">
              <div class="flex items-center justify-between gap-2">
                <span class="text-[10px] font-bold uppercase tracking-widest text-slate-500">Current token</span>
                <span class="rounded-full bg-indigo-400/15 px-2.5 py-1 text-[10px] font-black uppercase text-indigo-100"><%= @tier %></span>
              </div>
              <p class="mt-3 break-all rounded-xl bg-slate-950/80 p-3 text-[10px] leading-5 text-slate-400"><%= @sandbox_token %></p>
              <p class="mt-3 text-xs text-slate-500">Save this token to return to sandbox <span class="text-slate-300"><%= @tenant_id %></span>.</p>
            </div>
          </aside>
        </div>
      </section>
    </main>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:body, :string, required: true)

  defp tier_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-white/10 bg-white/[0.04] p-4 shadow-lg shadow-slate-950/30">
      <p class="text-[10px] font-black uppercase tracking-[0.25em] text-slate-500"><%= @label %></p>
      <p class="mt-2 text-2xl font-black text-cyan-100"><%= @value %></p>
      <p class="mt-1 text-xs leading-5 text-slate-400"><%= @body %></p>
    </div>
    """
  end
end

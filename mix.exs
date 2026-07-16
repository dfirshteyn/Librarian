defmodule Librarian.MixProject do
  use Mix.Project

  def project do
    [
      app: :librarian,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl, :public_key],
      mod: {Librarian.Application, []}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind librarian", "esbuild librarian"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:plug, "~> 1.16"},
      # Phoenix + LiveView
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:bandit, "~> 1.0"},
      # SQLite for COLD store
      {:exqlite, "~> 0.23"},
      {:ecto_sqlite3, "~> 0.17"},
      # Postgres for public graph network
      {:postgrex, "~> 0.19"},
      {:pgvector, "~> 0.3"},
      # ML
      {:nx, "~> 0.12.0"},
      {:exla, "~> 0.12.0"},
      {:bumblebee, "~> 0.7.0"},
      # Assets
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:glazer, "~> 0.5"},
      # PDF extraction via pdftotext (poppler-utils) — already installed on system
      # Future: swap to pdf_oxide (Rust NIF) when Rust toolchain is available
      # Image validation + dimension extraction
      {:ex_image_info, "~> 1.0.0"},
      # Markdown → HTML rendering for dashboard display
      {:mdex, "~> 0.3"}
    ]
  end
end

import Config

# Load .env and .env.local files if present (dev convenience — never commit secrets)
# .env.local takes precedence over .env
Enum.each([".env.local", ".env"], fn filename ->
  dotenv_path = Path.join(File.cwd!(), filename)

  if File.exists?(dotenv_path) do
    dotenv_path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.each(fn line ->
      case String.split(line, "=", parts: 2) do
        [k, v] -> System.put_env(String.trim(k), String.trim(v))
        _ -> :ok
      end
    end)
  end
end)

if api_key = System.get_env("DASHSCOPE_API_KEY") do
  config :librarian, dashscope_api_key: api_key
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL env var is required in prod"

  config :librarian, Librarian.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

   # Postgres public graph — optional for contributing to shared knowledge base
   # Leave unset for isolated deployment without public graph integration
   if public_database_url = System.get_env("DATABASE_PUBLIC_URL") do
     config :librarian, Librarian.PublicRepo,
       url: public_database_url,
       pool_size: String.to_integer(System.get_env("PUBLIC_POOL_SIZE") || "5")
   end

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE env var is required in prod"

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :librarian, LibrarianWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base
end

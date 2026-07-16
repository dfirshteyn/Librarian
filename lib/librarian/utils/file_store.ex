defmodule Librarian.Utils.FileStore do
  @moduledoc """
  Pluggable file storage for uploaded images, PDFs, and other media.

  Supports two backends:
    - `:local` — saves to `priv/uploads/{user_id}/{uuid}.{ext}` (default, no external deps)
    - `:r2` — saves to Cloudflare R2 via S3-compatible API (requires AWS creds)

  Configure via:
      config :librarian, :file_store, backend: :local

  The local backend is the default and works out of the box for the hackathon.
  """

  @doc """
  Store an uploaded file. Returns `{:ok, stored_path}` where stored_path is
  the canonical path/URL for later retrieval.

  ## Options
    - `:user_id` — namespace for the file (default: "local")
    - `:filename` — original filename for extension detection (required)
    - `:data` — raw binary data of the file (required)
  """
  def store(opts) do
    user_id = Keyword.get(opts, :user_id, "local")
    filename = Keyword.fetch!(opts, :filename)
    data = Keyword.fetch!(opts, :data)

    backend = get_backend()

    case backend do
      :local -> store_local(user_id, filename, data)
      :r2 -> store_r2(user_id, filename, data)
    end
  end

  @doc """
  Retrieve a stored file by its stored_path. Returns `{:ok, binary_data}`.
  """
  def retrieve(stored_path) do
    backend = get_backend()

    case backend do
      :local -> retrieve_local(stored_path)
      :r2 -> retrieve_r2(stored_path)
    end
  end

  @doc """
  Delete a stored file by its stored_path. Returns `:ok` or `{:error, reason}`.
  """
  def delete(stored_path) do
    backend = get_backend()

    case backend do
      :local -> delete_local(stored_path)
      :r2 -> delete_r2(stored_path)
    end
  end

  @doc """
  Returns the base upload directory for the local backend.
  """
  def base_upload_dir do
    Path.join(Application.app_dir(:librarian, "priv"), "uploads")
  end

  # --- Backend selection ---

  defp get_backend do
    Application.get_env(:librarian, :file_store, [])
    |> Keyword.get(:backend, :local)
  end

  # --- Local backend ---

  defp store_local(user_id, filename, data) do
    ext = filename |> Path.extname() |> String.downcase()
    uuid = generate_uuid()
    relative_path = Path.join([user_id, "#{uuid}#{ext}"])
    absolute_path = Path.join(base_upload_dir(), relative_path)

    # Ensure directory exists
    dir = Path.dirname(absolute_path)
    File.mkdir_p!(dir)

    case File.write(absolute_path, data) do
      :ok -> {:ok, relative_path}
      {:error, reason} -> {:error, {:file_write_error, reason}}
    end
  end

  defp retrieve_local(stored_path) do
    absolute_path = Path.join(base_upload_dir(), stored_path)

    case File.read(absolute_path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:file_read_error, reason}}
    end
  end

  defp delete_local(stored_path) do
    absolute_path = Path.join(base_upload_dir(), stored_path)

    case File.rm(absolute_path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file_delete_error, reason}}
    end
  end

  # --- R2 / S3-compatible backend ---
  #
  # R2 backend requires the :aws_s3 hex package and env vars:
  #   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
  #   CF_R2_ENDPOINT (e.g. https://<accountid>.r2.cloudflarestorage.com)
  #   CF_R2_BUCKET
  #
  # For now, falls back to local storage. Add ExAws to mix.exs and
  # implement store_r2/3, retrieve_r2/1, delete_r2/1 when ready.

  defp store_r2(user_id, filename, data) do
    store_local(user_id, filename, data)
  end

  defp retrieve_r2(stored_path) do
    retrieve_local(stored_path)
  end

  defp delete_r2(stored_path) do
    delete_local(stored_path)
  end

  # --- Helpers ---

  defp generate_uuid do
    Ecto.UUID.generate()
  end

  defp mime_type(ext) do
    case ext do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".svg" -> "image/svg+xml"
      ".pdf" -> "application/pdf"
      ".md" -> "text/markdown"
      ".txt" -> "text/plain"
      _ -> "application/octet-stream"
    end
  end
end

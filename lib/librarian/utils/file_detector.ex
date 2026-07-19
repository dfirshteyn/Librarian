defmodule Librarian.Utils.FileDetector do
  @moduledoc """
  Detects file types and content modes for incoming data.

  Supports:
  - Extension-based MIME type detection (using mime library)
  - Binary detection (base64 strings, magic bytes)
  - Content type routing decisions
  """

  @doc """
  Detects the type of content in the payload.

  Returns:
    - `:text` - Regular text content
    - `:image` - Image file (binary or recognized extension)
    - `:pdf` - PDF document
    - `:binary` - Unknown binary data
  """
  def detect_content_type(%{file_type: file_type}) when not is_nil(file_type) do
    detect_from_mime(file_type)
  end

  def detect_content_type(%{raw_text: text, file_type: nil}) do
    # Only check base64 if we don't have a file_type hint
    # This prevents false positives on code/text without extension
    cond do
      is_base64?(text) -> :binary
      true -> :text
    end
  end

  def detect_content_type(_), do: :text

  @doc """
  Gets MIME type from file extension or content-type string.
  """
  def mime_type(nil), do: nil

  def mime_type(filename) when is_binary(filename) do
    case Path.extname(filename) do
      "." <> ext -> mime_type_from_ext(ext)
      _ -> nil
    end
  end

  @doc """
  Checks if a string appears to be base64-encoded binary data.
  More conservative check to avoid false positives on code/text.
  """
  def is_base64?(text) when is_binary(text) do
    text = String.trim(text)

    # Base64 pattern: alphanumeric plus /+ and = for padding
    cond do
      String.length(text) < 100 -> false
      not String.match?(text, ~r/^[A-Za-z0-9+\/=]+$/) -> false
      rem(String.length(text), 4) != 0 -> false
      # Check for high density of base64 chars vs whitespace
      base64_density?(text) -> true
      true -> false
    end
  end

  def is_base64?(_), do: false

  @doc """
  Detects file type from extension.
  Returns a tuple of `{type_category, mime_type}`.
  """
  def file_category(filename) when is_binary(filename) do
    ext = filename |> Path.extname() |> String.downcase() |> String.trim_leading(".")

    case ext do
      ext when ext in ~w(png jpg jpeg gif svg webp) -> {:image, mime_type_from_ext(ext)}
      ext when ext in ~w(pdf) -> {:pdf, mime_type_from_ext(ext)}
      ext when ext in ~w(md markdown) -> {:markdown, "text/markdown"}
      ext when ext in ~w(ex exs) -> {:elixir, "text/x-elixir"}
      ext when ext in ~w(js ts py rs go rb java c cpp h hs) -> {:code, mime_type_from_ext(ext)}
      ext when ext in ~w(txt json yaml yml toml) -> {:text, mime_type_from_ext(ext)}
      _ -> {:unknown, mime_type_from_ext(ext)}
    end
  end

  def file_category(_), do: {:unknown, nil}

  # Private functions

  defp detect_from_mime(mime) when is_binary(mime) do
    cond do
      String.starts_with?(mime, "image/") -> :image
      mime == "application/pdf" -> :pdf
      String.starts_with?(mime, "text/") or
        mime in [
          "application/json",
          "application/javascript",
          "application/typescript",
          "application/yaml",
          "application/toml"
        ] -> :text
      true -> :binary
    end
  end

  defp detect_from_mime(_), do: :text

  defp mime_type_from_ext(ext) do
    # Use our own MIME type map
    Map.get(default_mime_map(), ext, "application/octet-stream")
  end

  # Our own MIME type fallback map
  defp default_mime_map do
    %{
      "md" => "text/markdown",
      "markdown" => "text/markdown",
      "pdf" => "application/pdf",
      "png" => "image/png",
      "jpg" => "image/jpeg",
      "jpeg" => "image/jpeg",
      "gif" => "image/gif",
      "svg" => "image/svg+xml",
      "webp" => "image/webp",
      "ex" => "text/x-elixir",
      "exs" => "text/x-elixir",
      "js" => "application/javascript",
      "ts" => "application/typescript",
      "py" => "text/x-python",
      "rs" => "text/x-rust",
      "go" => "text/x-go",
      "rb" => "text/x-ruby",
      "java" => "text/x-java",
      "c" => "text/x-c",
      "cpp" => "text/x-c++",
      "h" => "text/x-c",
      "hs" => "text/x-haskell",
      "txt" => "text/plain",
      "json" => "application/json",
      "yaml" => "application/yaml",
      "yml" => "application/yaml",
      "toml" => "application/toml"
    }
  end

  # Check if most characters are base64 chars (not typical text)
  defp base64_density?(text) do
    total = String.length(text)
    non_ws = String.replace(text, ~r/[\s\n\r]/, "")
    density = String.length(non_ws) / total

    # High density of non-whitespace chars suggests base64
    density > 0.8
  end
end

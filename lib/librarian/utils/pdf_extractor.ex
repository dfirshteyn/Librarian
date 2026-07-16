defmodule Librarian.Utils.PdfExtractor do
  @moduledoc """
  Extracts text from PDF documents using pdftotext (poppler-utils).

  pdftotext is an external binary that's already installed on the system
  at `/usr/bin/pdftotext`. It's reliable, well-tested, and handles
  corrupted/adversarial PDFs gracefully.

  Future: swap to pdf_oxide (in-process Rust NIF) when the Rust toolchain
  is available on the build machine. pdf_oxide would give us structured
  markdown output with heading detection via `page.markdown(detect_headings: true)`,
  and eliminates the external binary dependency.
  """

  @doc """
  Extract text from a PDF binary.

  Returns `{:ok, text_string}` where text_string is the full document content,
  or `{:error, reason}` on failure.
  """
  def extract(pdf_binary) when is_binary(pdf_binary) do
    # Write to a temp file since pdftotext works with file paths
    tmp_dir = tmp_path()
    File.mkdir_p!(tmp_dir)

    input_path = Path.join(tmp_dir, "input_#{unique_id()}.pdf")
    output_path = Path.join(tmp_dir, "output_#{unique_id()}.txt")

    try do
      File.write!(input_path, pdf_binary)

      case System.cmd("pdftotext", [input_path, output_path], stderr_to_stdout: true) do
        {_output, 0} ->
          case File.read(output_path) do
            {:ok, text} when text != "" ->
              {:ok, text}

            {:ok, _} ->
              {:ok, "[PDF appears to be empty or image-only]"}

            {:error, reason} ->
              {:error, {:output_read_error, reason}}
          end

        {error_output, _exit_code} ->
          {:error, {:pdftotext_error, String.trim(error_output)}}
      end
    after
      File.rm(input_path)
      File.rm(output_path)
    end
  end

  def extract(_), do: {:error, :invalid_input}

  @doc """
  Extract text from a PDF file path.
  """
  def extract_from_path(file_path) when is_binary(file_path) do
    case File.read(file_path) do
      {:ok, data} -> extract(data)
      {:error, reason} -> {:error, {:file_read_error, reason}}
    end
  end

  # --- Private ---

  defp tmp_path do
    Path.join(System.tmp_dir!(), "librarian_pdf")
  end

  defp unique_id do
    System.unique_integer([:positive])
    |> Integer.to_string(16)
  end
end

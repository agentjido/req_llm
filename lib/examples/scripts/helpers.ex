defmodule ReqLLM.Scripts.Helpers do
  @moduledoc """
  Shared utilities for example scripts in `scripts/`.

  Provides common functionality for script execution including argument parsing,
  logging, timing, error handling, and multimodal content processing.
  """

  require Logger

  @doc """
  Ensures the application is started.

  Starts the `:req_llm` application and its dependencies. Exits with error
  if startup fails.

  ## Examples

      iex> ensure_app!()
      :ok
  """
  @spec ensure_app!() :: :ok
  def ensure_app! do
    {:ok, _} = Application.ensure_all_started(:req_llm)
    :ok
  end

  @doc """
  Parses command-line arguments using NimbleOptions.

  ## Parameters

    * `argv` - List of command-line arguments
    * `schema` - NimbleOptions schema definition
    * `script_name` - Name of the script for error messages

  ## Examples

      schema = [
        model: [type: :string, default: "openai:gpt-4o"],
        prompt: [type: :string, required: true]
      ]
      parse_args(["--prompt", "Hello"], schema, "example.exs")
  """
  @spec parse_args([String.t()], keyword(), String.t()) :: keyword()
  def parse_args(argv, schema, script_name) do
    {opts, _} = OptionParser.parse!(argv, strict: nimble_to_strict(schema))

    case NimbleOptions.validate(opts, schema) do
      {:ok, validated} ->
        validated

      {:error, %NimbleOptions.ValidationError{message: msg}} ->
        IO.puts(:stderr, "Error: #{msg}\n")
        print_usage(schema, script_name)
        System.halt(1)
    end
  end

  @doc """
  Returns the log level based on verbosity flags.

  ## Parameters

    * `verbose` - Boolean or integer verbosity level

  ## Examples

      iex> log_level(true)
      :info

      iex> log_level(false)
      :warning
  """
  @spec log_level(boolean() | integer()) :: Logger.level()
  def log_level(verbose) when is_boolean(verbose) do
    if verbose, do: :info, else: :warning
  end

  def log_level(level) when is_integer(level) do
    case level do
      0 -> :warning
      1 -> :info
      _ -> :debug
    end
  end

  @doc """
  Returns the default text generation model.
  """
  @spec default_text_model() :: String.t()
  def default_text_model, do: "openai:gpt-4o"

  @doc """
  Returns the default embedding model.
  """
  @spec default_embedding_model() :: String.t()
  def default_embedding_model, do: "openai:text-embedding-3-small"

  @doc """
  Prints a banner for a script.

  ## Parameters

    * `script_name` - Name of the script
    * `description` - Brief description of what the script does
    * `opts` - Parsed options to display

  ## Examples

      banner!("example.exs", "Demonstrates basic text generation", model: "openai:gpt-4o")
  """
  @spec banner!(String.t(), String.t(), keyword()) :: :ok
  def banner!(script_name, description, opts) do
    IO.puts(
      "\n" <>
        IO.ANSI.bright() <> IO.ANSI.blue() <> "━" <> String.duplicate("━", 78) <> IO.ANSI.reset()
    )

    IO.puts(IO.ANSI.bright() <> "  #{script_name}" <> IO.ANSI.reset() <> " — #{description}")
    IO.puts(IO.ANSI.blue() <> "━" <> String.duplicate("━", 78) <> IO.ANSI.reset())

    opts
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.each(fn {k, v} ->
      IO.puts("  #{IO.ANSI.faint()}#{k}:#{IO.ANSI.reset()} #{inspect(v)}")
    end)

    IO.puts(IO.ANSI.blue() <> "━" <> String.duplicate("━", 78) <> IO.ANSI.reset() <> "\n")
  end

  @doc """
  Times the execution of a function and returns {result, duration_ms}.

  ## Examples

      {result, ms} = time(fn -> ReqLLM.generate_text!("openai:gpt-4o", "Hi") end)
  """
  @spec time((-> any())) :: {any(), non_neg_integer()}
  def time(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    duration = System.monotonic_time(:millisecond) - start
    {result, duration}
  end

  @doc """
  Creates a context from a prompt and optional system message.

  ## Examples

      context("Hello!", system: "You are helpful")
  """
  @spec context(String.t(), keyword()) :: ReqLLM.Context.t()
  def context(prompt, opts \\ []) do
    ctx = ReqLLM.Context.new()

    ctx =
      case Keyword.get(opts, :system) do
        nil -> ctx
        sys -> ReqLLM.Context.push_system(ctx, sys)
      end

    ReqLLM.Context.push_user(ctx, prompt)
  end

  @doc """
  Prints streamed text chunks to stdout.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec print_stream_text(String.t(), keyword()) :: :ok | {:error, any()}
  def print_stream_text(model, opts) do
    IO.write(IO.ANSI.green() <> "Assistant: " <> IO.ANSI.reset())

    context = Keyword.fetch!(opts, :context)
    stream_opts = Keyword.delete(opts, :context)

    case ReqLLM.stream_text(model, context, stream_opts) do
      {:ok, response} ->
        response.stream
        |> Enum.each(fn chunk ->
          case chunk do
            %ReqLLM.StreamChunk{type: :content, text: text} when is_binary(text) ->
              IO.write(text)

            %ReqLLM.StreamChunk{type: :meta, metadata: metadata} ->
              if metadata[:finish_reason] do
                IO.write("\n\n")
                if metadata[:usage], do: print_usage(metadata[:usage])
              end

            _ ->
              :ok
          end
        end)

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Prints a text generation response with timing information.
  """
  @spec print_text_response(ReqLLM.Response.t(), non_neg_integer(), keyword()) :: :ok
  def print_text_response(response, duration_ms, _opts) do
    text = ReqLLM.Response.text(response)
    IO.puts(IO.ANSI.green() <> "Assistant: " <> IO.ANSI.reset() <> text)
    IO.puts("")
    print_usage_and_timing(response.usage, duration_ms, [])
  end

  @doc """
  Prints an object generation response with timing information.
  """
  @spec print_object_response(map(), map() | nil, non_neg_integer()) :: :ok
  def print_object_response(object, usage, duration_ms) do
    IO.puts(IO.ANSI.green() <> "Generated Object:" <> IO.ANSI.reset())
    IO.puts(Jason.encode!(object, pretty: true))
    IO.puts("")
    print_usage_and_timing(usage, duration_ms, [])
  end

  @doc """
  Prints usage and timing information.
  """
  @spec print_usage_and_timing(map() | nil, non_neg_integer(), keyword()) :: :ok
  def print_usage_and_timing(usage, duration_ms, _opts) do
    IO.puts(IO.ANSI.faint() <> "⏱  #{duration_ms}ms" <> IO.ANSI.reset())

    if usage do
      usage
      |> usage_lines()
      |> Enum.each(&IO.puts/1)
    end

    :ok
  end

  @doc """
  Formats usage information into printable lines.
  """
  @spec usage_lines(map()) :: [String.t()]
  def usage_lines(usage) when is_map(usage) do
    input = usage[:input_tokens] || 0
    output = usage[:output_tokens] || 0
    total = usage[:total_tokens] || input + output

    lines = [
      "📊 Tokens: #{input} in / #{output} out / #{total} total"
    ]

    lines =
      if usage[:cache_read_tokens] && usage[:cache_read_tokens] > 0 do
        lines ++ ["💾 Cache read: #{usage[:cache_read_tokens]} tokens"]
      else
        lines
      end

    lines =
      if usage[:cache_creation_tokens] && usage[:cache_creation_tokens] > 0 do
        lines ++ ["💾 Cache created: #{usage[:cache_creation_tokens]} tokens"]
      else
        lines
      end

    if usage[:cost] do
      lines ++ ["💰 Cost: $#{Float.round(usage[:cost], 6)}"]
    else
      lines
    end
  end

  @doc """
  Handles errors by printing a formatted message and exiting.

  ## Parameters

    * `error` - The error to handle
    * `script_name` - Name of the script for error messages
    * `opts` - Options for error handling

  """
  @spec handle_error!(any(), String.t(), keyword()) :: no_return()
  def handle_error!(error, script_name, _opts) do
    IO.puts(:stderr, "\n" <> IO.ANSI.red() <> "❌ Error in #{script_name}" <> IO.ANSI.reset())

    message =
      case error do
        %{__exception__: true} = exc ->
          Exception.message(exc)

        other ->
          inspect(other)
      end

    IO.puts(:stderr, "   " <> message)

    if missing_api_key?(error) do
      IO.puts(:stderr, "\n" <> IO.ANSI.yellow() <> "💡 Hint:" <> IO.ANSI.reset())
      IO.puts(:stderr, "   Set your API key in the environment:")
      IO.puts(:stderr, "   export OPENAI_API_KEY=your-key-here")
      IO.puts(:stderr, "   Or see .env.example for all supported providers")
    end

    IO.puts("")
    System.halt(1)
  end

  @doc """
  Loads an image file and returns its base64-encoded content.

  ## Examples

      load_image_base64!("path/to/image.png")
  """
  @spec load_image_base64!(String.t()) :: String.t()
  def load_image_base64!(path) do
    path
    |> File.read!()
    |> Base.encode64()
  end

  @doc """
  Loads a PDF file and returns its base64-encoded content.

  ## Examples

      load_pdf_base64!("path/to/document.pdf")
  """
  @spec load_pdf_base64!(String.t()) :: String.t()
  def load_pdf_base64!(path) do
    path
    |> File.read!()
    |> Base.encode64()
  end

  @doc """
  Creates multimodal content parts for a message.

  Handles provider-specific formatting for images and PDFs.

  ## Parameters

    * `prompt` - The text prompt
    * `opts` - Options including :image_path, :pdf_path
    * `provider` - The provider atom (:openai, :anthropic, etc.)

  ## Examples

      multimodal_parts!("Describe this", [image_path: "cat.png"], :openai)
  """
  @spec multimodal_parts!(String.t(), keyword(), atom()) :: [map()]
  def multimodal_parts!(prompt, opts, provider) do
    parts = [%{type: "text", text: prompt}]

    parts =
      case Keyword.get(opts, :image_path) do
        nil ->
          parts

        path ->
          media_type = media_type_from_path(path)
          base64 = load_image_base64!(path)
          parts ++ [format_image_part(base64, media_type, provider)]
      end

    case Keyword.get(opts, :pdf_path) do
      nil ->
        parts

      path ->
        base64 = load_pdf_base64!(path)
        parts ++ [format_pdf_part(base64, provider)]
    end
  end

  defp nimble_to_strict(schema) do
    Enum.map(schema, fn {key, spec} ->
      type = Keyword.get(spec, :type, :string)
      {key, nimble_type_to_option_parser(type)}
    end)
  end

  defp nimble_type_to_option_parser(:string), do: :string
  defp nimble_type_to_option_parser(:boolean), do: :boolean
  defp nimble_type_to_option_parser(:integer), do: :integer
  defp nimble_type_to_option_parser(:float), do: :float
  defp nimble_type_to_option_parser(_), do: :string

  defp print_usage(schema, script_name) do
    IO.puts("Usage: elixir #{script_name} [options]\n")
    IO.puts("Options:")

    Enum.each(schema, fn {key, spec} ->
      required = if Keyword.get(spec, :required, false), do: " (required)", else: ""
      default = Keyword.get(spec, :default)
      default_str = if default, do: " [default: #{inspect(default)}]", else: ""
      doc = Keyword.get(spec, :doc, "")

      IO.puts("  --#{key}#{required}#{default_str}")
      if doc != "", do: IO.puts("      #{doc}")
    end)
  end

  defp print_usage(usage) when is_map(usage) do
    usage
    |> usage_lines()
    |> Enum.each(&IO.puts(IO.ANSI.faint() <> &1 <> IO.ANSI.reset()))
  end

  defp missing_api_key?(error) do
    message =
      case error do
        %{message: msg} when is_binary(msg) -> String.downcase(msg)
        _ -> ""
      end

    String.contains?(message, "api key") or
      String.contains?(message, "api_key") or
      String.contains?(message, "authentication") or
      String.contains?(message, "unauthorized")
  end

  defp media_type_from_path(path) do
    case Path.extname(path) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _ -> "image/jpeg"
    end
  end

  defp format_image_part(base64, media_type, :openai) do
    %{
      type: "image_url",
      image_url: %{
        url: "data:#{media_type};base64,#{base64}"
      }
    }
  end

  defp format_image_part(base64, media_type, :anthropic) do
    %{
      type: "image",
      source: %{
        type: "base64",
        media_type: media_type,
        data: base64
      }
    }
  end

  defp format_image_part(base64, media_type, _provider) do
    format_image_part(base64, media_type, :openai)
  end

  defp format_pdf_part(base64, :anthropic) do
    %{
      type: "document",
      source: %{
        type: "base64",
        media_type: "application/pdf",
        data: base64
      }
    }
  end

  defp format_pdf_part(base64, _provider) do
    %{
      type: "document",
      document: %{
        type: "base64",
        media_type: "application/pdf",
        data: base64
      }
    }
  end
end

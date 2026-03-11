alias ReqLLM.Scripts.Helpers

defmodule MultimodalImageAnalysis do
  @moduledoc """
  Demonstrates vision/image analysis using multimodal AI models.

  Analyzes images by sending them to vision-capable models along with a text prompt.
  Supports common image formats (JPG, PNG, GIF, WebP) and can be used with any
  vision-capable model.

  ## Usage

      mix run lib/examples/scripts/multimodal_image_analysis.exs [prompt] --file <image_path> [options]

  ## Options

    * `--file` - Path to image file (required)
    * `--model`, `-m` - Model to use (default: openai:gpt-4o-mini)
    * `--log-level`, `-l` - Log level: debug, info, warning, error (default: warning)
    * `--max-tokens` - Maximum tokens to generate
    * `--temperature` - Sampling temperature (0.0-2.0)

  ## Examples

      # Analyze an image with default prompt
      mix run lib/examples/scripts/multimodal_image_analysis.exs --file priv/examples/test.jpg

      # Ask a specific question about the image
      mix run lib/examples/scripts/multimodal_image_analysis.exs "What colors are prominent?" --file image.png

      # Use a different model
      mix run lib/examples/scripts/multimodal_image_analysis.exs --file photo.jpg --model anthropic:claude-3-5-haiku-20241022

      # Control generation parameters
      mix run lib/examples/scripts/multimodal_image_analysis.exs --file image.png --max-tokens 500 --temperature 0.7
  """

  @script_name "multimodal_image_analysis.exs"
  @default_model "openai:gpt-4o-mini"

  def run(argv) do
    Helpers.ensure_app!()

    {parsed_opts, remaining_args} =
      OptionParser.parse!(argv,
        strict: [
          model: :string,
          file: :string,
          log_level: :string,
          max_tokens: :integer,
          temperature: :float
        ],
        aliases: [m: :model, l: :log_level]
      )

    prompt = get_prompt(remaining_args)
    file_path = parsed_opts[:file]

    if is_nil(file_path) do
      print_usage()
      System.halt(1)
    end

    validate_file!(file_path)

    opts = Keyword.merge(parsed_opts, prompt: prompt, file: file_path)

    model = opts[:model] || @default_model

    Logger.configure(level: Helpers.log_level(opts[:log_level] || "warning"))

    Helpers.banner!(@script_name, "Demonstrates vision/image analysis",
      model: model,
      prompt: prompt,
      file: file_path,
      max_tokens: opts[:max_tokens],
      temperature: opts[:temperature]
    )

    media_type = Helpers.media_type(file_path)
    binary_data = File.read!(file_path)

    parts = [
      ReqLLM.Message.ContentPart.text(prompt),
      ReqLLM.Message.ContentPart.image(binary_data, media_type)
    ]

    ctx = ReqLLM.Context.new()
    ctx = ReqLLM.Context.append(ctx, ReqLLM.Context.user(parts))

    generation_opts = build_generation_opts(opts)

    {response, duration_ms} =
      Helpers.time(fn ->
        ReqLLM.generate_text(model, ctx, generation_opts)
      end)

    case response do
      {:ok, resp} -> Helpers.print_text_response(resp, duration_ms, [])
      {:error, error} -> raise error
    end
  rescue
    error -> Helpers.handle_error!(error, @script_name, [])
  end

  defp get_prompt(remaining_args) do
    if Enum.empty?(remaining_args) do
      "Describe this image in detail"
    else
      List.first(remaining_args)
    end
  end

  defp validate_file!(path) do
    if !File.exists?(path) do
      IO.puts(:stderr, IO.ANSI.red() <> "Error: File not found: #{path}" <> IO.ANSI.reset())
      System.halt(1)
    end

    extension = Path.extname(path) |> String.downcase()
    valid_extensions = [".jpg", ".jpeg", ".png", ".gif", ".webp"]

    if extension not in valid_extensions do
      IO.puts(
        :stderr,
        IO.ANSI.red() <>
          "Error: File must be an image (jpg, jpeg, png, gif, webp)" <> IO.ANSI.reset()
      )

      IO.puts(:stderr, "Got: #{extension}")
      System.halt(1)
    end
  end

  defp print_usage do
    IO.puts(:stderr, "Error: --file is required\n")
    IO.puts("Usage: mix run #{@script_name} [prompt] --file <image_path> [options]")
    IO.puts("\nOptions:")
    IO.puts("  --file <path>           Path to image file (required)")
    IO.puts("  --model, -m <model>     Model to use [default: #{@default_model}]")
    IO.puts("  --log-level, -l <level> Log level (debug|info|warning|error)")
    IO.puts("  --max-tokens <int>      Maximum tokens to generate")
    IO.puts("  --temperature <float>   Sampling temperature")
    IO.puts("\nExamples:")
    IO.puts("  mix run #{@script_name} \"What do you see?\" --file priv/examples/test.jpg")

    IO.puts(
      "  mix run #{@script_name} --file image.png --model anthropic:claude-3-5-haiku-20241022"
    )
  end

  defp build_generation_opts(opts) do
    []
    |> Helpers.maybe_put(:max_tokens, opts[:max_tokens])
    |> Helpers.maybe_put(:temperature, opts[:temperature])
  end
end

MultimodalImageAnalysis.run(System.argv())

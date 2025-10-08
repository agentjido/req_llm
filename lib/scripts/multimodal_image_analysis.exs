alias ReqLLM.Scripts.Helpers

defmodule MultimodalImageAnalysis do
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

    Logger.configure(level: parse_log_level(opts[:log_level] || "warning"))

    Helpers.banner!(@script_name, "Demonstrates vision/image analysis",
      model: model,
      prompt: prompt,
      file: file_path,
      max_tokens: opts[:max_tokens],
      temperature: opts[:temperature]
    )

    media_type = detect_media_type(file_path)
    binary_data = File.read!(file_path)

    parts = [
      ReqLLM.Message.ContentPart.text(prompt),
      ReqLLM.Message.ContentPart.image(binary_data, media_type)
    ]

    ctx = ReqLLM.Context.new()
    ctx = ReqLLM.Context.push_user(ctx, parts)

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

  defp detect_media_type(path) do
    case Path.extname(path) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _ -> "image/jpeg"
    end
  end

  defp parse_log_level(level_str) do
    case level_str do
      "debug" -> :debug
      "info" -> :info
      "warning" -> :warning
      "error" -> :error
      _ -> :warning
    end
  end

  defp build_generation_opts(opts) do
    []
    |> maybe_put(:max_tokens, opts[:max_tokens])
    |> maybe_put(:temperature, opts[:temperature])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end

MultimodalImageAnalysis.run(System.argv())

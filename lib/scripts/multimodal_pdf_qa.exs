alias ReqLLM.Scripts.Helpers

defmodule MultimodalPdfQA do
  @script_name "multimodal_pdf_qa.exs"
  @default_model "anthropic:claude-3-5-haiku-20241022"

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
    provider = detect_provider(model)

    validate_provider!(provider)

    Logger.configure(level: parse_log_level(opts[:log_level] || "warning"))

    Helpers.banner!(@script_name, "Demonstrates PDF document analysis",
      model: model,
      prompt: prompt,
      file: file_path,
      max_tokens: opts[:max_tokens],
      temperature: opts[:temperature]
    )

    binary_data = File.read!(file_path)
    filename = Path.basename(file_path)

    parts = [
      ReqLLM.Message.ContentPart.text(prompt),
      ReqLLM.Message.ContentPart.file(binary_data, filename, "application/pdf")
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
      "Summarize the key points"
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

    if extension != ".pdf" do
      IO.puts(
        :stderr,
        IO.ANSI.red() <> "Error: File must be a PDF document" <> IO.ANSI.reset()
      )

      IO.puts(:stderr, "Got: #{extension}")
      System.halt(1)
    end
  end

  defp detect_provider(model) do
    case String.split(model, ":", parts: 2) do
      [provider, _model_name] -> String.to_atom(provider)
      [_single_part] -> :openai
    end
  end

  defp validate_provider!(provider) do
    if provider != :anthropic do
      IO.puts(
        :stderr,
        IO.ANSI.red() <>
          "Error: PDF document analysis is only supported by Anthropic models" <>
          IO.ANSI.reset()
      )

      IO.puts(
        :stderr,
        "Please use an Anthropic model (e.g., anthropic:claude-3-5-haiku-20241022)"
      )

      System.halt(1)
    end
  end

  defp print_usage do
    IO.puts(:stderr, "Error: --file is required\n")
    IO.puts("Usage: mix run #{@script_name} [prompt] --file <pdf_path> [options]")
    IO.puts("\nOptions:")
    IO.puts("  --file <path>           Path to PDF file (required)")
    IO.puts("  --model, -m <model>     Model to use [default: #{@default_model}]")
    IO.puts("  --log-level, -l <level> Log level (debug|info|warning|error)")
    IO.puts("  --max-tokens <int>      Maximum tokens to generate")
    IO.puts("  --temperature <float>   Sampling temperature")
    IO.puts("\nNote: PDF analysis is only supported by Anthropic models")
    IO.puts("\nExamples:")

    IO.puts(
      "  mix run #{@script_name} \"What is this document about?\" --file priv/examples/test.pdf"
    )

    IO.puts(
      "  mix run #{@script_name} --file document.pdf --model anthropic:claude-3-5-sonnet-20241022"
    )
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

MultimodalPdfQA.run(System.argv())

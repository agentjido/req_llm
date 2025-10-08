alias ReqLLM.Scripts.Helpers

defmodule TextStream do
  @script_name "text_stream.exs"

  def run(argv) do
    Helpers.ensure_app!()

    {parsed_opts, remaining_args} =
      OptionParser.parse!(argv,
        strict: [
          model: :string,
          system: :string,
          log_level: :string,
          max_tokens: :integer,
          temperature: :float
        ],
        aliases: [m: :model, s: :system, l: :log_level]
      )

    prompt = get_prompt!(parsed_opts, remaining_args)

    opts = Keyword.put(parsed_opts, :prompt, prompt)

    model = opts[:model] || Helpers.default_text_model()

    Logger.configure(level: parse_log_level(opts[:log_level] || "warning"))

    Helpers.banner!(@script_name, "Demonstrates streaming text generation",
      model: model,
      prompt: prompt,
      system: opts[:system],
      max_tokens: opts[:max_tokens],
      temperature: opts[:temperature]
    )

    ctx = Helpers.context(prompt, system: opts[:system])

    stream_opts = build_stream_opts(opts, ctx)

    {result, duration_ms} =
      Helpers.time(fn ->
        Helpers.print_stream_text(model, stream_opts)
      end)

    case result do
      :ok ->
        IO.puts(IO.ANSI.faint() <> "⏱  #{duration_ms}ms" <> IO.ANSI.reset())
        :ok

      {:error, error} ->
        raise error
    end
  rescue
    error -> Helpers.handle_error!(error, @script_name, [])
  end

  defp get_prompt!(opts, remaining_args) do
    cond do
      opts[:prompt] ->
        opts[:prompt]

      not Enum.empty?(remaining_args) ->
        List.first(remaining_args)

      true ->
        IO.puts(:stderr, "Error: Prompt is required\n")
        IO.puts("Usage: mix run #{@script_name} \"Your prompt here\" [options]")
        IO.puts("\nExample:")
        IO.puts("  mix run #{@script_name} \"Write a haiku about rivers\"")

        IO.puts(
          "  mix run #{@script_name} \"Explain quantum physics\" --model anthropic:claude-3-5-sonnet-20241022"
        )

        System.halt(1)
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

  defp build_stream_opts(opts, ctx) do
    [context: ctx]
    |> maybe_put(:max_tokens, opts[:max_tokens])
    |> maybe_put(:temperature, opts[:temperature])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end

TextStream.run(System.argv())

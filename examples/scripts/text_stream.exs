alias ReqLLM.Scripts.Helpers

defmodule TextStream do
  @moduledoc """
  Demonstrates streaming text generation from an LLM.

  This script shows how to use `ReqLLM.stream_text/3` to generate text with
  real-time streaming output. Content chunks are printed as they arrive,
  and usage statistics are displayed when the stream completes.

  ## Usage

      mix run lib/examples/scripts/text_stream.exs "Your prompt here" [options]

  ## Options

    * `--model` (`-m`) - Model identifier (default: "openai:gpt-4o")
    * `--system` (`-s`) - System message to set context
    * `--max_tokens` - Maximum tokens to generate
    * `--temperature` - Sampling temperature (0.0-2.0)
    * `--log_level` (`-l`) - Logging level: debug, info, warning, error (default: warning)

  ## Examples

      # Basic streaming generation
      mix run lib/examples/scripts/text_stream.exs "Write a haiku about rivers"

      # With specific model and parameters
      mix run lib/examples/scripts/text_stream.exs "Explain quantum physics" \\
        --model anthropic:claude-sonnet-4-5-20250929 \\
        --max_tokens 500 \\
        --temperature 0.7

      # With system message
      mix run lib/examples/scripts/text_stream.exs "What is 2+2?" \\
        --system "You are a helpful math tutor"
  """

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

    Logger.configure(level: Helpers.log_level(opts[:log_level] || "warning"))

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
        case ReqLLM.stream_text(model, ctx, stream_opts) do
          {:ok, response} ->
            IO.write(IO.ANSI.green() <> "Assistant: " <> IO.ANSI.reset())

            response.stream
            |> Enum.each(fn chunk ->
              case chunk do
                %{type: :content, text: text} when is_binary(text) ->
                  IO.write(text)

                _ ->
                  :ok
              end
            end)

            IO.puts("\n")

            usage = ReqLLM.StreamResponse.usage(response)
            {:ok, usage}

          {:error, error} ->
            {:error, error}
        end
      end)

    case result do
      {:ok, usage} ->
        IO.puts(IO.ANSI.faint() <> "⏱  #{duration_ms}ms" <> IO.ANSI.reset())

        if usage do
          usage
          |> Helpers.usage_lines()
          |> Enum.each(&IO.puts(IO.ANSI.faint() <> &1 <> IO.ANSI.reset()))
        end

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
        "Write a haiku about coding."
    end
  end

  defp build_stream_opts(opts, _ctx) do
    []
    |> Helpers.maybe_put(:max_tokens, opts[:max_tokens])
    |> Helpers.maybe_put(:temperature, opts[:temperature])
  end
end

TextStream.run(System.argv())

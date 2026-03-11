alias ReqLLM.Scripts.Helpers

defmodule ContextReuse do
  @moduledoc """
  Demonstrates Context portability between generate_text and stream_text.

  Shows that the same context can be seamlessly passed between different API
  functions (generate_text and stream_text) without any modifications.

  ## Usage

      mix run lib/examples/scripts/context_reuse.exs "Tell me a fact about space"
      mix run lib/examples/scripts/context_reuse.exs "Count from 1 to 3" --model anthropic:claude-sonnet-4-5-20250929

  ## Options

    * `--model`, `-m` - Model to use (default: openai:gpt-4o)
    * `--system`, `-s` - System message
    * `--log-level`, `-l` - Log level: debug, info, warning, error (default: warning)
    * `--max-tokens` - Maximum tokens in response
    * `--temperature` - Temperature for sampling

  ## Examples

      # Basic usage with default model
      mix run lib/examples/scripts/context_reuse.exs "Tell me a joke"

      # With specific model and parameters
      mix run lib/examples/scripts/context_reuse.exs "Explain recursion" --model openai:gpt-4o --temperature 0.7

      # With system message
      mix run lib/examples/scripts/context_reuse.exs "Hello" --system "You are a helpful assistant"
  """

  @script_name "context_reuse.exs"

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

    Helpers.banner!(
      @script_name,
      "Demonstrates Context portability between generate_text and stream_text",
      model: model,
      prompt: prompt,
      system: opts[:system],
      max_tokens: opts[:max_tokens],
      temperature: opts[:temperature]
    )

    ctx = Helpers.context(prompt, system: opts[:system])

    generation_opts = build_generation_opts(opts)

    IO.puts(IO.ANSI.bright() <> "\n━━━ Step 1: generate_text ━━━" <> IO.ANSI.reset())

    {response1, duration1_ms} =
      Helpers.time(fn ->
        ReqLLM.generate_text(model, ctx, generation_opts)
      end)

    {text1, usage1, ctx2} =
      case response1 do
        {:ok, resp} ->
          text = ReqLLM.Response.text(resp)
          IO.puts(IO.ANSI.green() <> "Assistant: " <> IO.ANSI.reset() <> text)
          IO.puts("")
          Helpers.print_usage_and_timing(resp.usage, duration1_ms, [])
          {text, resp.usage, resp.context}

        {:error, error} ->
          raise error
      end

    IO.puts(
      IO.ANSI.bright() <> "\n━━━ Step 2: stream_text with response context ━━━" <> IO.ANSI.reset()
    )

    {stream_result, duration2_ms} =
      Helpers.time(fn ->
        consume_stream(model, ctx2, generation_opts)
      end)

    {text2, usage2, ctx3} =
      case stream_result do
        {:ok, text, usage} ->
          IO.puts("")
          Helpers.print_usage_and_timing(usage, duration2_ms, [])
          updated_ctx = ReqLLM.Context.append(ctx2, ReqLLM.Context.assistant(text))
          {text, usage, updated_ctx}

        {:error, error} ->
          raise error
      end

    IO.puts(
      IO.ANSI.bright() <>
        "\n━━━ Step 3: generate_text with updated context ━━━" <> IO.ANSI.reset()
    )

    {response3, duration3_ms} =
      Helpers.time(fn ->
        ReqLLM.generate_text(model, ctx3, generation_opts)
      end)

    {text3, usage3, _ctx4} =
      case response3 do
        {:ok, resp} ->
          text = ReqLLM.Response.text(resp)
          IO.puts(IO.ANSI.green() <> "Assistant: " <> IO.ANSI.reset() <> text)
          IO.puts("")
          Helpers.print_usage_and_timing(resp.usage, duration3_ms, [])
          {text, resp.usage, resp.context}

        {:error, error} ->
          raise error
      end

    IO.puts(IO.ANSI.bright() <> "\n━━━ Summary ━━━" <> IO.ANSI.reset())

    print_summary([
      {1, text1, usage1, duration1_ms},
      {2, text2, usage2, duration2_ms},
      {3, text3, usage3, duration3_ms}
    ])
  rescue
    error -> Helpers.handle_error!(error, @script_name, [])
  end

  defp consume_stream(model, ctx, opts) do
    IO.write(IO.ANSI.green() <> "Assistant: " <> IO.ANSI.reset())

    case ReqLLM.stream_text(model, ctx, opts) do
      {:ok, response} ->
        initial_state = %{text: "", usage: nil}

        result =
          response.stream
          |> Enum.reduce(initial_state, fn chunk, acc ->
            case chunk do
              %ReqLLM.StreamChunk{type: :content, text: text} when is_binary(text) ->
                IO.write(text)
                %{acc | text: acc.text <> text}

              %ReqLLM.StreamChunk{type: :meta, metadata: metadata} ->
                if metadata[:finish_reason] && metadata[:usage] do
                  %{acc | usage: metadata[:usage]}
                else
                  acc
                end

              _ ->
                acc
            end
          end)

        {:ok, result.text, result.usage}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp print_summary(results) do
    total_duration = Enum.reduce(results, 0, fn {_, _, _, duration}, acc -> acc + duration end)

    total_usage = %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      cost: 0.0
    }

    total_usage =
      Enum.reduce(results, total_usage, fn {_, _, usage, _}, acc ->
        if usage do
          %{
            input_tokens: acc.input_tokens + (usage[:input_tokens] || 0),
            output_tokens: acc.output_tokens + (usage[:output_tokens] || 0),
            total_tokens: acc.total_tokens + (usage[:total_tokens] || 0),
            cost: acc.cost + (usage[:cost] || 0.0)
          }
        else
          acc
        end
      end)

    IO.puts(IO.ANSI.faint() <> "Total time: #{total_duration}ms" <> IO.ANSI.reset())

    IO.puts(
      IO.ANSI.faint() <>
        "Total tokens: #{total_usage.input_tokens} in / #{total_usage.output_tokens} out / #{total_usage.total_tokens} total" <>
        IO.ANSI.reset()
    )

    if total_usage.cost > 0 do
      IO.puts(
        IO.ANSI.faint() <> "Total cost: $#{Float.round(total_usage.cost, 6)}" <> IO.ANSI.reset()
      )
    end

    :ok
  end

  defp get_prompt!(opts, remaining_args) do
    cond do
      opts[:prompt] ->
        opts[:prompt]

      not Enum.empty?(remaining_args) ->
        List.first(remaining_args)

      true ->
        "Tell me about Elixir."
    end
  end

  defp build_generation_opts(opts) do
    []
    |> Helpers.maybe_put(:max_tokens, opts[:max_tokens])
    |> Helpers.maybe_put(:temperature, opts[:temperature])
  end
end

ContextReuse.run(System.argv())

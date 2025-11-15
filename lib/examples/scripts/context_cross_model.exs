#!/usr/bin/env elixir

alias ReqLLM.Scripts.Helpers

defmodule ContextCrossModel do
  @moduledoc """
  Demonstrates Context reuse across different models and providers.

  Shows that ReqLLM Context is provider-agnostic: the same context can be
  seamlessly passed between different models and providers without any modifications.

  ## Usage

      mix run lib/examples/scripts/context_cross_model.exs "Tell me a joke"
      mix run lib/examples/scripts/context_cross_model.exs "Explain functional programming" --model-a openai:gpt-4o --model-b anthropic:claude-sonnet-4-5-20250929

  ## Options

    * `--model-a` - First model to use (default: openai:gpt-4o-mini)
    * `--model-b` - Second model to use (default: google:gemini-2.0-flash-exp)
    * `--system`, `-s` - System message
    * `--log-level`, `-l` - Log level: debug, info, warning, error (default: warning)
    * `--max-tokens` - Maximum tokens in response
    * `--temperature` - Temperature for sampling

  ## Examples

      # Basic usage with default models
      mix run lib/examples/scripts/context_cross_model.exs "What is AI?"

      # With specific models
      mix run lib/examples/scripts/context_cross_model.exs "Tell me a joke" --model-a openai:gpt-4o --model-b google:gemini-1.5-flash

      # With system message and parameters
      mix run lib/examples/scripts/context_cross_model.exs "Hello" --system "You are concise" --temperature 0.5
  """

  @script_name "context_cross_model.exs"

  def run(argv) do
    Helpers.ensure_app!()

    {parsed_opts, remaining_args} =
      OptionParser.parse!(argv,
        strict: [
          model_a: :string,
          model_b: :string,
          system: :string,
          log_level: :string,
          max_tokens: :integer,
          temperature: :float
        ],
        aliases: [s: :system, l: :log_level]
      )

    prompt = get_prompt!(parsed_opts, remaining_args)

    opts = Keyword.put(parsed_opts, :prompt, prompt)

    model_a = opts[:model_a] || "openai:gpt-4o-mini"
    model_b = opts[:model_b] || "google:gemini-2.0-flash-exp"

    Logger.configure(level: Helpers.log_level(opts[:log_level] || "warning"))

    banner_opts =
      [
        model_a: model_a,
        model_b: model_b,
        prompt: prompt
      ]
      |> Helpers.maybe_add(:system, opts[:system])
      |> Helpers.maybe_add(:max_tokens, opts[:max_tokens])
      |> Helpers.maybe_add(:temperature, opts[:temperature])

    Helpers.banner!(
      @script_name,
      "Demonstrates Context reuse across different models and providers",
      banner_opts
    )

    ctx = Helpers.context(prompt, system: opts[:system])

    generation_opts = build_generation_opts(opts)

    IO.puts(IO.ANSI.bright() <> "\n━━━ Step 1: Generate with #{model_a} ━━━" <> IO.ANSI.reset())

    {response1, duration1_ms} =
      Helpers.time(fn ->
        ReqLLM.generate_text(model_a, ctx, generation_opts)
      end)

    {text1, usage1, ctx2} =
      case response1 do
        {:ok, resp} ->
          text = ReqLLM.Response.text(resp) || "(no text response)"
          IO.puts(IO.ANSI.green() <> "[#{model_a}] Assistant: " <> IO.ANSI.reset() <> text)
          IO.puts("")
          Helpers.print_usage_and_timing(resp.usage, duration1_ms, [])
          context = extract_context(resp)
          {text, resp.usage, context}

        {:error, error} ->
          raise error
      end

    IO.puts(
      IO.ANSI.bright() <>
        "\n━━━ Step 2: Generate with #{model_b} using same context ━━━" <> IO.ANSI.reset()
    )

    {response2, duration2_ms} =
      Helpers.time(fn ->
        ReqLLM.generate_text(model_b, ctx2, generation_opts)
      end)

    {text2, usage2, _ctx3} =
      case response2 do
        {:ok, resp} ->
          text = ReqLLM.Response.text(resp) || "(no text response)"
          IO.puts(IO.ANSI.green() <> "[#{model_b}] Assistant: " <> IO.ANSI.reset() <> text)
          IO.puts("")
          Helpers.print_usage_and_timing(resp.usage, duration2_ms, [])
          context = extract_context(resp)
          {text, resp.usage, context}

        {:error, error} ->
          raise error
      end

    IO.puts(IO.ANSI.bright() <> "\n━━━ Summary ━━━" <> IO.ANSI.reset())
    IO.puts("Context was successfully reused across providers without modification.")
    IO.puts("")

    print_summary([
      {model_a, text1, usage1, duration1_ms},
      {model_b, text2, usage2, duration2_ms}
    ])
  rescue
    error -> Helpers.handle_error!(error, @script_name, [])
  end

  defp extract_context(response) do
    if Map.has_key?(response, :context) do
      response.context
    else
      ReqLLM.Context.new()
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
        "What is functional programming?"
    end
  end

  defp build_generation_opts(opts) do
    []
    |> Helpers.maybe_put(:max_tokens, opts[:max_tokens])
    |> Helpers.maybe_put(:temperature, opts[:temperature])
  end
end

ContextCrossModel.run(System.argv())

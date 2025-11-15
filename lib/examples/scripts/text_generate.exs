alias ReqLLM.Scripts.Helpers

defmodule TextGenerate do
  @moduledoc """
  Demonstrates basic text generation using ReqLLM.

  This script shows how to use the ReqLLM.generate_text/3 API to generate
  text responses from various LLM providers. It supports customization of
  models, system prompts, and generation parameters.

  ## Usage

      mix run lib/examples/scripts/text_generate.exs "Your prompt here" [options]

  ## Options

    * `--model`, `-m` - Model to use (default: openai:gpt-4o-mini)
    * `--system`, `-s` - System prompt to set context
    * `--max-tokens` - Maximum tokens to generate
    * `--temperature` - Sampling temperature (0.0-2.0)
    * `--log-level`, `-l` - Log level (debug, info, warning, error)

  ## Examples

      # Basic usage with default model
      mix run lib/examples/scripts/text_generate.exs "Explain functional programming in one sentence"

      # Using a specific model with system prompt
      mix run lib/examples/scripts/text_generate.exs "Write a haiku" \\
        --model anthropic:claude-sonnet-4-5-20250929 \\
        --system "You are a creative poet"

      # With generation parameters
      mix run lib/examples/scripts/text_generate.exs "Tell me a story" \\
        --max-tokens 500 \\
        --temperature 0.7
  """

  @script_name "text_generate.exs"

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

    Helpers.banner!(@script_name, "Demonstrates basic text generation",
      model: model,
      prompt: prompt,
      system: opts[:system],
      max_tokens: opts[:max_tokens],
      temperature: opts[:temperature]
    )

    ctx = Helpers.context(prompt, system: opts[:system])

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

  defp get_prompt!(opts, remaining_args) do
    cond do
      opts[:prompt] ->
        opts[:prompt]

      not Enum.empty?(remaining_args) ->
        List.first(remaining_args)

      true ->
        "Explain functional programming in one sentence."
    end
  end

  defp build_generation_opts(opts) do
    []
    |> Helpers.maybe_put(:max_tokens, opts[:max_tokens])
    |> Helpers.maybe_put(:temperature, opts[:temperature])
  end
end

TextGenerate.run(System.argv())

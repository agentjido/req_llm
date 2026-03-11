defmodule ReasoningTokensExample do
  @moduledoc """
  Demonstrates reasoning token usage with models that support extended thinking.

  This example shows how to configure reasoning options like effort level,
  token budget, and visibility settings, then track reasoning token consumption
  in the usage statistics.

  ## Usage

      mix run lib/examples/scripts/reasoning_tokens.exs --prompt "Solve this puzzle"

  ## Options

    * `--prompt` - The prompt to send (required)
    * `--model` - Model to use (default: "openai:o1-mini")
    * `--log-level` - Logging level: debug, info, warning, error (default: warning)
    * `--max-tokens` - Maximum tokens to generate
    * `--temperature` - Sampling temperature (0.0-2.0)
    * `--reasoning-effort` - Reasoning effort level: low, medium, high
    * `--reasoning-token-budget` - Maximum reasoning tokens to use
    * `--thinking-visibility` - Thinking visibility: final, hidden

  ## Examples

      # Basic reasoning with default settings
      mix run lib/examples/scripts/reasoning_tokens.exs --prompt "Explain quantum entanglement"

      # High effort reasoning with token budget
      mix run lib/examples/scripts/reasoning_tokens.exs \\
        --prompt "Solve this logic puzzle" \\
        --reasoning-effort high \\
        --reasoning-token-budget 1000

      # Control thinking visibility
      mix run lib/examples/scripts/reasoning_tokens.exs \\
        --prompt "Analyze this code" \\
        --thinking-visibility hidden
  """

  alias ReqLLM.Scripts.Helpers

  @schema [
    prompt: [
      type: :string,
      required: false,
      default: "Explain why the sky is blue in simple terms.",
      doc: "The prompt to send to the model"
    ],
    model: [
      type: :string,
      default: "openai:o1-mini",
      doc: "Model to use (must support reasoning)"
    ],
    log_level: [
      type: :string,
      default: "warning",
      doc: "Log level: debug, info, warning, error"
    ],
    max_tokens: [
      type: :integer,
      doc: "Maximum tokens to generate"
    ],
    temperature: [
      type: :float,
      doc: "Sampling temperature"
    ],
    reasoning_effort: [
      type: :string,
      doc: "Reasoning effort level: low, medium, high"
    ],
    reasoning_token_budget: [
      type: :integer,
      doc: "Maximum reasoning tokens to use"
    ],
    thinking_visibility: [
      type: :string,
      doc: "Thinking visibility: final, hidden"
    ]
  ]

  def run(argv) do
    Helpers.ensure_app!()
    opts = Helpers.parse_args(argv, @schema, "reasoning_tokens.exs")

    Logger.configure(level: Helpers.log_level(opts[:log_level]))

    Helpers.banner!("reasoning_tokens.exs", "Demonstrates reasoning token usage", opts)

    model = opts[:model]
    prompt = opts[:prompt]

    context = Helpers.context(prompt)

    generation_opts =
      []
      |> Helpers.maybe_put(:max_tokens, opts[:max_tokens])
      |> Helpers.maybe_put(:temperature, opts[:temperature])
      |> Helpers.maybe_put(:reasoning_effort, parse_reasoning_effort(opts[:reasoning_effort]))
      |> Helpers.maybe_put(:reasoning_token_budget, opts[:reasoning_token_budget])
      |> Helpers.maybe_put(
        :thinking_visibility,
        parse_thinking_visibility(opts[:thinking_visibility])
      )

    {response, duration_ms} =
      Helpers.time(fn ->
        case ReqLLM.generate_text(model, context, generation_opts) do
          {:ok, resp} -> resp
          {:error, error} -> Helpers.handle_error!(error, "reasoning_tokens.exs", [])
        end
      end)

    Helpers.print_text_response(response, duration_ms, [])

    if response.usage[:reasoning_tokens] do
      IO.puts(
        "\n" <>
          IO.ANSI.cyan() <>
          "💡 This model used #{response.usage[:reasoning_tokens]} reasoning tokens for extended thinking." <>
          IO.ANSI.reset()
      )
    else
      IO.puts(
        "\n" <>
          IO.ANSI.yellow() <>
          "⚠️  No reasoning tokens reported. This model may not support reasoning features." <>
          IO.ANSI.reset()
      )
    end
  end

  defp parse_reasoning_effort(nil), do: nil
  defp parse_reasoning_effort("low"), do: :low
  defp parse_reasoning_effort("medium"), do: :medium
  defp parse_reasoning_effort("high"), do: :high
  defp parse_reasoning_effort(other), do: String.to_atom(other)

  defp parse_thinking_visibility(nil), do: nil
  defp parse_thinking_visibility("final"), do: :final
  defp parse_thinking_visibility("hidden"), do: :hidden
  defp parse_thinking_visibility(other), do: String.to_atom(other)
end

ReasoningTokensExample.run(System.argv())

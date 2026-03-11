alias ReqLLM.Scripts.Helpers

defmodule UsageCostSmoke do
  @moduledoc """
  Smoke test for usage cost fields across multiple models.

  Usage:

      mix run lib/examples/scripts/usage_cost_smoke.exs [options]

  Options:

    * `--models`, `-m` - Comma-separated model specs
    * `--prompt`, `-p` - Prompt to use for all models
    * `--max-tokens`, `-t` - Maximum tokens to generate
    * `--log-level`, `-l` - Log level (debug, info, warning, error)

  Examples:

      mix run lib/examples/scripts/usage_cost_smoke.exs

      mix run lib/examples/scripts/usage_cost_smoke.exs \\
        --models "openai:gpt-4o-mini,anthropic:claude-3-5-haiku-20241022,google:gemini-2.0-flash" \\
        --prompt "Say hello in one short sentence."
  """

  @script_name "usage_cost_smoke.exs"

  def run(argv) do
    Helpers.ensure_app!()

    {opts, _} =
      OptionParser.parse!(argv,
        strict: [
          models: :string,
          prompt: :string,
          max_tokens: :integer,
          log_level: :string
        ],
        aliases: [m: :models, p: :prompt, t: :max_tokens, l: :log_level]
      )

    Logger.configure(level: Helpers.log_level(opts[:log_level] || "warning"))

    models = parse_models(opts[:models]) || default_models()
    prompt = opts[:prompt] || "Reply with one short sentence."

    generation_opts =
      []
      |> Helpers.maybe_put(:max_tokens, opts[:max_tokens])

    Helpers.banner!(@script_name, "Usage cost smoke test",
      models: models,
      prompt: prompt,
      max_tokens: opts[:max_tokens]
    )

    Enum.each(models, fn model -> check_model(model, prompt, generation_opts) end)
  rescue
    error -> Helpers.handle_error!(error, @script_name, [])
  end

  defp parse_models(nil), do: nil

  defp parse_models(models) when is_binary(models) do
    models
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp default_models do
    Application.get_env(:req_llm, :sample_text_models) ||
      [
        "anthropic:claude-opus-4-5",
        "anthropic:claude-sonnet-4-5",
        "anthropic:claude-haiku-4-5",
        "anthropic:claude-opus-4-1",
        "anthropic:claude-opus-4",
        "anthropic:claude-sonnet-4",
        "anthropic:claude-3-7-sonnet",
        "anthropic:claude-3-5-haiku",
        "google:gemini-3-flash-preview",
        "google:gemini-3-pro-preview",
        "google:gemini-2.5-pro",
        "google:gemini-2.5-flash",
        "google:gemini-2.5-flash-lite",
        "google:gemini-2.0-flash",
        "google:gemini-2.0-flash-lite",
        "openai:gpt-5.2",
        "openai:gpt-5",
        "openai:gpt-5-mini",
        "openai:gpt-5-nano",
        "openai:gpt-4.1",
        "xai:grok-4-1-fast-reasoning",
        "xai:grok-4-1-fast-non-reasoning",
        "xai:grok-4",
        "xai:grok-4-0709",
        "xai:grok-4-fast-reasoning",
        "xai:grok-4-fast-non-reasoning"
      ]
  end

  defp check_model(model_spec, prompt, generation_opts) do
    case ReqLLM.model(model_spec) do
      {:ok, %LLMDB.Model{} = llm_model} ->
        opts = maybe_provider_opts(llm_model, generation_opts)

        {result, duration_ms} =
          Helpers.time(fn -> ReqLLM.generate_text(model_spec, prompt, opts) end)

        render_result(model_spec, llm_model, result, duration_ms)

      {:error, error} ->
        IO.puts("#{model_spec} | model lookup error: #{format_error(error)}")
    end
  end

  defp maybe_provider_opts(%LLMDB.Model{provider: :openrouter}, generation_opts) do
    Keyword.put(generation_opts, :provider_options, openrouter_usage: %{include: true})
  end

  defp maybe_provider_opts(_model, generation_opts), do: generation_opts

  defp render_result(model_spec, llm_model, {:ok, response}, duration_ms) do
    usage = ReqLLM.Response.usage(response)
    pricing = llm_model.cost != nil

    cost_fields? =
      is_map(usage) and Map.has_key?(usage, :total_cost) and Map.has_key?(usage, :input_cost) and
        Map.has_key?(usage, :output_cost)

    tokens = if is_map(usage), do: usage[:total_tokens] || usage["total_tokens"]
    total_cost = if is_map(usage), do: usage[:total_cost] || usage["total_cost"]

    IO.puts(
      "#{model_spec} | pricing: #{bool(pricing)} | usage: #{usage_present(usage)} | " <>
        "cost_fields: #{bool(cost_fields?)} | total_tokens: #{format(tokens)} | " <>
        "total_cost: #{format(total_cost)} | ms: #{duration_ms}"
    )
  end

  defp render_result(model_spec, _llm_model, {:error, error}, _duration_ms) do
    IO.puts("#{model_spec} | error: #{format_error(error)}")
  end

  defp usage_present(usage) when is_map(usage), do: "yes"
  defp usage_present(_), do: "no"

  defp bool(true), do: "yes"
  defp bool(false), do: "no"

  defp format(nil), do: "n/a"
  defp format(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 6)
  defp format(value), do: to_string(value)

  defp format_error(%{__struct__: _} = error), do: Exception.message(error)
  defp format_error(other), do: inspect(other)
end

UsageCostSmoke.run(System.argv())

defmodule Mix.Tasks.ReqLlm.GenerateText do
  @shortdoc "Generate text from any AI model"

  @moduledoc """
  Simple mix task for text generation from any supported AI model.

  ## Usage

      mix req.llm.generate_text "Your prompt here" --model provider:model-name

  ## Examples

      # Generate from Groq
      mix req.llm.generate_text "Explain APIs" --model groq:gemma2-9b-it

      # Generate from OpenAI with options
      mix req.llm.generate_text "Write a story" --model openai:gpt-4o --max-tokens 500 --temperature 0.8

  ## Options

      --model         Model specification (provider:model-name)
      --system        System prompt/message
      --max-tokens    Maximum tokens to generate
      --temperature   Sampling temperature (0.0-2.0)
      --log-level     Output verbosity: quiet, normal, verbose, debug
  """
  use Mix.Task

  alias Mix.Tasks.ReqLlm.Shared

  @preferred_cli_env ["req.llm.generate_text": :dev]
  @spec run([String.t()]) :: :ok | no_return()
  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:req_llm)

    {opts, args_list, _} = Shared.parse_args(args)

    case Shared.validate_prompt(args_list, "generate_text") do
      {:ok, prompt} ->
        model_spec = Keyword.get(opts, :model, "groq:gemma2-9b-it")
        log_level = Shared.parse_log_level(Keyword.get(opts, :log_level))
        quiet = log_level == :quiet
        metrics = log_level in [:verbose, :debug]

        if !quiet do
          IO.puts("Generating from #{model_spec}")
          IO.puts("Prompt: #{prompt}")
          IO.puts("")
        end

        generate_opts = Shared.build_generate_opts(opts)
        start_time = System.monotonic_time(:millisecond)

        try do
          ReqLLM.Generation.generate_text(model_spec, prompt, generate_opts)
          |> Shared.handle_common_errors()
          |> handle_success(quiet, metrics, start_time, model_spec, prompt)
        rescue
          error -> Shared.handle_rescue_error(error)
        end

      {:error, :no_prompt} ->
        System.halt(1)
    end
  end

  defp handle_success({:ok, response}, quiet, metrics, start_time, model_spec, prompt) do
    if !quiet do
      IO.puts("Response:")
      IO.puts("   Model: #{response.model}")
      IO.puts("")
      IO.puts(ReqLLM.Response.text(response))
      IO.puts("")
    end

    if metrics do
      text = ReqLLM.Response.text(response)
      Shared.show_stats(text, start_time, model_spec, prompt, response, :text)
    end

    if !quiet do
      end_time = System.monotonic_time(:millisecond)
      response_time = end_time - start_time
      IO.puts("Response time: #{response_time}ms")
    end

    :ok
  end
end

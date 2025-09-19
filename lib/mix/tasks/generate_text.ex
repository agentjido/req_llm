defmodule Mix.Tasks.Req.Llm.GenerateText do
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
  """
  use Mix.Task

  @preferred_cli_env ["req.llm.generate_text": :dev]
  @spec run([String.t()]) :: :ok | no_return()
  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:req_llm)

    {opts, args_list, _} =
      OptionParser.parse(args,
        switches: [
          model: :string,
          system: :string,
          max_tokens: :integer,
          temperature: :float
        ]
      )

    prompt =
      case args_list do
        [p | _] ->
          p

        [] ->
          IO.puts(
            "Usage: mix req.llm.generate_text \"Your prompt here\" --model provider:model-name"
          )

          IO.puts("")
          IO.puts("Examples:")
          IO.puts("  mix req.llm.generate_text \"Explain HTTP\" --model groq:gemma2-9b-it")

          IO.puts(
            "  mix req.llm.generate_text \"Write a poem\" --model openai:gpt-4o --temperature 0.9"
          )

          System.halt(1)
      end

    model_spec = Keyword.get(opts, :model, "groq:gemma2-9b-it")

    IO.puts("Generating from #{model_spec}")
    IO.puts("Prompt: #{prompt}")
    IO.puts("")

    generate_opts =
      []
      |> maybe_add_option(opts, :system_prompt, :system)
      |> maybe_add_option(opts, :max_tokens)
      |> maybe_add_option(opts, :temperature)
      |> Enum.reject(fn {_key, val} -> is_nil(val) end)

    start_time = System.monotonic_time(:millisecond)

    try do
      case ReqLLM.Generation.generate_text(model_spec, prompt, generate_opts) do
        {:ok, response} ->
          IO.puts("Response:")
          IO.puts("   Model: #{response.model}")
          IO.puts("")
          IO.puts(ReqLLM.Response.text(response))
          IO.puts("")

          end_time = System.monotonic_time(:millisecond)
          response_time = end_time - start_time
          IO.puts("Response time: #{response_time}ms")

          :ok

        {:error, %ReqLLM.Error.Invalid.Provider{provider: provider}} ->
          IO.puts("Error: Unknown provider '#{provider}'. Please check that the provider is supported and properly configured.")
          IO.puts("Available providers: openai, groq, xai (others may require additional setup)")
          System.halt(1)

        {:error, %ReqLLM.Error.Invalid.Parameter{parameter: param}} ->
          IO.puts("Error: #{param}")
          System.halt(1)

        {:error, %ReqLLM.Error.API.Request{reason: reason, status: status}} when not is_nil(status) ->
          IO.puts("API Error (#{status}): #{reason}")
          System.halt(1)

        {:error, %ReqLLM.Error.API.Request{reason: reason}} ->
          IO.puts("API Error: #{reason}")
          System.halt(1)

        {:error, error} ->
          IO.puts("Generation failed: #{format_error(error)}")
          System.halt(1)
      end
    rescue
      error in UndefinedFunctionError ->
        case error do
          %UndefinedFunctionError{module: nil, function: :prepare_request} ->
            IO.puts("Error: Provider not properly configured or not available. Please check your model specification.")
            System.halt(1)

          _ ->
            IO.puts("Unexpected error: #{format_error(error)}")
            System.halt(1)
        end

      error ->
        IO.puts("Unexpected error: #{format_error(error)}")
        System.halt(1)
    end
  end

  defp format_error(%{__struct__: _} = error) do
    case Exception.message(error) do
      message when is_binary(message) -> message
      _ -> inspect(error)
    end
  end

  defp format_error(error) do
    inspect(error)
  end

  defp maybe_add_option(opts_list, parsed_opts, target_key, source_key \\ nil) do
    source_key = source_key || target_key

    case Keyword.get(parsed_opts, source_key) do
      nil -> opts_list
      value -> Keyword.put(opts_list, target_key, value)
    end
  end
end

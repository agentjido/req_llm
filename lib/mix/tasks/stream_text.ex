defmodule Mix.Tasks.Req.Llm.StreamText do
  @shortdoc "Stream text generation from any AI model"

  @moduledoc """
  Generic mix task for streaming text generation from any supported AI model.

  Supports all providers in the ReqLLM ecosystem with real-time streaming 
  and comprehensive metrics.

  ## Usage

      mix req.llm.stream_text "Your prompt here" --model provider:model-name

  ## Examples

      # Stream from Groq
      mix req.llm.stream_text "Explain streaming APIs" --model groq:gemma2-9b-it

      # Stream from OpenAI with options
      mix req.llm.stream_text "Write a story" --model openai:gpt-4o --max-tokens 500 --temperature 0.8

      # Stream from Anthropic with system prompt
      mix req.llm.stream_text "Analyze this code" --model anthropic:claude-3-sonnet --system "You are a code reviewer"

  ## Options

      --model         Model specification (provider:model-name)
      --system        System prompt/message
      --max-tokens    Maximum tokens to generate
      --temperature   Sampling temperature (0.0-2.0)
      --verbose       Show detailed chunk information
      --metrics       Show performance metrics
      --quiet         Minimal output
  """
  use Mix.Task

  @preferred_cli_env ["req.llm.stream_text": :dev]
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
          temperature: :float,
          verbose: :boolean,
          metrics: :boolean,
          quiet: :boolean
        ]
      )

    prompt =
      case args_list do
        [p | _] ->
          p

        [] ->
          IO.puts(
            "Usage: mix req.llm.stream_text \"Your prompt here\" --model provider:model-name"
          )

          IO.puts("")
          IO.puts("Examples:")

          IO.puts(
            "  mix req.llm.stream_text \"Explain HTTP streaming\" --model groq:gemma2-9b-it"
          )

          IO.puts(
            "  mix req.llm.stream_text \"Write a poem\" --model openai:gpt-4o --temperature 0.9"
          )

          System.halt(1)
      end

    model_spec = Keyword.get(opts, :model, "groq:gemma2-9b-it")
    quiet = Keyword.get(opts, :quiet, false)
    verbose = Keyword.get(opts, :verbose, false)
    metrics = Keyword.get(opts, :metrics, false)

    if !quiet do
      IO.puts("Streaming from #{model_spec}")
      IO.puts("Prompt: #{prompt}")
      IO.puts("")
    end

    stream_opts =
      []
      |> maybe_add_option(opts, :system_prompt, :system)
      |> maybe_add_option(opts, :max_tokens)
      |> maybe_add_option(opts, :temperature)
      |> Enum.reject(fn {_key, val} -> is_nil(val) end)

    start_time = System.monotonic_time(:millisecond)

    try do
      case ReqLLM.stream_text(model_spec, prompt, stream_opts) do
        {:ok, response} ->
          if !quiet do
            IO.puts("Response:")
            IO.puts("   Model: #{response.model}")
            IO.puts("")
          end

          {text_chunks, chunk_count} =
            response.stream
            |> Enum.reduce({[], 0}, fn chunk, {acc_chunks, count} ->
              count = count + 1

              cond do
                verbose and not quiet ->
                  IO.puts("[#{count}]: #{inspect(chunk)}")

                  case chunk do
                    %ReqLLM.StreamChunk{type: :content, text: text} when is_binary(text) ->
                      {[text | acc_chunks], count}

                    _ ->
                      {acc_chunks, count}
                  end

                not quiet ->
                  case chunk do
                    %ReqLLM.StreamChunk{type: :content, text: text} when is_binary(text) ->
                      IO.binwrite(:stdio, text)
                      :io.put_chars(:standard_io, [])
                      {[text | acc_chunks], count}

                    %ReqLLM.StreamChunk{type: :tool_call, name: name} ->
                      IO.binwrite(:stdio, "\n[TOOL CALL: #{name}]")
                      :io.put_chars(:standard_io, [])
                      {acc_chunks, count}

                    %ReqLLM.StreamChunk{type: :meta} ->
                      if verbose do
                        IO.binwrite(:stdio, "\n[META]")
                        :io.put_chars(:standard_io, [])
                      end
                      {acc_chunks, count}

                    other ->
                      if verbose, do: IO.puts("Other chunk: #{inspect(other)}")
                      {acc_chunks, count}
                  end

                true ->
                  case chunk do
                    %ReqLLM.StreamChunk{type: :content, text: text} when is_binary(text) ->
                      {[text | acc_chunks], count}

                    _ ->
                      {acc_chunks, count}
                  end
              end
            end)

          if !quiet, do: IO.puts("\n")

          if metrics do
            full_text = text_chunks |> Enum.reverse() |> Enum.join("")
            show_key_stats(full_text, start_time, model_spec, prompt, chunk_count)
          end

          if !quiet, do: IO.puts("Streaming completed")
          :ok

        {:error, error} ->
          IO.puts("Streaming failed: #{inspect(error)}")
          System.halt(1)
      end
    rescue
      error ->
        IO.puts("Error: #{inspect(error)}")
        System.halt(1)
    end
  end

  defp maybe_add_option(opts_list, parsed_opts, target_key, source_key \\ nil) do
    source_key = source_key || target_key

    case Keyword.get(parsed_opts, source_key) do
      nil -> opts_list
      value -> Keyword.put(opts_list, target_key, value)
    end
  end

  defp show_key_stats(full_text, start_time, model_spec, prompt, chunk_count) do
    end_time = System.monotonic_time(:millisecond)
    response_time = end_time - start_time

    output_tokens = estimate_tokens(full_text)
    input_tokens = estimate_tokens(prompt)
    estimated_cost = calculate_cost(model_spec, input_tokens + output_tokens)

    IO.puts("Stats:")
    IO.puts("   Response time: #{response_time}ms")
    IO.puts("   Chunks received: #{chunk_count}")
    IO.puts("   Output tokens: #{output_tokens}")
    IO.puts("   Input tokens: #{input_tokens}")
    IO.puts("   Total tokens: #{input_tokens + output_tokens}")

    if estimated_cost > 0 do
      IO.puts("   Estimated cost: $#{Float.round(estimated_cost, 6)}")
    else
      IO.puts("   Estimated cost: Unknown")
    end
  end

  defp estimate_tokens(text) do
    max(1, div(String.length(text), 4))
  end

  defp calculate_cost(model_spec, tokens) do
    cost_per_million =
      cond do
        String.contains?(model_spec, "claude-3-haiku") -> 0.25
        String.contains?(model_spec, "claude-3-5-sonnet") -> 3.0
        String.contains?(model_spec, "claude-3-sonnet") -> 3.0
        String.contains?(model_spec, "claude-3-opus") -> 15.0
        String.contains?(model_spec, "gpt-4o-mini") -> 0.6
        String.contains?(model_spec, "gpt-4o") -> 2.4
        String.contains?(model_spec, "deepseek") -> 0.28
        # Groq is very affordable
        String.contains?(model_spec, "groq:") -> 0.1
        true -> 0.0
      end

    tokens / 1_000_000 * cost_per_million
  end
end

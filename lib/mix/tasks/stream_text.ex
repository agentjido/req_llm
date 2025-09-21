defmodule Mix.Tasks.ReqLlm.StreamText do
  @shortdoc "Stream text generation from any AI model"

  @moduledoc """
  Stream text generation from any supported AI model with real-time output.

  ## Usage

      mix req.llm.stream_text "Your prompt here" --model provider:model-name

  ## Examples

      # Stream from Groq
      mix req.llm.stream_text "Explain streaming APIs" --model groq:gemma2-9b-it

      # Stream from OpenAI with options
      mix req.llm.stream_text "Write a story" --model openai:gpt-4o --max-tokens 500 --temperature 0.8

  ## Options

      --model         Model specification (provider:model-name)
      --system        System prompt/message
      --max-tokens    Maximum tokens to generate
      --temperature   Sampling temperature (0.0-2.0)
      --log-level     Output verbosity: quiet, normal, verbose, debug
  """
  use Mix.Task

  alias Mix.Tasks.ReqLlm.Shared

  @preferred_cli_env ["req.llm.stream_text": :dev]
  @spec run([String.t()]) :: :ok | no_return()
  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:req_llm)

    {opts, args_list, _} = Shared.parse_args(args)

    case Shared.validate_prompt(args_list, "stream_text") do
      {:ok, prompt} ->
        model_spec = Keyword.get(opts, :model, "groq:gemma2-9b-it")
        log_level = Shared.parse_log_level(Keyword.get(opts, :log_level))
        quiet = log_level == :quiet
        verbose = log_level in [:verbose, :debug]
        metrics = log_level in [:verbose, :debug]

        if !quiet do
          IO.puts("Streaming from #{model_spec}")
          IO.puts("Prompt: #{prompt}")
          IO.puts("")
        end

        stream_opts = Shared.build_generate_opts(opts)
        start_time = System.monotonic_time(:millisecond)

        try do
          ReqLLM.stream_text(model_spec, prompt, stream_opts)
          |> Shared.handle_common_errors()
          |> handle_success(quiet, verbose, metrics, start_time, model_spec, prompt)
        rescue
          error -> Shared.handle_rescue_error(error)
        end

      {:error, :no_prompt} ->
        System.halt(1)
    end
  end

  defp handle_success({:ok, response}, quiet, verbose, metrics, start_time, model_spec, prompt) do
    if !quiet do
      IO.puts("Response:")
      IO.puts("   Model: #{response.model}")
      IO.puts("")
    end

    {full_text, chunk_count} = stream_response(response, quiet, verbose)

    if !quiet, do: IO.puts("\n")

    if metrics do
      response_with_chunk_count = Map.put(response, :chunk_count, chunk_count)

      Shared.show_stats(
        full_text,
        start_time,
        model_spec,
        prompt,
        response_with_chunk_count,
        :stream
      )
    end

    if !quiet, do: IO.puts("Streaming completed")
    :ok
  end

  defp stream_response(response, quiet, verbose) do
    response.stream
    |> Enum.reduce({[], 0}, fn chunk, {acc_chunks, count} ->
      count = count + 1

      cond do
        verbose ->
          IO.puts("[#{count}]: #{inspect(chunk)}")
          collect_text_chunk(chunk, acc_chunks, count)

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

            _ ->
              {acc_chunks, count}
          end

        true ->
          collect_text_chunk(chunk, acc_chunks, count)
      end
    end)
    |> then(fn {chunks, count} ->
      text = chunks |> Enum.reverse() |> Enum.join("")
      {text, count}
    end)
  end

  defp collect_text_chunk(%ReqLLM.StreamChunk{type: :content, text: text}, acc_chunks, count)
       when is_binary(text) do
    {[text | acc_chunks], count}
  end

  defp collect_text_chunk(_, acc_chunks, count), do: {acc_chunks, count}
end

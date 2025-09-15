defmodule Mix.Tasks.Req.Llm.StreamText do
  @shortdoc "Stream text generation from AI models"

  @moduledoc """
  Mix task for streaming text generation from AI models.

  Provides real-time streaming text generation with basic metrics.
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
          IO.puts("Usage: mix req.llm.stream_text \"Your prompt here\"")
          System.halt(1)
      end

    model_spec = Keyword.get(opts, :model, "anthropic:claude-3-haiku-20240307")
    quiet = Keyword.get(opts, :quiet, false)
    verbose = Keyword.get(opts, :verbose, false)
    metrics = Keyword.get(opts, :metrics, false)

    # Check for API key configuration
    provider = String.split(model_spec, ":") |> List.first()

    jido_key =
      case provider do
        "anthropic" -> :anthropic_api_key
        "openai" -> :openai_api_key
        "openrouter" -> :openrouter_api_key
        _ -> nil
      end

    if jido_key && !JidoKeys.get(jido_key) do
      IO.puts("⚠️  Warning: API key for #{provider} not found in JidoKeys keyring.")
      IO.puts("   Please set it with: JidoKeys.put(#{inspect(jido_key)}, \"your-api-key\")")
      IO.puts("")
    end

    if !quiet do
      IO.puts("🚀 Streaming from #{model_spec}")
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
      stream = ReqLLM.stream_text!(model_spec, prompt, stream_opts)

      if !quiet, do: IO.puts("Response:")

      chunks = Enum.to_list(stream)

      # Print each chunk - handle potential error tuples
      for {chunk, index} <- Enum.with_index(chunks, 1) do
        cond do
          verbose and not quiet ->
            IO.puts("[#{index}]: #{inspect(chunk)}")

          not quiet ->
            case chunk do
              {_status, _error} = error_tuple ->
                IO.puts("❌ Error in stream: #{inspect(error_tuple)}")

              chunk when is_binary(chunk) ->
                IO.write(chunk)

              other ->
                IO.puts("❌ Unexpected chunk type: #{inspect(other)}")
            end

          true ->
            :ok
        end
      end

      # Debug output for empty responses
      if Enum.empty?(chunks) and not quiet do
        IO.puts("⚠️ No chunks received from stream")
      end

      if !quiet, do: IO.puts("")

      if metrics do
        show_key_stats(chunks, start_time, model_spec, prompt)
      end

      if !quiet, do: IO.puts("✅ Completed")
      :ok
    rescue
      error ->
        IO.puts("❌ Error: #{inspect(error)}")
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

  defp show_key_stats(chunks, start_time, model_spec, prompt) do
    end_time = System.monotonic_time(:millisecond)
    response_time = end_time - start_time

    # Filter out non-string chunks and join
    string_chunks = Enum.filter(chunks, &is_binary/1)
    full_text = Enum.join(string_chunks, "")
    output_tokens = estimate_tokens(full_text)
    input_tokens = estimate_tokens(prompt)
    estimated_cost = calculate_cost(model_spec, input_tokens + output_tokens)

    IO.puts("📊 Stats:")
    IO.puts("   Response time: #{response_time}ms")
    IO.puts("   Output tokens: #{output_tokens}")
    IO.puts("   Estimated input tokens: #{input_tokens}")

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
        true -> 0.0
      end

    tokens / 1_000_000 * cost_per_million
  end
end

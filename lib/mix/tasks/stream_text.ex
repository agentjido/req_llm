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

      # Stream from Anthropic with system prompt and debug logging
      mix req.llm.stream_text "Analyze this code" --model anthropic:claude-3-sonnet --system "You are a code reviewer" --log-level debug

  ## Options

      --model         Model specification (provider:model-name)
      --system        System prompt/message
      --max-tokens    Maximum tokens to generate
      --temperature   Sampling temperature (0.0-2.0)
      --log-level     Output verbosity level: quiet, normal, verbose, debug (default: normal)
      --debug-dir     Directory to write debug trace files
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
          "log-level": :string,
          "debug-dir": :string
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
            "  mix req.llm.stream_text \"Write a poem\" --model openai:gpt-4o --temperature 0.9 --log-level verbose"
          )

          System.halt(1)
      end

    model_spec = Keyword.get(opts, :model, "groq:gemma2-9b-it")
    log_level = parse_log_level(Keyword.get(opts, :"log-level", "normal"))
    debug_dir = Keyword.get(opts, :"debug-dir")

    # Derive behavior flags from log level
    quiet = log_level == :quiet
    verbose = log_level in [:verbose, :debug]
    debug = log_level == :debug
    metrics = log_level in [:verbose, :debug]

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

    # Debug: Show context section
    if debug do
      debug_context(model_spec, prompt, stream_opts, opts)
    end

    start_time = System.monotonic_time(:millisecond)

    try do
      case ReqLLM.stream_text(model_spec, prompt, stream_opts) do
        {:ok, response} ->
          # Debug: Show request details  
          if debug do
            debug_request(response)
          end

          if !quiet do
            IO.puts("Response:")
            IO.puts("   Model: #{response.model}")
            IO.puts("")
          end

          # Debug: Show streaming timeline header
          if debug do
            IO.puts("=== DEBUG/STREAMING TIMELINE =============================")
            IO.puts("INDEX\tELAPSED\tTYPE\tBYTES\tPREVIEW")
          end

          {text_chunks, chunk_count} =
            response.stream
            |> Enum.reduce({[], 0}, fn chunk, {acc_chunks, count} ->
              count = count + 1

              # Debug: Log chunk details
              if debug do
                debug_chunk(chunk, count, start_time)
              end

              cond do
                verbose and not debug ->
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

          full_text = text_chunks |> Enum.reverse() |> Enum.join("")

          # Debug: Show response metadata
          if debug do
            IO.puts("=============================================================")
            debug_response_meta(response)
          end

          # Debug: Write debug files if requested
          if debug do
            write_debug_files(debug_dir, response, full_text)
          end

          if metrics do
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

  # Helper functions
  defp parse_log_level(level_string) do
    case String.downcase(level_string) do
      "quiet" ->
        :quiet

      "normal" ->
        :normal

      "verbose" ->
        :verbose

      "debug" ->
        :debug

      _ ->
        IO.puts("Warning: Unknown log level '#{level_string}'. Using 'normal'.")
        :normal
    end
  end

  # Debug helper functions
  defp debug_context(model_spec, prompt, stream_opts, opts) do
    env_vars = debug_env_vars()

    IO.puts("""
    === DEBUG/CONTEXT =========================================
    CLI Arguments:
      Model: #{model_spec}
      Prompt: #{inspect(prompt)}
      Stream Options: #{inspect(stream_opts, pretty: true)}
      All Options: #{inspect(Map.new(opts), pretty: true)}

    Environment Variables:
    #{env_vars}
    ============================================================
    """)
  end

  defp debug_env_vars do
    relevant_env_vars = [
      "ANTHROPIC_API_KEY",
      "OPENAI_API_KEY",
      "GROQ_API_KEY",
      "XAI_API_KEY",
      "GOOGLE_API_KEY",
      "OPENROUTER_API_KEY"
    ]

    relevant_env_vars
    |> Enum.map_join("\n", fn var ->
      case System.get_env(var) do
        nil -> "      #{var}: (not set)"
        _value -> "      #{var}: [REDACTED]"
      end
    end)
  end

  defp debug_request(response) do
    # Note: This assumes ReqLLM.Response has request field
    # May need to be adjusted based on actual response structure
    case Map.get(response, :request) do
      nil ->
        IO.puts("=== DEBUG/REQUEST (unavailable) =======================")
        IO.puts("Request details not available in response")
        IO.puts("========================================================")

      req ->
        headers = redact_sensitive_headers(req.headers || [])

        IO.puts("""
        === DEBUG/REQUEST =========================================
        #{String.upcase(to_string(req.method || "POST"))} #{req.url}
        Headers: #{inspect(headers, pretty: true)}
        Body: #{format_request_body(req.body)}
        ============================================================
        """)
    end
  end

  defp redact_sensitive_headers(headers) do
    Enum.map(headers, fn
      {key, _value} when key in ["authorization", "x-api-key", "api-key"] ->
        {key, "[REDACTED]"}

      header ->
        header
    end)
  end

  defp format_request_body(body) when is_map(body) do
    Jason.encode!(body, pretty: true)
  rescue
    _ -> inspect(body, pretty: true)
  end

  defp format_request_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
      {:error, _} -> body
    end
  end

  defp format_request_body(body) do
    inspect(body, pretty: true)
  end

  defp debug_chunk(chunk, index, start_time) do
    elapsed_ms = System.monotonic_time(:millisecond) - start_time

    {chunk_type, bytes, preview} = analyze_chunk(chunk)

    IO.puts("CHUNK\t#{index}\t#{elapsed_ms}ms\t#{chunk_type}\t#{bytes}B\t#{preview}")
  end

  defp analyze_chunk(%ReqLLM.StreamChunk{type: type, text: text}) when is_binary(text) do
    bytes = byte_size(text)
    preview = text |> String.slice(0, 40) |> inspect()
    {type, bytes, preview}
  end

  defp analyze_chunk(%ReqLLM.StreamChunk{type: type} = chunk) do
    chunk_binary = :erlang.term_to_binary(chunk)
    bytes = byte_size(chunk_binary)
    preview = chunk |> inspect() |> String.slice(0, 40)
    {type, bytes, preview}
  end

  defp analyze_chunk(chunk) do
    chunk_binary = :erlang.term_to_binary(chunk)
    bytes = byte_size(chunk_binary)
    preview = chunk |> inspect() |> String.slice(0, 40)
    {:unknown, bytes, preview}
  end

  defp debug_response_meta(response) do
    meta = extract_response_metadata(response)

    IO.puts("""
    === DEBUG/RESPONSE META ===================================
    #{inspect(meta, pretty: true)}
    ============================================================
    """)
  end

  defp extract_response_metadata(response) do
    %{
      model: Map.get(response, :model, "unknown"),
      usage: Map.get(response, :usage, "unavailable"),
      request_id: get_nested(response, [:metadata, :request_id], "unavailable"),
      provider_metadata: Map.get(response, :metadata, %{})
    }
  end

  defp get_nested(map, keys, default) do
    Enum.reduce(keys, map, fn key, acc ->
      case acc do
        %{} -> Map.get(acc, key, default)
        _ -> default
      end
    end)
  end

  defp write_debug_files(debug_dir, _response, _full_text) when is_nil(debug_dir), do: :ok

  defp write_debug_files(debug_dir, response, full_text) do
    File.mkdir_p!(debug_dir)

    # Write request details
    request_data = extract_request_data(response)
    request_path = Path.join(debug_dir, "request.json")
    File.write!(request_path, Jason.encode!(request_data, pretty: true))

    # Write response text
    response_path = Path.join(debug_dir, "response.txt")
    File.write!(response_path, full_text)

    # Write summary
    summary = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      model: Map.get(response, :model, "unknown"),
      text_length: String.length(full_text),
      metadata: Map.get(response, :metadata, %{})
    }

    summary_path = Path.join(debug_dir, "summary.json")
    File.write!(summary_path, Jason.encode!(summary, pretty: true))

    IO.puts("Debug files written to: #{debug_dir}")
  rescue
    error ->
      IO.puts("Failed to write debug files: #{inspect(error)}")
  end

  defp extract_request_data(response) do
    case Map.get(response, :request) do
      nil ->
        %{error: "request_not_available"}

      req ->
        %{
          url: req.url,
          method: req.method,
          headers: redact_sensitive_headers(req.headers || []),
          body: req.body
        }
    end
  end
end

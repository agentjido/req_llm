defmodule Mix.Tasks.ReqLlm.Gen do
  @shortdoc "Generate text or objects from any AI model"

  @moduledoc """
  Generate text or structured objects from any supported AI model with unified interface.

  This consolidated task combines text generation, object generation, streaming,
  and non-streaming capabilities into a single command. Use flags to control
  output format and streaming behavior.

  ## Usage

      mix req_llm.gen "Your prompt here" [options]

  ## Arguments

      prompt          The text prompt to send to the AI model (required)

  ## Options

      --model, -m MODEL       Model specification in format provider:model-name
                             Default: groq:gemma2-9b-it

      --system, -s SYSTEM     System prompt/message to set context for the AI

      --max-tokens TOKENS     Maximum number of tokens to generate
                             (integer, provider-specific limits apply)

      --temperature, -t TEMP  Sampling temperature for randomness (0.0-2.0)
                             Lower values = more focused, higher = more creative

      --stream                Stream output in real-time (default: false)
      --json                  Generate structured JSON object (default: text)

      --log-level, -l LEVEL   Output verbosity level:
                             quiet   - Only show generated content
                             normal  - Show model info and content (default)
                             verbose - Show timing and usage statistics
                             debug   - Show all internal details

  ## Examples

      # Basic text generation with default model
      mix req_llm.gen "Explain how neural networks work"

      # Streaming text from specific provider
      mix req_llm.gen "Write a story about space" \\
        --model openai:gpt-4o \\
        --system "You are a creative science fiction writer" \\
        --stream

      # Generate structured JSON object
      mix req_llm.gen "Create a user profile for John Smith, age 30, engineer in Seattle" \\
        --model openai:gpt-4o-mini \\
        --json

      # Streaming JSON generation with metrics
      mix req_llm.gen "Extract person info from this text" \\
        --model anthropic:claude-3-sonnet \\
        --json --stream \\
        --temperature 0.1 \\
        --log-level verbose

      # Quick generation without extra output
      mix req_llm.gen "What is 2+2?" --log-level quiet

  ## JSON Schema

  When using --json flag, objects are generated using a built-in person schema:

      {
        "name": "string (required) - Full name of the person",
        "age": "integer - Age in years",
        "occupation": "string - Job or profession",
        "location": "string - City or region where they live"
      }

  ## Supported Providers

      openai      - OpenAI models (GPT-4, GPT-3.5, etc.)
      anthropic   - Anthropic Claude models
      groq        - Groq models (fast inference)
      google      - Google Gemini models
      openrouter  - OpenRouter (access to multiple providers)
      xai         - xAI Grok models

  ## Environment Variables

  Most providers require API keys set as environment variables:

      OPENAI_API_KEY      - For OpenAI models
      ANTHROPIC_API_KEY   - For Anthropic models
      GOOGLE_API_KEY      - For Google models
      OPENROUTER_API_KEY  - For OpenRouter
      XAI_API_KEY         - For xAI models

  ## Output Modes

  ### Text Generation
  - Non-streaming: Complete response after generation finishes
  - Streaming: Real-time token display as they're generated

  ### JSON Generation
  - Non-streaming: Complete structured object after validation
  - Streaming: Incremental object updates (where supported)

  ## Capability Requirements

  Different modes require different model capabilities:
  - Text: No special requirements (all models)
  - JSON: Structured output support (varies by provider)
  - Streaming: Stream support (most models, varies by provider)

  ## Provider Compatibility

  Not all providers support all features equally:

      openai      - Excellent support for all modes
      anthropic   - Good support, tool-based JSON generation
      groq        - Fast streaming, limited JSON support
      google      - Experimental JSON/streaming support
      openrouter  - Depends on underlying model
      xai         - Basic support across modes
  """
  use Mix.Task

  require Logger

  @preferred_cli_env ["req_llm.gen": :dev]
  @spec run([String.t()]) :: :ok | no_return()
  @impl Mix.Task
  def run(args) do
    # Parse with additional switches for the consolidated task
    extra_switches = [stream: :boolean, json: :boolean]
    {opts, args_list, _} = parse_args(args, extra_switches)

    # Set logger level early, before starting the application
    log_level = parse_log_level(Keyword.get(opts, :log_level))
    logger_level = if log_level == :debug, do: :debug, else: :info
    Logger.configure(level: logger_level)

    Application.ensure_all_started(:req_llm)

    case validate_prompt(args_list, "gen") do
      {:ok, prompt} ->
        model_spec = Keyword.get(opts, :model, default_model())

        # Determine mode from flags
        streaming = Keyword.get(opts, :stream, false)
        json_mode = Keyword.get(opts, :json, false)

        # Validate model exists (basic validation only)
        # Skip strict capability validation since it's handled at the API level
        case validate_model_capabilities(model_spec, []) do
          {:ok, _metadata} ->
            execute_generation(model_spec, prompt, opts, log_level, streaming, json_mode)

          {:error, _error_msg} ->
            # For now, proceed anyway if model metadata isn't available
            # The actual API call will validate compatibility
            execute_generation(model_spec, prompt, opts, log_level, streaming, json_mode)
        end

      {:error, :no_prompt} ->
        System.halt(1)
    end
  end

  # Route to appropriate generation function based on mode
  defp execute_generation(model_spec, prompt, opts, log_level, streaming, json_mode) do
    case {streaming, json_mode} do
      {false, false} ->
        execute_text_generation(model_spec, prompt, opts, log_level)

      {true, false} ->
        execute_streaming_text(model_spec, prompt, opts, log_level)

      {false, true} ->
        execute_object_generation(model_spec, prompt, opts, log_level)

      {true, true} ->
        execute_streaming_object(model_spec, prompt, opts, log_level)
    end
  end

  # Standard text generation (non-streaming)
  defp execute_text_generation(model_spec, prompt, opts, log_level) do
    quiet = log_level == :quiet
    debug = log_level == :debug

    if not quiet do
      IO.puts(
        "#{model_spec} → \"#{String.slice(prompt, 0, 50)}#{if String.length(prompt) > 50, do: "...", else: ""}\"\n"
      )
    end

    generate_opts = build_generate_opts(opts)
    start_time = System.monotonic_time(:millisecond)

    try do
      ReqLLM.Generation.generate_text(model_spec, prompt, generate_opts)
      |> handle_common_errors()
      |> handle_text_success(quiet, debug, start_time, model_spec, prompt)
    rescue
      error -> handle_rescue_error(error)
    end
  end

  # Streaming text generation
  defp execute_streaming_text(model_spec, prompt, opts, log_level) do
    quiet = log_level == :quiet
    debug = log_level == :debug

    if not quiet do
      IO.puts(
        "#{model_spec} → \"#{String.slice(prompt, 0, 50)}#{if String.length(prompt) > 50, do: "...", else: ""}\"\n"
      )
    end

    stream_opts = build_generate_opts(opts)
    start_time = System.monotonic_time(:millisecond)

    try do
      ReqLLM.stream_text(model_spec, prompt, stream_opts)
      |> handle_common_errors()
      |> handle_streaming_text_success(quiet, debug, start_time, model_spec, prompt)
    rescue
      error -> handle_rescue_error(error)
    end
  end

  # Object generation (non-streaming)
  defp execute_object_generation(model_spec, prompt, opts, log_level) do
    quiet = log_level == :quiet
    debug = log_level == :debug
    metrics = log_level in [:verbose, :debug]

    if not quiet do
      IO.puts("Generating object from #{model_spec}")
      IO.puts("Prompt: #{prompt}")
      IO.puts("")
    end

    schema = default_object_schema()
    generate_opts = build_generate_opts(opts)
    start_time = System.monotonic_time(:millisecond)

    try do
      ReqLLM.Generation.generate_object(model_spec, prompt, schema, generate_opts)
      |> handle_common_errors()
      |> handle_object_success(quiet, debug, metrics, start_time, model_spec, prompt)
    rescue
      error -> handle_rescue_error(error)
    end
  end

  # Streaming object generation
  defp execute_streaming_object(model_spec, prompt, opts, log_level) do
    quiet = log_level == :quiet
    debug = log_level == :debug
    metrics = log_level in [:verbose, :debug]

    if not quiet do
      IO.puts("Streaming object from #{model_spec}")
      IO.puts("Prompt: #{prompt}")
      IO.puts("")
    end

    schema = default_object_schema()
    generate_opts = build_generate_opts(opts)
    start_time = System.monotonic_time(:millisecond)

    try do
      ReqLLM.Generation.stream_object(model_spec, prompt, schema, generate_opts)
      |> handle_common_errors()
      |> handle_streaming_object_success(quiet, debug, metrics, start_time, model_spec, prompt)
    rescue
      error -> handle_rescue_error(error)
    end
  end

  # Success handlers for different generation modes

  defp handle_text_success({:ok, response}, quiet, debug, start_time, model_spec, prompt) do
    text = ReqLLM.Response.text(response)

    if quiet do
      IO.puts(text)
    else
      IO.puts(text)
      IO.puts("")
      show_stats(text, start_time, model_spec, prompt, response, :text, debug)
    end

    :ok
  end

  defp handle_streaming_text_success(
         {:ok, response},
         quiet,
         debug,
         start_time,
         model_spec,
         prompt
       ) do
    {full_text, chunk_count} = stream_text_response(response, quiet, debug)

    if not quiet do
      IO.puts("")
      response_with_chunk_count = Map.put(response, :chunk_count, chunk_count)

      show_stats(
        full_text,
        start_time,
        model_spec,
        prompt,
        response_with_chunk_count,
        :stream,
        debug
      )
    end

    :ok
  end

  defp handle_object_success(
         {:ok, response},
         quiet,
         debug,
         metrics,
         start_time,
         model_spec,
         prompt
       ) do
    if debug, do: debug_request(response)

    generated_object = ReqLLM.Response.object(response)

    if debug do
      IO.puts("=== FULL RESPONSE STRUCTURE ===========================")
      IO.puts(inspect(response, pretty: true, limit: :infinity))
      IO.puts("========================================================")
      IO.puts("")
    end

    if quiet do
      IO.puts(Jason.encode!(generated_object, pretty: true))
    else
      IO.puts("Response:")
      IO.puts("   Model: #{response.model}")
      IO.puts("")
      IO.puts("Generated Object:")
      IO.puts(Jason.encode!(generated_object, pretty: true))
      IO.puts("")
    end

    if debug, do: debug_response_meta(response)

    if metrics do
      show_object_stats(generated_object, start_time, model_spec, prompt, response)
    end

    if not quiet, do: IO.puts("Object generation completed")
    :ok
  end

  defp handle_streaming_object_success(
         {:ok, response},
         quiet,
         debug,
         metrics,
         start_time,
         model_spec,
         prompt
       ) do
    if debug, do: debug_request(response)

    if not quiet do
      IO.puts("Response:")
      IO.puts("   Model: #{response.model}")
      IO.puts("")
    end

    if debug do
      IO.puts("=== FULL RESPONSE STRUCTURE ===========================")
      IO.puts(inspect(response, pretty: true, limit: :infinity))
      IO.puts("========================================================")
      IO.puts("")
    end

    if not quiet do
      IO.puts("Streaming Object:")
    end

    # Stream the object and collect final result
    final_object = stream_object_response(response, quiet, debug)

    if quiet do
      IO.puts(Jason.encode!(final_object, pretty: true))
    else
      IO.puts("")
      IO.puts("Final Object:")
      IO.puts(Jason.encode!(final_object, pretty: true))
      IO.puts("")
    end

    if debug, do: debug_response_meta(response)

    if metrics do
      show_object_stats(final_object, start_time, model_spec, prompt, response)
    end

    if not quiet, do: IO.puts("Object streaming completed")
    :ok
  end

  # Streaming helpers

  defp stream_text_response(response, quiet, verbose) do
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

  defp stream_object_response(response, quiet, debug) do
    # Debug: First let's see what's in the raw stream
    _raw_chunks =
      if debug do
        IO.puts("=== DEBUG/RAW STREAM CHUNKS ===========================")
        chunks = Enum.to_list(response.stream)
        IO.puts("Total chunks received: #{length(chunks)}")

        chunks
        |> Enum.with_index()
        |> Enum.each(fn {chunk, index} ->
          IO.puts("Chunk #{index + 1}: #{inspect(chunk, pretty: true, limit: :infinity)}")
          # Extra debug for tool_call chunks
          if chunk.type == :tool_call do
            IO.puts("  Tool name: #{inspect(chunk.name)}")

            IO.puts(
              "  Tool arguments: #{inspect(chunk.arguments, pretty: true, limit: :infinity)}"
            )

            IO.puts(
              "  Chunk metadata: #{inspect(chunk.metadata, pretty: true, limit: :infinity)}"
            )
          end
        end)

        chunks
      else
        Enum.to_list(response.stream)
      end

    # Stream the object and collect chunks for analysis
    object_stream = ReqLLM.Response.object_stream(response)

    if debug do
      IO.puts("=== DEBUG/FILTERED OBJECT STREAM =====================")
    end

    stream_and_collect_object(object_stream, quiet)
  end

  defp stream_and_collect_object(object_stream, quiet) do
    object_stream
    |> Enum.reduce(%{}, fn chunk, acc ->
      if not quiet do
        IO.puts("Filtered chunk: #{inspect(chunk, pretty: true, limit: :infinity)}")
      end

      # For object streaming, chunks represent partial object updates
      case chunk do
        %{} = object_part ->
          Map.merge(acc, object_part)

        _ ->
          acc
      end
    end)
  end

  defp collect_text_chunk(%ReqLLM.StreamChunk{type: :content, text: text}, acc_chunks, count)
       when is_binary(text) do
    {[text | acc_chunks], count}
  end

  defp collect_text_chunk(_, acc_chunks, count), do: {acc_chunks, count}

  # Consolidated utility functions from shared.ex

  @common_switches [
    model: :string,
    system: :string,
    max_tokens: :integer,
    temperature: :float,
    log_level: :string,
    debug_dir: :string
  ]

  @common_aliases [
    m: :model,
    s: :system,
    t: :temperature,
    l: :log_level,
    d: :debug_dir
  ]

  defp parse_args(args, extra_switches) do
    switches = Keyword.merge(@common_switches, extra_switches)
    aliases = @common_aliases

    OptionParser.parse(args, switches: switches, aliases: aliases)
  end

  defp validate_prompt(args_list, task_name) do
    case args_list do
      [prompt | _] ->
        {:ok, prompt}

      [] ->
        show_usage(task_name)
        {:error, :no_prompt}
    end
  end

  defp show_usage(task_name) do
    examples =
      case task_name do
        "gen" ->
          [
            ~s(  mix req_llm.gen "Explain APIs" --model groq:gemma2-9b-it),
            ~s(  mix req_llm.gen "Write a story" --model openai:gpt-4o --stream),
            ~s(  mix req_llm.gen "Generate user profile" --model openai:gpt-4o-mini --json),
            ~s(  mix req_llm.gen "Extract person info" --model anthropic:claude-3-sonnet --json --stream)
          ]
      end

    case task_name do
      "gen" ->
        IO.puts(
          ~s(Usage: mix req_llm.gen "Your prompt here" [--stream] [--json] --model provider:model-name)
        )
    end

    IO.puts("")
    IO.puts("Examples:")
    Enum.each(examples, &IO.puts/1)
  end

  defp parse_log_level(level_string) do
    case String.downcase(level_string || "normal") do
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

  defp build_generate_opts(opts) do
    []
    |> maybe_add_option(opts, :system_prompt, :system)
    |> maybe_add_option(opts, :max_tokens)
    |> maybe_add_option(opts, :temperature)
    |> Enum.reject(fn {_key, val} -> is_nil(val) end)
  end

  defp default_object_schema do
    [
      name: [type: :string, required: true, doc: "Full name of the person"],
      age: [type: :pos_integer, doc: "Age in years"],
      occupation: [type: :string, doc: "Job or profession"],
      location: [type: :string, doc: "City or region where they live"]
    ]
  end

  defp handle_common_errors({:error, %ReqLLM.Error.Invalid.Provider{provider: provider}}) do
    IO.puts(
      "Error: Unknown provider '#{provider}'. Please check that the provider is supported and properly configured."
    )

    IO.puts("Available providers: openai, groq, xai (others may require additional setup)")
    System.halt(1)
  end

  defp handle_common_errors({:error, %ReqLLM.Error.Invalid.Parameter{parameter: param}}) do
    IO.puts("Error: #{param}")
    System.halt(1)
  end

  defp handle_common_errors({:error, %ReqLLM.Error.API.Request{reason: reason, status: status}})
       when not is_nil(status) do
    IO.puts("API Error (#{status}): #{reason}")
    System.halt(1)
  end

  defp handle_common_errors({:error, %ReqLLM.Error.API.Request{reason: reason}}) do
    IO.puts("API Error: #{reason}")
    System.halt(1)
  end

  defp handle_common_errors({:error, error}) do
    IO.puts("Operation failed: #{format_error(error)}")
    System.halt(1)
  end

  defp handle_common_errors({:ok, result}), do: {:ok, result}

  @spec handle_rescue_error(any()) :: no_return()
  defp handle_rescue_error(%UndefinedFunctionError{module: nil, function: :prepare_request}) do
    IO.puts(
      "Error: Provider not properly configured or not available. Please check your model specification."
    )

    System.halt(1)
  end

  defp handle_rescue_error(%UndefinedFunctionError{} = error) do
    IO.puts("Unexpected error: #{format_error(error)}")
    System.halt(1)
  end

  defp handle_rescue_error(error) do
    IO.puts("Unexpected error: #{format_error(error)}")
    System.halt(1)
  end

  defp show_stats(content, start_time, model_spec, prompt, response, type, debug) do
    end_time = System.monotonic_time(:millisecond)
    response_time = end_time - start_time

    input_tokens = get_nested(response, [:usage, :input_tokens], 0)
    output_tokens = get_nested(response, [:usage, :output_tokens], 0)
    estimated_cost = calculate_cost_from_registry(model_spec, input_tokens, output_tokens)

    # Clean, one-line stats format
    cost_display =
      if estimated_cost > 0 do
        "$#{:erlang.float_to_binary(estimated_cost, decimals: 6)}"
      else
        "unknown"
      end

    IO.puts(
      "Stats: #{response_time}ms • #{input_tokens + output_tokens} tokens (#{input_tokens}→#{output_tokens}) • #{cost_display}"
    )

    if debug do
      case type do
        :text ->
          output_tokens_est = estimate_tokens(content)
          input_tokens_est = estimate_tokens(prompt)
          IO.puts("   Debug - Output tokens: #{output_tokens} (est: #{output_tokens_est})")
          IO.puts("   Debug - Input tokens: #{input_tokens} (est: #{input_tokens_est})")

        :object ->
          object_json = Jason.encode!(content)
          object_size = byte_size(object_json)
          field_count = count_fields(content)
          IO.puts("   Debug - Object size: #{object_size} bytes")
          IO.puts("   Debug - Field count: #{field_count}")

        :stream ->
          chunk_count = Map.get(response, :chunk_count, 0)
          IO.puts("   Debug - Chunks received: #{chunk_count}")
      end
    end
  end

  defp show_object_stats(object, start_time, model_spec, _prompt, response) do
    end_time = System.monotonic_time(:millisecond)
    response_time = end_time - start_time

    input_tokens = get_nested(response, [:usage, :input_tokens], 0)
    output_tokens = get_nested(response, [:usage, :output_tokens], 0)

    # Estimate object complexity
    object_json = Jason.encode!(object)
    object_size = byte_size(object_json)
    field_count = count_fields(object)

    estimated_cost = calculate_cost_from_registry(model_spec, input_tokens, output_tokens)

    IO.puts("   Response time: #{response_time}ms")
    IO.puts("   Object size: #{object_size} bytes")
    IO.puts("   Field count: #{field_count}")
    IO.puts("   Input tokens: #{input_tokens}")
    IO.puts("   Output tokens: #{output_tokens}")
    IO.puts("   Total tokens: #{input_tokens + output_tokens}")

    if estimated_cost > 0 do
      IO.puts("   Estimated cost: $#{:erlang.float_to_binary(estimated_cost, decimals: 6)}")
    else
      IO.puts("   Estimated cost: Unknown")
    end
  end

  defp debug_request(response) do
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

  defp validate_model_capabilities(model_spec, required_capabilities) do
    case ReqLLM.Model.Metadata.load_full_metadata(model_spec) do
      {:ok, metadata} ->
        # Check if all required capabilities are supported
        supported = get_model_capabilities(metadata)

        case check_capabilities(required_capabilities, supported) do
          :ok ->
            {:ok, metadata}

          {:missing, missing_caps} ->
            {:error,
             "Model '#{model_spec}' does not support required capabilities: #{Enum.join(missing_caps, ", ")}. Supported: #{Enum.join(supported, ", ")}"}
        end

      {:error, _} ->
        # If we can't load metadata, assume model is valid (fallback to existing behavior)
        # This maintains backward compatibility when model registry is incomplete
        {:ok, nil}
    end
  end

  defp calculate_cost_from_registry(model_spec, input_tokens, output_tokens) do
    case ReqLLM.Model.Metadata.load_full_metadata(model_spec) do
      {:ok, metadata} ->
        case extract_pricing(metadata) do
          {:ok, input_cost, output_cost} ->
            input_tokens / 1_000_000 * input_cost + output_tokens / 1_000_000 * output_cost

          {:error, _} ->
            # Fallback to hardcoded calculation
            calculate_cost(model_spec, input_tokens + output_tokens)
        end

      {:error, _} ->
        # Fallback to hardcoded calculation
        calculate_cost(model_spec, input_tokens + output_tokens)
    end
  end

  defp default_model do
    Application.get_env(:req_llm, :default_model, "groq:gemma2-9b-it")
  end

  # Private helper functions

  defp maybe_add_option(opts_list, parsed_opts, target_key, source_key \\ nil) do
    source_key = source_key || target_key

    case Keyword.get(parsed_opts, source_key) do
      nil -> opts_list
      value -> Keyword.put(opts_list, target_key, value)
    end
  end

  defp estimate_tokens(text), do: max(1, div(String.length(text), 4))

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
        String.contains?(model_spec, "groq:") -> 0.1
        true -> 0.0
      end

    tokens / 1_000_000 * cost_per_million
  end

  defp count_fields(obj) when is_map(obj) do
    Enum.reduce(obj, 0, fn {_key, value}, acc ->
      acc + 1 + count_fields(value)
    end)
  end

  defp count_fields(obj) when is_list(obj) do
    Enum.reduce(obj, 0, fn item, acc ->
      acc + count_fields(item)
    end)
  end

  defp count_fields(_), do: 0

  defp get_nested(map, keys, default) do
    Enum.reduce(keys, map, fn key, acc ->
      case acc do
        %{} -> Map.get(acc, key, default)
        _ -> default
      end
    end)
  end

  defp format_error(%{__struct__: _} = error), do: Exception.message(error)
  defp format_error(error), do: inspect(error)

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

  defp get_model_capabilities(metadata) do
    # Look for capabilities in various possible formats
    capabilities =
      Map.get(metadata, "capabilities") ||
        Map.get(metadata, :capabilities) ||
        Map.get(metadata, "supports") ||
        Map.get(metadata, :supports) ||
        []

    # Convert to normalized list of atoms
    capabilities
    |> Enum.map(fn
      cap when is_binary(cap) -> String.to_atom(cap)
      cap when is_atom(cap) -> cap
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp check_capabilities(required, supported) do
    missing = Enum.reject(required, &(&1 in supported))

    case missing do
      [] -> :ok
      _ -> {:missing, Enum.map(missing, &to_string/1)}
    end
  end

  defp extract_pricing(metadata) do
    pricing =
      Map.get(metadata, "pricing") ||
        Map.get(metadata, :pricing) ||
        Map.get(metadata, "cost") ||
        Map.get(metadata, :cost)

    case pricing do
      %{"input" => input, "output" => output} when is_number(input) and is_number(output) ->
        {:ok, input, output}

      %{:input => input, :output => output} when is_number(input) and is_number(output) ->
        {:ok, input, output}

      _ ->
        {:error, :pricing_not_found}
    end
  end
end

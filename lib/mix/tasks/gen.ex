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
                              Default: openai:gpt-4o-mini

      --system, -s SYSTEM     System prompt/message to set context for the AI

      --max-tokens TOKENS     Maximum number of tokens to generate
                             (integer, provider-specific limits apply)

      --temperature, -t TEMP  Sampling temperature for randomness (0.0-2.0)
                             Lower values = more focused, higher = more creative

      --stream                Stream output in real-time (default: true)
      --no-stream             Disable streaming (non-streaming mode)
      --json                  Generate structured JSON object (default: text)

      --log-level, -l LEVEL   Output verbosity level:
                             quiet   - Only show generated content
                             normal  - Show model info and content (default)
                             verbose - Show timing and usage statistics
                             debug   - Show all internal details

  ## Examples

      # Basic text generation (streams by default)
      mix req_llm.gen "Explain how neural networks work"

      # Text generation with specific provider and system prompt
      mix req_llm.gen "Write a story about space" \\
        --model openai:gpt-4o \\
        --system "You are a creative science fiction writer"

      # Generate with GPT-5 and high reasoning effort
      mix req_llm.gen "Solve this complex math problem step by step" \\
        --model openai:gpt-5-mini \\
        --reasoning-effort high

      # Generate structured JSON object (streams by default)
      mix req_llm.gen "Create a user profile for John Smith, age 30, engineer in Seattle" \\
        --model openai:gpt-4o-mini \\
        --json

      # JSON generation with metrics (streams by default)
      mix req_llm.gen "Extract person info from this text" \\
        --model anthropic:claude-3-sonnet \\
        --json \\
        --temperature 0.1 \\
        --log-level debug

      # Non-streaming mode (waits for complete response)
      mix req_llm.gen "What is 2+2?" --no-stream

      # Quick generation without extra output (streams by default)
      mix req_llm.gen "What is 2+2?" --log-level warning

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

  ## Configuration

  The default model can be configured in your application config:

      # config/config.exs
      config :req_llm, default_model: "openai:gpt-4o-mini"

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
  @log_levels [:warning, :info, :debug]

  @spec run([String.t()]) :: no_return()
  @impl Mix.Task
  def run(args) do
    extra_switches = [
      stream: :boolean,
      no_stream: :boolean,
      json: :boolean,
      reasoning_effort: :string,
      schema: :string
    ]

    {opts, args_list, _} = parse_args(args, extra_switches)

    log_level = parse_log_level(Keyword.get(opts, :log_level))
    Logger.configure(level: if(log_level == :debug, do: :debug, else: :warning))

    Application.ensure_all_started(:req_llm)

    case validate_prompt(args_list, "gen") do
      {:ok, prompt} ->
        model_spec = Keyword.get(opts, :model, default_model())

        case validate_model_spec(model_spec) do
          {:ok, _model} ->
            streaming =
              cond do
                Keyword.get(opts, :no_stream, false) -> false
                Keyword.has_key?(opts, :stream) -> Keyword.get(opts, :stream, true)
                true -> true
              end

            json_mode = Keyword.get(opts, :json, false)

            mode =
              {if(json_mode, do: :json, else: :text), if(streaming, do: :stream, else: :full)}

            execute_generation(mode, model_spec, prompt, opts, log_level)

          {:error, error_type} ->
            handle_validation_error(error_type, model_spec)
            System.halt(1)
        end

      {:error, :no_prompt} ->
        System.halt(1)
    end
  end

  # Unified execution with mode dispatch
  defp execute_generation(mode, model_spec, prompt, opts, log_level) do
    {call_fun, success_handler} = mode_dispatcher(mode)

    show_banner(mode, model_spec, prompt, log_level)

    schema = if match?({:json, _}, mode), do: resolve_schema(opts)
    opts = build_generate_opts(opts)
    start_time = System.monotonic_time(:millisecond)

    call_args =
      case mode do
        {:json, _} -> [model_spec, prompt, schema, opts]
        _ -> [model_spec, prompt, opts]
      end

    case apply(call_fun, call_args) do
      {:ok, result} ->
        success_handler.(result, log_level, model_spec, prompt, start_time)

      {:error, error} ->
        handle_generation_error(error, model_spec, log_level)
        System.halt(1)
    end
  rescue
    error ->
      error_message = format_error(error)

      if api_key_missing_error?(error_message) do
        handle_missing_api_key_error(error_message, model_spec, log_level)
      else
        log_puts("Unexpected error: #{error_message}", :warning, log_level)
      end

      System.halt(1)
  end

  # Mode dispatcher - maps mode tuples to API functions and handlers
  defp mode_dispatcher(mode) do
    case mode do
      {:text, :full} ->
        {&ReqLLM.Generation.generate_text/3, &handle_text_result/5}

      {:text, :stream} ->
        {&ReqLLM.Generation.stream_text/3, &handle_stream_text_result/5}

      {:json, :full} ->
        {&ReqLLM.Generation.generate_object/4, &handle_object_result/5}

      {:json, :stream} ->
        {&ReqLLM.Generation.stream_object/4, &handle_stream_object_result/5}
    end
  end

  # Unified banner display
  defp show_banner({_content_type, _stream_type}, _model_spec, _prompt, log_level)
       when log_level == :warning do
    :ok
  end

  defp show_banner({content_type, _stream_type}, model_spec, prompt, log_level) do
    prompt_preview = String.slice(prompt, 0, 50)
    prompt_suffix = if String.length(prompt) > 50, do: "...", else: ""

    case content_type do
      :text ->
        log_puts("#{model_spec} → \"#{prompt_preview}#{prompt_suffix}\"\n", :info, log_level)

      :json ->
        log_puts("Generating object from #{model_spec}", :info, log_level)
        log_puts("Prompt: #{prompt}", :info, log_level)
        log_puts("", :info, log_level)
    end
  end

  # Result handlers
  defp handle_text_result(response, log_level, model_spec, prompt, start_time) do
    text = ReqLLM.Response.text(response)
    IO.puts(text)
    show_text_stats(text, start_time, model_spec, prompt, response, log_level)
  end

  defp handle_stream_text_result(stream_response, log_level, model_spec, prompt, start_time) do
    {accumulated_text, reasoning_text} =
      stream_response.stream
      |> Enum.reduce({"", ""}, fn chunk, {text_acc, reasoning_acc} ->
        case chunk.type do
          :content ->
            text = chunk.text || ""
            IO.write(text)
            {text_acc <> text, reasoning_acc}

          :thinking ->
            reasoning = chunk.text || ""
            # Show reasoning tokens in a different color/style if log level allows
            if log_level != :warning do
              IO.write(IO.ANSI.faint() <> IO.ANSI.cyan() <> reasoning <> IO.ANSI.reset())
            end

            {text_acc, reasoning_acc <> reasoning}

          _ ->
            {text_acc, reasoning_acc}
        end
      end)

    IO.puts("")

    # Show reasoning token count in the stats if we have any
    if reasoning_text != "" and log_level != :warning do
      reasoning_tokens = estimate_tokens(reasoning_text)
      IO.puts("#{IO.ANSI.faint()}[Reasoning: #{reasoning_tokens} tokens]#{IO.ANSI.reset()}")
    end

    show_text_stats(
      accumulated_text,
      start_time,
      model_spec,
      prompt,
      stream_response,
      log_level
    )
  end

  defp handle_object_result(response, log_level, model_spec, prompt, start_time) do
    object = Map.get(response, :object, %{})

    case Jason.encode(object, pretty: true) do
      {:ok, json} -> IO.puts(json)
      {:error, _} -> IO.puts(inspect(object, pretty: true))
    end

    show_object_stats(object, start_time, model_spec, prompt, response, log_level)
  end

  defp handle_stream_object_result(stream, log_level, model_spec, prompt, start_time) do
    final_object =
      stream
      |> Enum.reduce(%{}, fn chunk, acc ->
        partial = Map.get(chunk, :object, %{})
        Map.merge(acc, partial)
      end)

    case Jason.encode(final_object, pretty: true) do
      {:ok, json} -> IO.puts(json)
      {:error, _} -> IO.puts(inspect(final_object, pretty: true))
    end

    response = %{object: final_object, chunk_count: Enum.count(stream)}
    show_object_stats(final_object, start_time, model_spec, prompt, response, log_level)
  end

  # Statistics display
  defp show_text_stats(_text, _start_time, _model_spec, _prompt, _response_data, :warning),
    do: :ok

  defp show_text_stats(_text, start_time, _model_spec, _prompt, response_data, :info) do
    response_time = System.monotonic_time(:millisecond) - start_time

    usage =
      case response_data do
        %{usage: usage} -> usage
        %ReqLLM.StreamResponse{} -> ReqLLM.StreamResponse.usage(response_data)
        _ -> nil
      end

    case usage do
      %{input_tokens: input, output_tokens: output, total_cost: cost} = usage ->
        cost_str = :erlang.float_to_binary(cost, decimals: 6)

        reasoning_info =
          if Map.get(usage, :reasoning_tokens, 0) > 0 do
            " (#{usage.reasoning_tokens} reasoning)"
          else
            ""
          end

        IO.puts(
          "\n#{response_time}ms • #{input}→#{output} tokens#{reasoning_info} • ~$#{cost_str}"
        )

      %{input_tokens: input, output_tokens: output} = usage ->
        reasoning_info =
          if Map.get(usage, :reasoning_tokens, 0) > 0 do
            " (#{usage.reasoning_tokens} reasoning)"
          else
            ""
          end

        IO.puts("\n#{response_time}ms • #{input}→#{output} tokens#{reasoning_info}")

      _ ->
        IO.puts("\n#{response_time}ms • streaming")
    end
  end

  defp show_text_stats(text, start_time, _model_spec, _prompt, response_data, log_level) do
    response_time = System.monotonic_time(:millisecond) - start_time
    char_count = String.length(text || "")
    word_count = (text || "") |> String.split(~r/\s+/, trim: true) |> length()

    log_puts("   Response time: #{response_time}ms", :debug, log_level)
    log_puts("   Characters: #{char_count}", :debug, log_level)
    log_puts("   Words: #{word_count}", :debug, log_level)

    # Try to extract usage from different response types
    usage =
      case response_data do
        %{usage: usage} -> usage
        %ReqLLM.StreamResponse{} -> ReqLLM.StreamResponse.usage(response_data)
        _ -> nil
      end

    # Show usage data from response if available
    case usage do
      %{input_tokens: input, output_tokens: output} = usage ->
        log_puts("   Input tokens: #{input}", :debug, log_level)
        log_puts("   Output tokens: #{output}", :debug, log_level)

        reasoning_tokens = Map.get(usage, :reasoning_tokens, 0)

        if reasoning_tokens > 0 do
          log_puts("   Reasoning tokens: #{reasoning_tokens}", :debug, log_level)
        end

        log_puts("   Total tokens: #{input + output}", :debug, log_level)

        if Map.has_key?(usage, :total_cost) do
          cost = :erlang.float_to_binary(usage.total_cost, decimals: 6)
          log_puts("   Cost: $#{cost}", :debug, log_level)
          # credo:disable-for-next-line Credo.Check.Warning.IoInspect
          IO.inspect(usage, label: "DEBUG: Full usage object")
        end

      _ ->
        estimated_tokens = estimate_tokens(text || "")
        log_puts("   Estimated tokens: #{estimated_tokens}", :debug, log_level)
    end

    # Show chunk count for streaming responses
    case response_data do
      %ReqLLM.StreamResponse{stream: stream} ->
        chunk_count = Enum.count(stream)
        log_puts("   Chunks received: #{chunk_count}", :debug, log_level)

      %{chunk_count: chunk_count} ->
        log_puts("   Chunks received: #{chunk_count}", :debug, log_level)

      _ ->
        :ok
    end
  end

  defp show_object_stats(_object, _start_time, _model_spec, _prompt, _response, log_level)
       when log_level not in [:debug] do
    :ok
  end

  defp show_object_stats(object, start_time, model_spec, _prompt, response, log_level) do
    response_time = System.monotonic_time(:millisecond) - start_time
    input_tokens = get_nested(response, [:usage, :input_tokens], 0)
    output_tokens = get_nested(response, [:usage, :output_tokens], 0)

    object_json = Jason.encode!(object)
    object_size = byte_size(object_json)
    field_count = count_fields(object)
    estimated_cost = calculate_estimated_cost(model_spec, input_tokens, output_tokens)

    log_puts("   Response time: #{response_time}ms", :debug, log_level)
    log_puts("   Object size: #{object_size} bytes", :debug, log_level)
    log_puts("   Field count: #{field_count}", :debug, log_level)
    log_puts("   Input tokens: #{input_tokens}", :debug, log_level)
    log_puts("   Output tokens: #{output_tokens}", :debug, log_level)
    log_puts("   Total tokens: #{input_tokens + output_tokens}", :debug, log_level)

    cost_display =
      if estimated_cost > 0 do
        "$#{:erlang.float_to_binary(estimated_cost, decimals: 6)}"
      else
        "Unknown"
      end

    log_puts("   Estimated cost: #{cost_display}", :debug, log_level)

    if Map.has_key?(response, :chunk_count) do
      log_puts("   Chunks received: #{response.chunk_count}", :debug, log_level)
    end
  end

  # Centralized logging helper
  defp log_puts(message, min_level, current_level) do
    if level_index(current_level) >= level_index(min_level) do
      IO.puts(message)
    end
  end

  defp level_index(level) do
    Enum.find_index(@log_levels, &(&1 == level)) || 1
  end

  # Configuration and validation helpers
  defp default_model do
    Application.get_env(:req_llm, :default_model, "openai:gpt-4o-mini")
  end

  defp default_object_schema do
    [
      name: [type: :string, required: true, doc: "Full name of the person"],
      age: [type: :pos_integer, doc: "Age in years"],
      occupation: [type: :string, doc: "Job or profession"],
      location: [type: :string, doc: "City or region where they live"]
    ]
  end

  defp build_generate_opts(opts) do
    base_opts =
      []
      |> maybe_add_option(opts, :system)
      |> maybe_add_option(opts, :max_tokens)
      |> maybe_add_option(opts, :temperature)

    # Add reasoning_effort as a provider option
    case Keyword.get(opts, :reasoning_effort) do
      nil ->
        base_opts

      effort when effort in ["minimal", "low", "medium", "high"] ->
        effort_atom = String.to_atom(effort)
        provider_options = [reasoning_effort: effort_atom]
        Keyword.put(base_opts, :provider_options, provider_options)

      invalid_effort ->
        IO.puts(
          "Warning: Invalid reasoning effort '#{invalid_effort}'. Must be minimal, low, medium, or high. Ignoring."
        )

        base_opts
    end
  end

  defp maybe_add_option(opts_list, parsed_opts, key) do
    case Keyword.get(parsed_opts, key) do
      nil -> opts_list
      value -> Keyword.put(opts_list, key, value)
    end
  end

  defp maybe_put(list, _k, nil), do: list
  defp maybe_put(list, k, v), do: Keyword.put(list, k, v)

  # Cost calculation using model metadata system
  defp calculate_estimated_cost(model_spec, input_tokens, output_tokens) do
    case ReqLLM.model(model_spec) do
      {:ok, %LLMDB.Model{cost: cost_map}} when is_map(cost_map) ->
        input_rate = cost_map[:input] || cost_map["input"] || 0.0
        output_rate = cost_map[:output] || cost_map["output"] || 0.0

        input_cost = input_tokens / 1_000_000 * input_rate
        output_cost = output_tokens / 1_000_000 * output_rate

        Float.round(input_cost + output_cost, 6)

      _ ->
        # No cost data available
        0.0
    end
  end

  # Utility functions
  defp estimate_tokens(text), do: max(1, div(String.length(text), 4))

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

  defp parse_args(args, extra_switches) do
    OptionParser.parse(args,
      switches:
        [
          model: :string,
          system: :string,
          max_tokens: :integer,
          temperature: :float,
          log_level: :string
        ] ++ extra_switches,
      aliases: [
        m: :model,
        s: :system,
        t: :temperature,
        l: :log_level
      ]
    )
  end

  defp validate_prompt(args_list, _task_name) do
    case args_list do
      [prompt | _] when is_binary(prompt) and prompt != "" ->
        {:ok, prompt}

      _ ->
        IO.puts("Error: Prompt is required")
        {:error, :no_prompt}
    end
  end

  defp parse_log_level(nil), do: :info
  defp parse_log_level("warning"), do: :warning
  defp parse_log_level("info"), do: :info
  defp parse_log_level("debug"), do: :debug
  defp parse_log_level(_), do: :info

  defp validate_model_spec(model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, model} ->
        {:ok, model}

      {:error, %{tag: :invalid_provider, context: context}} ->
        {:error, {:invalid_provider, context[:provider]}}

      {:error, %{tag: :invalid_model_spec} = error} ->
        {:error, {:invalid_spec, error}}

      {:error, error} ->
        {:error, {:invalid_spec, error}}
    end
  end

  defp handle_validation_error({:invalid_provider, provider}, _model_spec) do
    IO.puts("Error: Unknown provider '#{provider}'")
    IO.puts("Available providers:")

    try do
      providers = ReqLLM.Providers.list()

      Enum.each(providers, fn provider_atom ->
        IO.puts("  • #{provider_atom}")
      end)
    rescue
      _ ->
        IO.puts("  Could not load provider list")
    end
  end

  defp handle_validation_error({:invalid_spec, error}, model_spec) do
    IO.puts("Error: Invalid model specification '#{model_spec}'")
    IO.puts("Details: #{Exception.message(error)}")
  end

  defp handle_generation_error(error, model_spec, log_level) do
    error_message = format_error(error)

    cond do
      api_key_missing_error?(error_message) ->
        handle_missing_api_key_error(error_message, model_spec, log_level)

      model_not_found_error?(error, error_message) ->
        log_puts(error_message, :warning, log_level)

        case parse_provider_from_spec(model_spec) do
          {:ok, provider} ->
            list_provider_models(provider)

          {:error, _} ->
            :ok
        end

      true ->
        log_puts(error_message, :warning, log_level)
    end
  end

  defp api_key_missing_error?(error_message) do
    String.contains?(error_message, "api_key option or") or
      String.contains?(error_message, "_API_KEY") or
      String.contains?(error_message, "API key")
  end

  defp handle_missing_api_key_error(error_message, model_spec, log_level) do
    case parse_provider_from_spec(model_spec) do
      {:ok, provider_id} ->
        case ReqLLM.provider(provider_id) do
          {:ok, provider_module} ->
            env_var = provider_module.default_env_key([])
            log_puts("Error: API key not found for #{provider_id}", :warning, log_level)
            log_puts("\nPlease set your API key using one of these methods:", :warning, log_level)

            log_puts(
              "  1. Environment variable: export #{env_var}=your-api-key",
              :warning,
              log_level
            )

            log_puts(
              "  2. Application config: config :req_llm, #{provider_id}_api_key: \"your-api-key\"",
              :warning,
              log_level
            )

            log_puts(
              "  3. Pass directly: generate_text(model, prompt, api_key: \"your-api-key\")",
              :warning,
              log_level
            )

          {:error, _} ->
            log_puts("Error: #{error_message}", :warning, log_level)
        end

      {:error, _} ->
        log_puts("Error: #{error_message}", :warning, log_level)
    end
  end

  defp model_not_found_error?(error, error_message) do
    cond do
      is_struct(error, ReqLLM.Error.API) and error.status == 404 ->
        true

      String.contains?(error_message, "404") ->
        true

      String.contains?(String.downcase(error_message), "model") and
          String.contains?(String.downcase(error_message), ["not found", "invalid", "unknown"]) ->
        true

      true ->
        false
    end
  end

  defp parse_provider_from_spec(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [provider_str, _model] when provider_str != "" ->
        LLMDB.Spec.parse_provider(provider_str)

      _ ->
        {:error, :invalid_spec}
    end
  end

  defp parse_provider_from_spec(_), do: {:error, :invalid_spec}

  defp list_provider_models(provider) do
    case LLMDB.models(provider) do
      models when models != [] ->
        IO.puts("\nAvailable #{provider} models:")

        Enum.each(models, fn model ->
          IO.puts("  • #{LLMDB.Model.spec(model)}")
        end)

      [] ->
        IO.puts("\n(No models found for provider #{provider})")
    end
  end

  defp resolve_schema(opts) do
    case Keyword.get(opts, :schema) do
      nil ->
        default_object_schema()

      value ->
        case load_schema(value) do
          {:ok, schema} ->
            schema

          {:error, reason} ->
            IO.puts(
              "Warning: Failed to load schema (#{inspect(reason)}). Falling back to default schema."
            )

            default_object_schema()
        end
    end
  end

  defp load_schema(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") ->
        parse_inline_schema(trimmed)

      File.exists?(value) ->
        load_schema_file(value)

      true ->
        load_predefined_schema(value)
    end
  end

  defp parse_inline_schema(json) do
    with {:ok, decoded} <- Jason.decode(json) do
      normalize_schema(decoded)
    end
  end

  defp load_schema_file(path) do
    case Path.extname(path) do
      ".json" ->
        case File.read(path) do
          {:ok, content} ->
            with {:ok, decoded} <- Jason.decode(content) do
              normalize_schema(decoded)
            end

          {:error, reason} ->
            {:error, {:file_read_error, reason}}
        end

      _ ->
        {:error, :unsupported_format}
    end
  end

  defp load_predefined_schema(name) do
    case predefined_schemas()[name] do
      nil -> {:error, :unknown_schema_name}
      schema -> {:ok, schema}
    end
  end

  defp predefined_schemas do
    %{
      "person" => default_object_schema(),
      "product" => [
        name: [type: :string, required: true, doc: "Product name"],
        price: [type: :float, required: true, doc: "Product price in USD"],
        category: [type: :string, required: true, doc: "Product category"],
        features: [type: {:list, :string}, doc: "Key features"],
        in_stock: [type: :boolean, doc: "Whether product is in stock"]
      ],
      "address" => [
        street: [type: :string, required: true, doc: "Street address"],
        city: [type: :string, required: true, doc: "City"],
        state: [type: :string, doc: "State or province"],
        country: [type: :string, required: true, doc: "Country"],
        postal_code: [type: :string, doc: "Postal or ZIP code"]
      ]
    }
  end

  defp normalize_schema(%{"type" => "object", "properties" => props} = obj) when is_map(props) do
    required = Map.get(obj, "required", [])

    fields =
      Enum.map(props, fn {k, v} ->
        name = String.to_atom(k)

        opts =
          []
          |> maybe_put(:type, map_json_type(v))
          |> maybe_put(:doc, v["description"])
          |> maybe_put(:required, k in required)
          |> Enum.reject(fn {_k, val} -> is_nil(val) end)

        {name, opts}
      end)

    {:ok, fields}
  end

  defp normalize_schema(map) when is_map(map) do
    fields =
      Enum.map(map, fn {k, v} ->
        name = String.to_atom(k)
        {name, normalize_field_opts(v)}
      end)

    {:ok, fields}
  end

  defp normalize_schema(_), do: {:error, :invalid_schema_format}

  defp normalize_field_opts(%{"type" => _t} = v) do
    type = map_simple_type(v["type"], v)

    []
    |> maybe_put(:type, type)
    |> maybe_put(:required, v["required"])
    |> maybe_put(:doc, v["doc"] || v["description"])
    |> Enum.reject(fn {_k, val} -> is_nil(val) end)
  end

  defp normalize_field_opts(v) when is_map(v), do: []

  defp map_json_type(%{"type" => "array", "items" => %{"type" => inner}}) do
    {:list, map_atomic_type(inner)}
  end

  defp map_json_type(%{"type" => t} = v) do
    map_simple_type(t, v)
  end

  defp map_simple_type("integer", %{"minimum" => min}) when is_number(min) and min >= 1,
    do: :pos_integer

  defp map_simple_type("integer", _), do: :integer
  defp map_simple_type("number", _), do: :float
  defp map_simple_type("string", _), do: :string
  defp map_simple_type("boolean", _), do: :boolean
  defp map_simple_type("object", _), do: :map
  defp map_simple_type("array", _), do: :list
  defp map_simple_type("list:string", _), do: {:list, :string}
  defp map_simple_type("list:integer", _), do: {:list, :integer}
  defp map_simple_type(other, _) when is_binary(other), do: String.to_atom(other)

  defp map_atomic_type("integer"), do: :integer
  defp map_atomic_type("number"), do: :float
  defp map_atomic_type("string"), do: :string
  defp map_atomic_type("boolean"), do: :boolean
  defp map_atomic_type("object"), do: :map
  defp map_atomic_type(other) when is_binary(other), do: String.to_atom(other)
end

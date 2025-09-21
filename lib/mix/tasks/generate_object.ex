defmodule Mix.Tasks.Req.Llm.GenerateObject do
  @shortdoc "Generate structured objects from any AI model"

  @moduledoc """
  Mix task for structured object generation from any supported AI model.

  ## Usage

      mix req.llm.generate_object "Your prompt here" --model provider:model-name

  ## Examples

      # Generate from OpenAI
      mix req.llm.generate_object "Generate a user profile for John" --model openai:gpt-4o-mini

      # Generate from Anthropic
      mix req.llm.generate_object "Extract person info: John works at Acme Corp" --model anthropic:claude-3-sonnet

  ## Options

      --model         Model specification (provider:model-name)
      --system        System prompt/message
      --max-tokens    Maximum tokens to generate
      --temperature   Sampling temperature (0.0-2.0)
      --log-level     Output verbosity level: quiet, normal, verbose, debug (default: normal)
  """
  use Mix.Task

  @preferred_cli_env ["req.llm.generate_object": :dev]
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
          log_level: :string
        ],
        aliases: [
          l: :log_level
        ]
      )

    prompt =
      case args_list do
        [p | _] ->
          p

        [] ->
          IO.puts(
            "Usage: mix req.llm.generate_object \"Your prompt here\" --model provider:model-name"
          )

          IO.puts("")
          IO.puts("Examples:")

          IO.puts(
            "  mix req.llm.generate_object \"Generate a user profile for John\" --model openai:gpt-4o-mini"
          )

          IO.puts(
            "  mix req.llm.generate_object \"Extract person info: John works at Acme\" --model anthropic:claude-3-sonnet"
          )

          System.halt(1)
      end

    model_spec = Keyword.get(opts, :model, "openai:gpt-4o")
    log_level = parse_log_level(Keyword.get(opts, :log_level, "normal"))

    # Derive behavior flags from log level
    quiet = log_level == :quiet
    debug = log_level == :debug
    metrics = log_level in [:verbose, :debug]

    # Use a simple hardcoded schema for testing
    schema = [
      name: [type: :string, required: true, doc: "Full name of the person"],
      age: [type: :pos_integer, doc: "Age in years"],
      occupation: [type: :string, doc: "Job or profession"],
      location: [type: :string, doc: "City or region where they live"]
    ]

    if !quiet do
      IO.puts("Generating object from #{model_spec}")
      IO.puts("Prompt: #{prompt}")
      IO.puts("")
    end

    generate_opts =
      []
      |> maybe_add_option(opts, :system_prompt, :system)
      |> maybe_add_option(opts, :max_tokens)
      |> maybe_add_option(opts, :temperature)
      |> Enum.reject(fn {_key, val} -> is_nil(val) end)

    start_time = System.monotonic_time(:millisecond)

    try do
      case ReqLLM.Generation.generate_object(model_spec, prompt, schema, generate_opts) do
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

          generated_object = ReqLLM.Response.object(response)

          # Debug: Show full response structure 
          if debug do
            IO.puts("=== FULL RESPONSE STRUCTURE ===========================")
            IO.puts(inspect(response, pretty: true, limit: :infinity))
            IO.puts("========================================================")
            IO.puts("")
          end

          if !quiet do
            IO.puts("Generated Object:")
            IO.puts(Jason.encode!(generated_object, pretty: true))
            IO.puts("")
          end

          # Debug: Show response metadata
          if debug do
            debug_response_meta(response)
          end

          if metrics do
            show_key_stats(generated_object, start_time, model_spec, prompt, response)
          end

          if !quiet, do: IO.puts("Object generation completed")
          :ok

        {:error, %ReqLLM.Error.Invalid.Provider{provider: provider}} ->
          IO.puts(
            "Error: Unknown provider '#{provider}'. Please check that the provider is supported and properly configured."
          )

          IO.puts("Available providers: openai, groq, xai (others may require additional setup)")
          System.halt(1)

        {:error, %ReqLLM.Error.Invalid.Parameter{parameter: param}} ->
          IO.puts("Error: #{param}")
          System.halt(1)

        {:error, %ReqLLM.Error.API.Request{reason: reason, status: status}}
        when not is_nil(status) ->
          IO.puts("API Error (#{status}): #{reason}")
          System.halt(1)

        {:error, %ReqLLM.Error.API.Request{reason: reason}} ->
          IO.puts("API Error: #{reason}")
          System.halt(1)

        {:error, error} ->
          IO.puts("Object generation failed: #{format_error(error)}")
          System.halt(1)
      end
    rescue
      error in UndefinedFunctionError ->
        case error do
          %UndefinedFunctionError{module: nil, function: :prepare_request} ->
            IO.puts(
              "Error: Provider not properly configured or not available. Please check your model specification."
            )

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

  defp format_error(%{__struct__: _} = error), do: Exception.message(error)

  defp format_error(error), do: inspect(error)

  defp maybe_add_option(opts_list, parsed_opts, target_key, source_key \\ nil) do
    source_key = source_key || target_key

    case Keyword.get(parsed_opts, source_key) do
      nil -> opts_list
      value -> Keyword.put(opts_list, target_key, value)
    end
  end

  defp show_key_stats(generated_object, start_time, model_spec, _prompt, response) do
    end_time = System.monotonic_time(:millisecond)
    response_time = end_time - start_time

    input_tokens = get_nested(response, [:usage, :input_tokens], 0)
    output_tokens = get_nested(response, [:usage, :output_tokens], 0)

    # Estimate object complexity
    object_json = Jason.encode!(generated_object)
    object_size = byte_size(object_json)
    field_count = count_fields(generated_object)

    estimated_cost = calculate_cost(model_spec, input_tokens + output_tokens)

    IO.puts("   Response time: #{response_time}ms")
    IO.puts("   Object size: #{object_size} bytes")
    IO.puts("   Field count: #{field_count}")
    IO.puts("   Input tokens: #{input_tokens}")
    IO.puts("   Output tokens: #{output_tokens}")
    IO.puts("   Total tokens: #{input_tokens + output_tokens}")

    if estimated_cost > 0 do
      IO.puts("   Estimated cost: $#{Float.round(estimated_cost, 6)}")
    else
      IO.puts("   Estimated cost: Unknown")
    end
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
end

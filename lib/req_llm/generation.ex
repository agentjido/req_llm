defmodule ReqLLM.Generation do
  @moduledoc """
  Text generation functionality for ReqLLM.

  This module provides the core text generation capabilities including:
  - Text generation with full response metadata
  - Text streaming with metadata
  - Usage and cost extraction utilities

  All functions follow Vercel AI SDK patterns and return structured responses
  with proper error handling.
  """

  alias ReqLLM.Context
  alias ReqLLM.Response

  @doc """
  Returns the base generation options schema.

  This schema delegates to ReqLLM.Provider.Options.generation_schema/0 which is
  the canonical runtime options schema. Provider-specific options should be
  validated separately by each provider via Provider.Options.process/4.

  For the complete schema including provider extensions, use:
      Provider.Options.compose_schema(Provider.Options.generation_schema(), provider_mod)
  """
  @spec schema :: NimbleOptions.t()
  def schema do
    ReqLLM.Provider.Options.generation_schema()
  end

  @doc """
  Generates text using an AI model with full response metadata.

  Returns a canonical ReqLLM.Response which includes usage data, context, and metadata.
  For simple text-only results, use `generate_text!/3`.

  ## Parameters

    * `model_spec` - Model specification in various formats
    * `messages` - Text prompt or list of messages
    * `opts` - Additional options (keyword list)

  ## Options

    * `:temperature` - Control randomness in responses (0.0 to 2.0)
    * `:max_tokens` - Limit the length of the response
    * `:top_p` - Nucleus sampling parameter
    * `:presence_penalty` - Penalize new tokens based on presence
    * `:frequency_penalty` - Penalize new tokens based on frequency
    * `:tools` - List of tool definitions
    * `:tool_choice` - Tool choice strategy
    * `:output` - A `ReqLLM.Output` descriptor; omitted and `ReqLLM.Output.text/0`
      preserve plain-text behavior, while structured descriptors reuse the existing
      provider-native or tool-fallback object path
    * `:output_validation` - Final validation policy: `:compatible`, `:warn`, or
      `:strict`; omitted calls preserve current V1 behavior
    * `:output_repair` - Optional one-argument local repair callback invoked at
      most once after an invalid complete structured output
    * `:system_prompt` - System prompt to prepend
    * `:receive_timeout` - Provider-transport inactivity timeout in milliseconds
    * `:total_timeout` - Optional whole-call deadline in milliseconds, including retries
    * `:stream_idle_timeout` - Optional semantic-progress timeout for streaming calls
    * `:provider_options` - Provider-specific options

  ## Examples

      {:ok, response} = ReqLLM.Generation.generate_text("anthropic:claude-3-sonnet", "Hello world")
      ReqLLM.Response.text(response)
      #=> "Hello! How can I assist you today?"

      # Access usage metadata
      ReqLLM.Response.usage(response)
      #=> %{input_tokens: 10, output_tokens: 8}

      output = ReqLLM.Output.object([name: [type: :string, required: true]])
      {:ok, response} = ReqLLM.Generation.generate_text(model, "Generate a person", output: output)
      ReqLLM.Response.output(response, output)
      #=> %{"name" => "Ada"}

  """

  @spec generate_text(
          ReqLLM.model_input(),
          Context.prompt(),
          keyword()
        ) :: {:ok, Response.t()} | {:error, term()}
  def generate_text(model_spec, messages, opts \\ []) do
    opts = ReqLLM.ModelInput.merge_tuple_defaults(model_spec, :chat, opts)
    {output, opts} = Keyword.pop(opts, :output)

    with {:ok, runtime_config, opts} <- ReqLLM.Output.Validation.take_runtime_options(opts),
         {:ok, descriptor} <- ReqLLM.Output.normalize(output),
         {:ok, contract} <- ReqLLM.Output.compile(descriptor),
         :ok <- ReqLLM.Output.Validation.validate_runtime_config(contract, runtime_config) do
      case contract.operation do
        :chat ->
          model_spec
          |> generate_text_response(messages, opts)
          |> ReqLLM.Output.Validation.finalize_result(contract, runtime_config)

        :object ->
          generate_output_response(model_spec, messages, contract, opts, runtime_config)
      end
    end
  end

  defp generate_text_response(model_spec, messages, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, opts} <-
           ReqLLM.Provider.Options.normalize_namespaced_provider_options(
             provider_module,
             :chat,
             model,
             opts
           ),
         {:ok, context} <- ReqLLM.Context.normalize(messages, opts),
         :ok <- ReqLLM.ProviderFileReference.validate_context(context, model.provider) do
      case ReqLLM.Cache.fetch(model, :chat, context, opts) do
        {:hit, response, _cache_ref} ->
          {:ok, response}

        {:miss, cache_ref} ->
          execute_generate_text(
            provider_module,
            model,
            context,
            ReqLLM.Cache.request_opts(opts),
            opts,
            cache_ref
          )
      end
    end
  end

  defp generate_output_response(model_spec, messages, contract, opts, runtime_config) do
    generate_object_response(
      model_spec,
      messages,
      {:compiled, contract.compiled_schema},
      opts,
      contract.descriptor,
      runtime_config
    )
  end

  @doc """
  Generates text using an AI model, returning only the text content.

  This is a convenience function that extracts just the text from the response.
  For access to usage metadata and other response data, use `generate_text/3`.
  Raises on error. This function remains a text-only convenience; use
  `generate_text/3` and `ReqLLM.Response.output/2` for structured descriptors.

  ## Parameters

  Same as `generate_text/3`.

  ## Examples

      ReqLLM.Generation.generate_text!("anthropic:claude-3-sonnet", "Hello world")
      #=> "Hello! How can I assist you today?"

  """
  @spec generate_text!(
          ReqLLM.model_input(),
          Context.prompt(),
          keyword()
        ) :: String.t() | no_return()
  def generate_text!(model_spec, messages, opts \\ []) do
    case generate_text(model_spec, messages, opts) do
      {:ok, response} -> Response.text(response)
      {:error, error} -> raise error
    end
  end

  @doc """
  Streams text generation using an AI model with full response metadata.

  Returns a canonical ReqLLM.Response containing usage data and stream.
  For simple streaming without metadata, use `stream_text!/3`.

  When `:output` is structured, the stream retains the existing object-stream
  representation. Partial content and tool-call argument chunks are transport
  fragments, not final-schema validation results. Materialize the stream once
  with `ReqLLM.StreamResponse.to_response/1`, then call
  `ReqLLM.Response.output/2` with the same descriptor. An explicit
  `:output_validation` policy is enforced by `to_response/1` or
  `ReqLLM.StreamResponse.process_stream/2` after the complete value exists.

  ## Parameters

  Same as `generate_text/3`.

  ## Examples

      {:ok, response} = ReqLLM.Generation.stream_text("anthropic:claude-3-sonnet", "Tell me a story")
      ReqLLM.Response.text_stream(response) |> Enum.each(&IO.write/1)

      # Access usage metadata after streaming
      ReqLLM.Response.usage(response)
      #=> %{input_tokens: 15, output_tokens: 42}

  """
  @spec stream_text(
          ReqLLM.model_input(),
          Context.prompt(),
          keyword()
        ) :: {:ok, ReqLLM.StreamResponse.t()} | {:error, term()}
  def stream_text(model_spec, messages, opts \\ []) do
    opts = ReqLLM.ModelInput.merge_tuple_defaults(model_spec, :chat, opts)
    {output, opts} = Keyword.pop(opts, :output)

    with {:ok, runtime_config, opts} <- ReqLLM.Output.Validation.take_runtime_options(opts),
         {:ok, descriptor} <- ReqLLM.Output.normalize(output),
         {:ok, contract} <- ReqLLM.Output.compile(descriptor),
         :ok <- ReqLLM.Output.Validation.validate_runtime_config(contract, runtime_config) do
      case contract.operation do
        :chat ->
          model_spec
          |> stream_text_response(messages, opts)
          |> ReqLLM.Output.Validation.attach_stream_result(contract, runtime_config)

        :object ->
          stream_output_response(model_spec, messages, contract, opts, runtime_config)
      end
    end
  end

  defp stream_text_response(model_spec, messages, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, opts} <-
           ReqLLM.Provider.Options.normalize_namespaced_provider_options(
             provider_module,
             :chat,
             model,
             opts
           ),
         {:ok, context} <- ReqLLM.Context.normalize(messages, opts),
         :ok <- ReqLLM.ProviderFileReference.validate_context(context, model.provider) do
      case ReqLLM.Cache.fetch(model, :chat, context, opts) do
        {:hit, response, _cache_ref} ->
          {:ok, ReqLLM.Cache.stream_response(response, model, context)}

        {:miss, _cache_ref} ->
          ReqLLM.Streaming.start_stream(
            provider_module,
            model,
            context,
            ReqLLM.Cache.request_opts(opts)
          )
      end
    end
  end

  defp stream_output_response(model_spec, messages, contract, opts, runtime_config) do
    stream_object_response(
      model_spec,
      messages,
      {:compiled, contract.compiled_schema},
      opts,
      contract.descriptor,
      runtime_config
    )
  end

  @doc """
  **DEPRECATED**: This function will be removed in a future version.

  The streaming API has been redesigned to return a composite `StreamResponse` struct
  that provides both the stream and metadata. Use `stream_text/3` instead:

      {:ok, response} = ReqLLM.Generation.stream_text(model, messages)
      response.stream |> Enum.each(&IO.write/1)

  For simple text extraction, use:

      text = ReqLLM.StreamResponse.text(response)
  """
  @deprecated "Use stream_text/3 with StreamResponse instead"
  @spec stream_text!(
          ReqLLM.model_input(),
          Context.prompt(),
          keyword()
        ) :: Enumerable.t() | no_return()
  def stream_text!(_model_spec, _messages, _opts \\ []) do
    IO.warn("""
    ReqLLM.Generation.stream_text!/3 is deprecated and will be removed in a future version.

    Please migrate to the new streaming API:

    Old code:
        ReqLLM.Generation.stream_text!(model, messages) |> Enum.each(&IO.write/1)

    New code:
        {:ok, response} = ReqLLM.Generation.stream_text(model, messages)
        response.stream |> Enum.each(&IO.write/1)

    Or for simple text extraction:
        text = ReqLLM.StreamResponse.text(response)
    """)

    :ok
  end

  @doc """
  Generates structured data using an AI model with schema validation.

  Returns a canonical ReqLLM.Response which includes the generated object, usage data,
  context, and metadata. For simple object-only results, use `generate_object!/4`.

  ## Parameters

    * `model_spec` - Model specification in various formats
    * `messages` - Text prompt or list of messages
    * `schema` - Schema definition for structured output (keyword list) or Zoi schema
    * `opts` - Additional options (keyword list)

  ## Options

    * `:temperature` - Control randomness in responses (0.0 to 2.0)
    * `:max_tokens` - Limit the length of the response
    * `:top_p` - Nucleus sampling parameter
    * `:presence_penalty` - Penalize new tokens based on presence
    * `:frequency_penalty` - Penalize new tokens based on frequency
    * `:system_prompt` - System prompt to prepend
    * `:receive_timeout` - Provider-transport inactivity timeout in milliseconds
    * `:total_timeout` - Optional whole-call deadline in milliseconds, including retries
    * `:stream_idle_timeout` - Optional semantic-progress timeout for streaming calls
    * `:provider_options` - Provider-specific options
    * `:output_validation` - Final validation policy: `:compatible`, `:warn`, or
      `:strict`; omitted calls preserve current V1 behavior
    * `:output_repair` - Optional one-argument local repair callback invoked at
      most once after an invalid complete object

  ## Examples

      {:ok, response} = ReqLLM.Generation.generate_object("anthropic:claude-3-sonnet", "Generate a person", person_schema)
      ReqLLM.Response.object(response)
      #=> %{name: "Alice Smith", age: 30, occupation: "Engineer"}

      # Access usage metadata
      ReqLLM.Response.usage(response)
      #=> %{input_tokens: 25, output_tokens: 15}

  """
  @spec generate_object(
          ReqLLM.model_input(),
          Context.prompt(),
          keyword() | map() | Zoi.Type.t(),
          keyword()
        ) :: {:ok, Response.t()} | {:error, term()}
  def generate_object(model_spec, messages, object_schema, opts \\ []) do
    opts =
      model_spec
      |> ReqLLM.ModelInput.merge_tuple_defaults(:object, opts)
      |> Keyword.delete(:output)

    with {:ok, runtime_config, opts} <-
           ReqLLM.Output.Validation.take_runtime_options(opts) do
      generate_object_response(
        model_spec,
        messages,
        {:schema, object_schema},
        opts,
        ReqLLM.Output.object(object_schema),
        runtime_config
      )
    end
  end

  defp generate_object_response(
         model_spec,
         messages,
         schema_source,
         opts,
         descriptor,
         runtime_config
       ) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, opts} <-
           ReqLLM.Provider.Options.normalize_namespaced_provider_options(
             provider_module,
             :object,
             model,
             opts
           ),
         {:ok, context} <- ReqLLM.Context.normalize(messages, opts),
         :ok <- ReqLLM.ProviderFileReference.validate_context(context, model.provider),
         {:ok, compiled_schema} <- compile_schema_source(schema_source) do
      compiled_opts = Keyword.put(opts, :compiled_schema, compiled_schema)
      contract = ReqLLM.Output.Validation.validation_contract(descriptor, compiled_schema)

      result =
        case ReqLLM.Cache.fetch(model, :object, context, opts, compiled_schema.schema) do
          {:hit, response, _cache_ref} ->
            {:ok, response}

          {:miss, cache_ref} ->
            execute_generate_object(
              provider_module,
              model,
              context,
              compiled_schema,
              ReqLLM.Cache.request_opts(compiled_opts),
              compiled_opts,
              cache_ref
            )
        end

      ReqLLM.Output.Validation.finalize_result(result, contract, runtime_config)
    end
  end

  defp compile_schema_source({:schema, schema}), do: ReqLLM.Schema.compile(schema)
  defp compile_schema_source({:compiled, compiled_schema}), do: {:ok, compiled_schema}

  @doc """
  Generates structured data using an AI model, returning only the object content.

  This is a convenience function that extracts just the object from the response.
  For access to usage metadata and other response data, use `generate_object/4`.
  Raises on error.

  ## Parameters

  Same as `generate_object/4`.

  ## Examples

      ReqLLM.Generation.generate_object!("anthropic:claude-3-sonnet", "Generate a person", person_schema)
      #=> %{name: "Alice Smith", age: 30, occupation: "Engineer"}

  """
  @spec generate_object!(
          String.t() | {atom(), keyword()} | struct(),
          Context.prompt(),
          keyword() | map() | Zoi.Type.t(),
          keyword()
        ) :: map() | no_return()
  def generate_object!(model_spec, messages, object_schema, opts \\ []) do
    case generate_object(model_spec, messages, object_schema, opts) do
      {:ok, response} -> Response.object(response)
      {:error, error} -> raise error
    end
  end

  # Coerces object types to match schema for models that don't strictly follow schemas
  # Uses JSV validation but keeps the coerced result instead of discarding it
  defp coerce_object_types(%Response{object: object} = response, schema)
       when not is_nil(object) do
    case coerce_with_schema(object, schema) do
      {:ok, coerced} -> %{response | object: coerced}
      # If coercion fails, return original
      {:error, _} -> response
    end
  end

  defp coerce_object_types(response, _schema), do: response

  defp execute_generate_text(provider_module, model, context, request_opts, cache_opts, cache_ref) do
    deadline = ReqLLM.TimeoutBudget.deadline(request_opts)

    with {:ok, request} <- provider_module.prepare_request(:chat, model, context, request_opts),
         {:ok, %Req.Response{status: status, body: decoded_response}} when status in 200..299 <-
           ReqLLM.TimeoutBudget.request(request, deadline) do
      {:ok, ReqLLM.Cache.store(cache_ref, decoded_response, cache_opts)}
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Request failed",
           status: status,
           response_body: body
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp execute_generate_object(
         provider_module,
         model,
         context,
         compiled_schema,
         request_opts,
         cache_opts,
         cache_ref
       ) do
    deadline = ReqLLM.TimeoutBudget.deadline(request_opts)

    with {:ok, request} <-
           provider_module.prepare_request(:object, model, context, request_opts),
         {:ok, %Req.Response{status: status, body: decoded_response}} when status in 200..299 <-
           ReqLLM.TimeoutBudget.request(request, deadline) do
      response =
        if ReqLLM.ModelHelpers.json_strict?(model) do
          decoded_response
        else
          coerce_object_types(decoded_response, compiled_schema.schema)
        end

      {:ok, ReqLLM.Cache.store(cache_ref, response, cache_opts)}
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Request failed",
           status: status,
           response_body: body
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp coerce_with_schema(data, schema) do
    json_schema = ReqLLM.Schema.to_json(schema)
    built_schema = JSV.build!(json_schema)

    # First try validation - if it passes, data is already correct
    case JSV.validate(data, built_schema) do
      {:ok, validated_data} ->
        {:ok, validated_data}

      {:error, %JSV.ValidationError{errors: errors}} ->
        # Extract type errors and coerce those fields
        type_errors = extract_type_errors(errors)
        coerced_data = apply_type_coercion(data, type_errors, json_schema)

        # Try validation again with coerced data
        case JSV.validate(coerced_data, built_schema) do
          {:ok, validated_data} -> {:ok, validated_data}
          # Return coerced even if still invalid
          {:error, _} -> {:ok, coerced_data}
        end
    end
  rescue
    _ -> {:error, :coercion_failed}
  end

  # Extract type mismatch errors from JSV validation errors
  defp extract_type_errors(errors) do
    errors
    |> Enum.filter(fn error -> error.kind == :type end)
    |> Enum.map(fn error ->
      path = error.data_path
      expected_type = Keyword.get(error.args, :type)
      {path, expected_type}
    end)
  end

  # Apply type coercion to specific fields based on type errors
  defp apply_type_coercion(data, type_errors, _schema) when is_map(data) do
    Enum.reduce(type_errors, data, fn {path, expected_type}, acc ->
      coerce_field(acc, path, expected_type)
    end)
  end

  # Coerce a specific field at the given path
  defp coerce_field(data, [field | rest], expected_type) when is_map(data) do
    case Map.get(data, field) do
      nil ->
        data

      value when rest == [] ->
        Map.put(data, field, coerce_value(value, expected_type))

      value when is_map(value) ->
        Map.put(data, field, coerce_field(value, rest, expected_type))

      _ ->
        data
    end
  end

  defp coerce_field(data, [], _expected_type), do: data

  # Coerce individual values based on expected type
  defp coerce_value(value, :integer) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp coerce_value(value, :number) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _ -> value
    end
  end

  defp coerce_value(value, :boolean) when is_binary(value) do
    case String.downcase(value) do
      "true" -> true
      "false" -> false
      _ -> value
    end
  end

  defp coerce_value(value, _type), do: value

  @doc """
  Streams structured data generation using an AI model with schema validation.

  Returns a `ReqLLM.StreamResponse` that provides both real-time structured data streaming
  and concurrent metadata collection. Uses the same Finch-based streaming infrastructure
  as `stream_text/3` with connection pooling and configurable checkout timeouts.

  ## Parameters

    * `model_spec` - Model specification in various formats
    * `messages` - Text prompt or list of messages
    * `schema` - Schema definition for structured output (keyword list) or Zoi schema
    * `opts` - Additional options (keyword list)

  ## Options

  Same as `generate_object/4`.

  ## Returns

    * `{:ok, stream_response}` - StreamResponse with object stream and metadata task
    * `{:error, reason}` - Request failed or invalid parameters

  ## Examples

      # Stream structured data generation
      {:ok, response} = ReqLLM.Generation.stream_object("anthropic:claude-3-sonnet", "Generate a person", person_schema)

      # Process structured chunks as they arrive
      response.stream
      |> Stream.filter(&(&1.type in [:content, :tool_call]))
      |> Stream.each(&IO.inspect/1)
      |> Stream.run()

      # Concurrent metadata collection
      usage = ReqLLM.StreamResponse.usage(response)
      #=> %{input_tokens: 25, output_tokens: 15, total_cost: 0.045}

  ## Structure Notes

  Object streaming may include both content chunks (partial JSON) and tool_call chunks
  depending on the provider's structured output implementation. Use appropriate filtering
  based on your needs.

  """
  @spec stream_object(
          ReqLLM.model_input(),
          Context.prompt(),
          keyword() | Zoi.Type.t(),
          keyword()
        ) :: {:ok, ReqLLM.StreamResponse.t()} | {:error, term()}
  def stream_object(model_spec, messages, object_schema, opts \\ []) do
    opts =
      model_spec
      |> ReqLLM.ModelInput.merge_tuple_defaults(:object, opts)
      |> Keyword.delete(:output)

    with {:ok, runtime_config, opts} <-
           ReqLLM.Output.Validation.take_runtime_options(opts) do
      stream_object_response(
        model_spec,
        messages,
        {:schema, object_schema},
        opts,
        ReqLLM.Output.object(object_schema),
        runtime_config
      )
    end
  end

  defp stream_object_response(
         model_spec,
         messages,
         schema_source,
         opts,
         descriptor,
         runtime_config
       ) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, opts} <-
           ReqLLM.Provider.Options.normalize_namespaced_provider_options(
             provider_module,
             :object,
             model,
             opts
           ),
         {:ok, context} <- ReqLLM.Context.normalize(messages, opts),
         :ok <- ReqLLM.ProviderFileReference.validate_context(context, model.provider),
         {:ok, compiled_schema} <- compile_schema_source(schema_source),
         {:ok, prepared_req} <-
           provider_module.prepare_request(
             :object,
             model,
             messages,
             Keyword.put(opts, :compiled_schema, compiled_schema)
           ) do
      prepared_context = prepared_req.options[:context] || %ReqLLM.Context{messages: []}

      stream_opts =
        opts
        |> Keyword.merge(Map.to_list(prepared_req.options))
        |> Keyword.put(:stream, true)
        |> Keyword.put_new(:operation, :object)
        |> Keyword.put(:compiled_schema, compiled_schema)

      contract = ReqLLM.Output.Validation.validation_contract(descriptor, compiled_schema)

      provider_module
      |> ReqLLM.Streaming.start_stream(model, prepared_context, stream_opts)
      |> ReqLLM.Output.Validation.attach_stream_result(contract, runtime_config)
    end
  end

  @doc """
  **DEPRECATED**: This function will be removed in a future version.

  The streaming API has been redesigned to return a composite `StreamResponse` struct
  that provides both the stream and metadata. Use `stream_object/4` instead:

      {:ok, response} = ReqLLM.Generation.stream_object(model, messages, schema)
      response.stream |> Enum.each(&IO.inspect/1)

  For simple object extraction, use:

      object = ReqLLM.StreamResponse.object(response)

  ## Legacy Parameters

  Same as `stream_object/4`.

  ## Legacy Examples

      ReqLLM.Generation.stream_object!("anthropic:claude-3-sonnet", "Generate a person", person_schema)
      |> Enum.each(&IO.inspect/1)

  """
  @deprecated "Use stream_object/4 with StreamResponse instead"
  @spec stream_object!(
          ReqLLM.model_input(),
          Context.prompt(),
          keyword() | Zoi.Type.t(),
          keyword()
        ) :: Enumerable.t() | no_return()
  def stream_object!(_model_spec, _messages, _object_schema, _opts \\ []) do
    IO.warn("""
    ReqLLM.Generation.stream_object!/4 is deprecated and will be removed in a future version.

    Please migrate to the new streaming API:

    Old code:
        ReqLLM.Generation.stream_object!(model, messages, schema) |> Enum.each(&IO.inspect/1)

    New code:
        {:ok, response} = ReqLLM.Generation.stream_object(model, messages, schema)
        response.stream |> Enum.each(&IO.inspect/1)

    Or for simple object extraction:
        object = ReqLLM.StreamResponse.object(response)
    """)

    :ok
  end
end

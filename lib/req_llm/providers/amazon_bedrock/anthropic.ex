defmodule ReqLLM.Providers.AmazonBedrock.Anthropic do
  @moduledoc """
  Anthropic model family support for AWS Bedrock.

  Handles Claude models (Claude 3 Sonnet, Haiku, Opus, etc.) on AWS Bedrock.

  This module acts as a thin adapter between Bedrock's AWS-specific wrapping
  and Anthropic's native message format. It delegates to the native Anthropic
  modules for all format conversion.

  ## Prompt Caching Support

  Full Anthropic prompt caching is supported when using the native Bedrock API.
  Enable with `anthropic_prompt_cache: true` option.

  **Note**: Bedrock auto-switches to Converse API when tools are present (including
  `:object` operations which use a synthetic tool). Converse API has limited caching
  (only entire system prompts, no granular cache control). For full caching support,
  set `use_converse: false` to force native API with tools/structured output.
  """

  alias ReqLLM.Providers.AmazonBedrock
  alias ReqLLM.Providers.Anthropic

  @doc """
  Returns whether this model family supports toolChoice in Bedrock Converse API.
  """
  def supports_converse_tool_choice?, do: true

  @doc """
  Formats a ReqLLM context into Anthropic request format for Bedrock.

  Delegates to the native Anthropic.Context module and adds Bedrock-specific
  version parameter.

  For :object operations, creates a synthetic "structured_output" tool to
  leverage Claude's tool-calling for structured JSON output.
  """
  def format_request(_model_id, context, opts) do
    operation = opts[:operation]

    # For :object operation, we need to inject the structured_output tool
    {context, opts} =
      if operation == :object do
        prepare_structured_output_context(context, opts)
      else
        {context, opts}
      end

    # Create a fake model struct for Anthropic.Context.encode_request
    model = %{model: opts[:model] || "claude-3-sonnet"}

    # Delegate to native Anthropic context encoding
    body = Anthropic.Context.encode_request(context, model)

    # Remove model field - Bedrock specifies model in URL, not body
    body = Map.delete(body, :model)

    # Add Bedrock-specific parameters
    # Use 4096 for :object operations (need more tokens for structured output), 1024 otherwise
    default_max_tokens = if operation == :object, do: 4096, else: 1024

    body
    |> Map.put(:anthropic_version, "bedrock-2023-05-31")
    |> maybe_add_param(:max_tokens, opts[:max_tokens] || default_max_tokens)
    |> maybe_add_param(:temperature, opts[:temperature])
    |> maybe_add_param(:top_p, opts[:top_p])
    |> maybe_add_param(:top_k, opts[:top_k])
    |> maybe_add_param(:stop_sequences, opts[:stop_sequences])
    |> maybe_add_thinking(opts)
    |> maybe_add_tools(opts)
    |> Anthropic.maybe_apply_prompt_caching(opts)
  end

  # Create the synthetic structured_output tool for :object operations
  defp prepare_structured_output_context(context, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    # Create the structured_output tool (same as native Anthropic provider)
    structured_output_tool =
      ReqLLM.Tool.new!(
        name: "structured_output",
        description: "Generate structured output matching the provided schema",
        parameter_schema: compiled_schema.schema,
        callback: fn _args -> {:ok, "structured output generated"} end
      )

    # Add tool to context - Context may or may not have a tools field
    existing_tools = Map.get(context, :tools, [])
    updated_context = Map.put(context, :tools, [structured_output_tool | existing_tools])

    # Update opts to force tool choice
    updated_opts =
      opts
      |> Keyword.put(:tools, [structured_output_tool | Keyword.get(opts, :tools, [])])
      |> Keyword.put(:tool_choice, %{type: "tool", name: "structured_output"})

    {updated_context, updated_opts}
  end

  defp maybe_add_param(body, _key, nil), do: body
  defp maybe_add_param(body, key, value), do: Map.put(body, key, value)

  # Add tools from opts to request body (same as native Anthropic provider)
  # Bedrock-specific: If no tools in opts but messages contain tool_use/tool_result,
  # create stub tool definitions to satisfy Bedrock's validation
  defp maybe_add_tools(body, opts) do
    tools = Keyword.get(opts, :tools, [])

    tools =
      case tools do
        [] ->
          # Check if body has tool messages - if so, create stubs
          extract_stub_tools_if_needed(body)

        tools when is_list(tools) ->
          tools
      end

    case tools do
      [] ->
        body

      tools when is_list(tools) ->
        # Convert tools to Anthropic format (handles both ReqLLM.Tool structs and stub maps)
        anthropic_tools = Enum.map(tools, &tool_to_anthropic_format/1)
        body = Map.put(body, :tools, anthropic_tools)

        # Add tool_choice if specified
        case Keyword.get(opts, :tool_choice) do
          nil -> body
          choice -> Map.put(body, :tool_choice, choice)
        end
    end
  end

  # Extract stub tools from messages when Bedrock requires tools but none provided.
  # This handles multi-turn tool conversations where the caller didn't pass tools
  # on subsequent requests (works for other providers, but Bedrock is strict).
  defp extract_stub_tools_if_needed(body) do
    messages = Map.get(body, :messages, [])

    tool_names =
      messages
      |> Enum.flat_map(fn msg ->
        case msg do
          %{content: content} when is_list(content) ->
            content
            |> Enum.filter(fn
              %{type: "tool_use", name: _} -> true
              _ -> false
            end)
            |> Enum.map(fn %{name: name} -> name end)

          _ ->
            []
        end
      end)
      |> Enum.uniq()

    # Create minimal stub tools for validation
    Enum.map(tool_names, fn name ->
      %{
        name: name,
        description: "Tool stub for multi-turn conversation",
        input_schema: %{type: "object", properties: %{}}
      }
    end)
  end

  # Convert ReqLLM.Tool or stub map to Anthropic tool format
  defp tool_to_anthropic_format(%ReqLLM.Tool{} = tool) do
    schema = ReqLLM.Tool.to_schema(tool, :openai)

    %{
      name: schema["function"]["name"],
      description: schema["function"]["description"],
      input_schema: schema["function"]["parameters"]
    }
  end

  # Stub tools are already in Anthropic format
  defp tool_to_anthropic_format(%{name: _, description: _, input_schema: _} = stub), do: stub

  # Add extended thinking configuration for native Anthropic endpoint
  # Note: pre_validate_options already extracted reasoning params and added to additional_model_request_fields
  defp maybe_add_thinking(body, opts) do
    # Check if additional_model_request_fields has thinking config (from pre_validate_options)
    # Note: additional_model_request_fields is nested under :provider_options after Options.process
    case get_in(opts, [:provider_options, :additional_model_request_fields, :thinking]) do
      %{type: "enabled", budget_tokens: budget} ->
        Map.put(body, :thinking, %{type: "enabled", budget_tokens: budget})

      _ ->
        body
    end
  end

  @doc """
  Parses Anthropic response from Bedrock into ReqLLM format.

  Delegates to the native Anthropic.Response module.

  For :object operations, extracts the structured output from the tool call.
  """
  def parse_response(body, opts) when is_map(body) do
    # Create a model struct for Anthropic.Response.decode_response
    model = %ReqLLM.Model{
      provider: :anthropic,
      model: Map.get(body, "model", opts[:model] || "bedrock-anthropic")
    }

    # Delegate to native Anthropic response decoding
    case Anthropic.Response.decode_response(body, model) do
      {:ok, response} ->
        # For :object operation, extract structured output from tool call
        final_response =
          if opts[:operation] == :object do
            extract_and_set_object(response)
          else
            response
          end

        {:ok, final_response}

      error ->
        error
    end
  end

  # Extract structured output from tool call (same logic as native Anthropic provider)
  defp extract_and_set_object(response) do
    extracted_object =
      response
      |> ReqLLM.Response.tool_calls()
      |> ReqLLM.ToolCall.find_args("structured_output")

    %{response | object: extracted_object}
  end

  @doc """
  Parses a streaming chunk for Anthropic models.

  Unwraps the Bedrock-specific encoding then delegates to native Anthropic
  SSE event parsing.
  """
  def parse_stream_chunk(chunk, opts) when is_map(chunk) do
    # First, unwrap the Bedrock AWS event stream encoding
    with {:ok, event} <- AmazonBedrock.Response.unwrap_stream_chunk(chunk) do
      # Create a model struct for Anthropic.Response.decode_sse_event
      model = %ReqLLM.Model{
        provider: :anthropic,
        model: opts[:model] || "bedrock-anthropic"
      }

      # Delegate to native Anthropic SSE event parsing
      # decode_sse_event expects %{data: event_data} format
      chunks = Anthropic.Response.decode_sse_event(%{data: event}, model)

      # Return first chunk if any, or nil
      case chunks do
        [chunk | _] -> {:ok, chunk}
        [] -> {:ok, nil}
      end
    end
  rescue
    e -> {:error, "Failed to parse stream chunk: #{inspect(e)}"}
  end

  @doc """
  Extracts usage metadata from the response body.

  Delegates to the native Anthropic provider.

  Note: AWS Bedrock does not return a separate `reasoning_tokens` field in its
  response structure. Extended thinking tokens are included in `output_tokens`
  and billed accordingly, but Bedrock's API response only provides `input_tokens`
  and `output_tokens`. This differs from Anthropic's direct API which returns
  `reasoning_tokens` as a separate field.
  """
  def extract_usage(body, model) do
    # Delegate to native Anthropic extract_usage
    Anthropic.extract_usage(body, model)
  end
end

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
  alias ReqLLM.Providers.Anthropic.AdapterHelpers

  @doc """
  Returns whether this model family supports toolChoice in Bedrock Converse API.
  """
  def supports_converse_tool_choice?, do: true

  @doc """
  Preserve inference profile prefix for all Anthropic models.

  All Anthropic inference profile models require the region prefix to be preserved
  in the API request path.
  """
  def preserve_inference_profile?(_model_id), do: true

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
        AdapterHelpers.prepare_structured_output_context(context, opts)
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
    |> maybe_add_anthropic_beta(opts)
    |> AdapterHelpers.maybe_add_param(:max_tokens, opts[:max_tokens] || default_max_tokens)
    |> AdapterHelpers.maybe_add_param(:temperature, opts[:temperature])
    |> AdapterHelpers.maybe_add_param(:top_p, opts[:top_p])
    |> AdapterHelpers.maybe_add_param(:top_k, opts[:top_k])
    |> AdapterHelpers.maybe_add_param(:stop_sequences, opts[:stop_sequences])
    |> AdapterHelpers.maybe_add_thinking(opts)
    |> maybe_add_tools(opts)
    |> Anthropic.maybe_apply_prompt_caching(opts)
  end

  defp maybe_add_anthropic_beta(body, opts) do
    case get_in(opts, [:provider_options, :anthropic_beta]) do
      betas when is_list(betas) and betas != [] ->
        Map.put(body, :anthropic_beta, betas)

      _ ->
        body
    end
  end

  # Add tools from opts to request body (same as native Anthropic provider)
  # Bedrock-specific: If no tools in opts but messages contain tool_use/tool_result,
  # create stub tool definitions to satisfy Bedrock's validation
  defp maybe_add_tools(body, opts) do
    tools = Keyword.get(opts, :tools, [])

    tools =
      case tools do
        [] ->
          AdapterHelpers.extract_stub_tools_from_messages(body)

        tools when is_list(tools) ->
          tools
      end

    case tools do
      [] ->
        body

      tools when is_list(tools) ->
        anthropic_tools = Enum.map(tools, &tool_to_anthropic_format/1)
        body = Map.put(body, :tools, anthropic_tools)

        case Keyword.get(opts, :tool_choice) do
          nil -> body
          choice -> Map.put(body, :tool_choice, choice)
        end
    end
  end

  # Convert ReqLLM.Tool or stub map to Anthropic tool format
  defp tool_to_anthropic_format(%ReqLLM.Tool{} = tool) do
    # Use the public helper from native Anthropic provider
    Anthropic.tool_to_anthropic_format(tool)
  end

  # Stub tools are already in Anthropic format
  defp tool_to_anthropic_format(%{name: _, description: _, input_schema: _} = stub), do: stub

  @doc """
  Parses Anthropic response from Bedrock into ReqLLM format.

  Delegates to the native Anthropic.Response module.

  For :object operations, extracts the structured output from the tool call.
  """
  def parse_response(body, opts) when is_map(body) do
    # Create a model struct for Anthropic.Response.decode_response
    model_id =
      ReqLLM.ModelId.normalize(Map.get(body, "model") || opts[:model], "bedrock-anthropic")

    model = LLMDB.Model.new!(%{id: model_id, provider: :anthropic})

    case Anthropic.Response.decode_response(body, model) do
      {:ok, response} ->
        input_context = opts[:context] || %ReqLLM.Context{messages: []}
        merged_response = ReqLLM.Context.merge_response(input_context, response)

        final_response =
          if opts[:operation] == :object do
            AdapterHelpers.extract_and_set_object(merged_response)
          else
            merged_response
          end

        {:ok, final_response}

      error ->
        error
    end
  end

  @doc """
  Parses a streaming chunk for Anthropic models.

  Unwraps the Bedrock-specific encoding then delegates to native Anthropic
  SSE event parsing.
  """
  def parse_stream_chunk(chunk, opts) when is_map(chunk) do
    # First, unwrap the Bedrock AWS event stream encoding
    with {:ok, event} <- AmazonBedrock.Response.unwrap_stream_chunk(chunk) do
      # Create a model struct for Anthropic.Response.decode_stream_event
      model_id = ReqLLM.ModelId.normalize(opts[:model], "bedrock-anthropic")
      model = LLMDB.Model.new!(%{id: model_id, provider: :anthropic})

      # Delegate to native Anthropic SSE event parsing
      # decode_stream_event expects %{data: event_data} format
      chunks = Anthropic.Response.decode_stream_event(%{data: event}, model)

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

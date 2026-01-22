defmodule ReqLLM.Providers.Azure.Anthropic do
  @moduledoc """
  Anthropic model family support for Azure.

  Handles Claude models deployed on Azure's infrastructure.

  This module acts as a thin adapter between Azure's API and Anthropic's native
  message format. It delegates to the native Anthropic modules for all format
  conversion.

  ## Key Differences from Native Anthropic

  - Uses `x-api-key` header (same as native Anthropic, set by parent Azure provider)
  - URL is `/v1/messages` (model specified in body, like native Anthropic)
  - The `anthropic-version` header is set by the parent `Azure` provider via
    `get_anthropic_headers/2`, configurable with `anthropic_version` option

  ## Prompt Caching Support

  Full Anthropic prompt caching is supported. Enable with `anthropic_prompt_cache: true` option.

  ## Extended Thinking Support

  Extended thinking (reasoning) is supported for models that have the capability.
  Enable with `reasoning_effort: :low | :medium | :high` option.

  **Important constraints:**
  - Temperature is automatically set to 1.0 when reasoning is enabled, overriding any user-provided value (required by Anthropic)
  - If provider option translation changes temperature after reasoning is enabled, thinking will be disabled
  - Models without reasoning capability will log a warning and ignore reasoning params

  ## Structured Output

  Structured output is supported via tool-calling. Use `generate_object/4` with a schema.

  Note: Native Anthropic's `json_schema` structured output mode (beta) is not available on Azure.
  Azure uses the tool-based approach which is stable and well-supported.

  ## Tool Calling

  When no explicit tools are provided but the conversation history contains tool_use
  blocks, stub tool definitions are automatically extracted from the messages to
  satisfy Anthropic's validation requirements.

  ## Streaming

  Streaming is fully supported using the same SSE format as native Anthropic.
  The parent `Azure` provider handles `attach_stream/4` for building streaming
  requests; this module provides `decode_stream_event/2` for parsing SSE events.
  Usage information is automatically included in streaming responses.
  """

  alias ReqLLM.Providers.Anthropic
  alias ReqLLM.Providers.Anthropic.AdapterHelpers
  alias ReqLLM.Providers.Anthropic.PlatformReasoning

  require Logger

  @doc """
  Pre-validates and transforms options for Claude models on Azure.
  Handles reasoning_effort/reasoning_token_budget translation to thinking config.
  Warns if json_schema response_format is attempted (not supported on Azure).
  """
  def pre_validate_options(_operation, model, opts) do
    opts = maybe_translate_reasoning_params(model, opts)
    opts = warn_if_json_schema_response_format(opts)
    opts = warn_if_openai_specific_options(opts)
    {opts, []}
  end

  defp warn_if_json_schema_response_format(opts) do
    provider_opts = opts[:provider_options] || []
    response_format = opts[:response_format] || provider_opts[:response_format]

    is_json_schema =
      case response_format do
        %{type: "json_schema"} -> true
        %{"type" => "json_schema"} -> true
        _ -> false
      end

    if is_json_schema do
      Logger.warning(
        "response_format with json_schema is not supported for Claude models on Azure. " <>
          "Use generate_object/4 with a schema instead (tool-based structured output)."
      )

      opts
      |> Keyword.delete(:response_format)
      |> Keyword.update(:provider_options, [], &Keyword.delete(&1, :response_format))
    else
      opts
    end
  end

  defp warn_if_openai_specific_options(opts) do
    provider_opts = opts[:provider_options] || []

    if provider_opts[:service_tier] do
      Logger.warning(
        "service_tier is an OpenAI-specific option and is ignored for Claude models on Azure."
      )

      updated_provider_opts = Keyword.delete(provider_opts, :service_tier)
      Keyword.put(opts, :provider_options, updated_provider_opts)
    else
      opts
    end
  end

  @doc """
  Formats a ReqLLM context into Anthropic request format for Azure.

  Delegates to the native Anthropic.Context module and adjusts for Azure's
  deployment-based routing (no model field in body).

  For :object operations, creates a synthetic "structured_output" tool to
  leverage Claude's tool-calling for structured JSON output.
  """
  def format_request(model_id, context, opts) do
    operation = opts[:operation]

    {context, opts} =
      if operation == :object do
        AdapterHelpers.prepare_structured_output_context(context, opts)
      else
        {context, opts}
      end

    model = %{model: model_id}

    body = Anthropic.Context.encode_request(context, model)

    default_max_tokens = if operation == :object, do: 4096, else: 1024

    body
    |> AdapterHelpers.maybe_add_param(:max_tokens, opts[:max_tokens] || default_max_tokens)
    |> AdapterHelpers.maybe_add_param(:temperature, opts[:temperature])
    |> AdapterHelpers.maybe_add_param(:top_p, opts[:top_p])
    |> AdapterHelpers.maybe_add_param(:top_k, opts[:top_k])
    |> AdapterHelpers.maybe_add_param(:stop_sequences, opts[:stop_sequences])
    |> AdapterHelpers.maybe_add_param(:stream, opts[:stream])
    |> AdapterHelpers.maybe_add_thinking(opts)
    |> maybe_add_tools(opts)
    |> Anthropic.maybe_apply_prompt_caching(opts)
  end

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

  defp tool_to_anthropic_format(%ReqLLM.Tool{} = tool) do
    Anthropic.tool_to_anthropic_format(tool)
  end

  defp tool_to_anthropic_format(%{name: _, description: _, input_schema: _} = stub), do: stub

  @doc """
  Parses Anthropic response from Azure into ReqLLM format.

  Delegates to the native Anthropic.Response module.

  For :object operations, extracts the structured output from the tool call.

  Note: Azure responses don't include a "model" field since the deployment
  determines the model. We use the azure_model.id for response tracking.
  """
  def parse_response(body, %LLMDB.Model{} = azure_model, opts) when is_map(body) do
    model_id =
      if azure_model.id do
        azure_model.id
      else
        Logger.debug(
          "Azure model ID is nil, using fallback 'azure-anthropic' for response tracking"
        )

        "azure-anthropic"
      end

    anthropic_model = %LLMDB.Model{
      id: model_id,
      provider: :anthropic
    }

    case Anthropic.Response.decode_response(body, anthropic_model) do
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
  Decodes Server-Sent Events for streaming responses.

  Delegates to native Anthropic SSE event parsing since Azure uses the same
  streaming format.
  """
  def decode_stream_event(event, model) do
    Anthropic.Response.decode_stream_event(event, model)
  end

  @doc """
  Extracts usage metadata from the response body.

  Delegates to the native Anthropic provider.
  """
  def extract_usage(body, model) do
    Anthropic.extract_usage(body, model)
  end

  @doc """
  Anthropic Claude models do not support embeddings.

  Note: This function should never be called under normal operation. The parent
  `Azure` provider validates embedding requests and rejects Claude models with
  a proper error tuple before reaching this point. This exists only as a safety
  net for direct formatter calls.
  """
  def format_embedding_request(_model_id, _text, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "Claude models do not support embeddings. Use an OpenAI embedding model."
     )}
  end

  @doc """
  Cleans up thinking config if incompatible with other options.

  Delegates to shared PlatformReasoning module.
  See `ReqLLM.Providers.Anthropic.PlatformReasoning.maybe_clean_thinking_after_translation/2`.
  """
  def maybe_clean_thinking_after_translation(opts, operation) do
    PlatformReasoning.maybe_clean_thinking_after_translation(opts, operation)
  end

  defp maybe_translate_reasoning_params(model, opts) do
    {reasoning_effort, opts} = Keyword.pop(opts, :reasoning_effort)
    {reasoning_budget, opts} = Keyword.pop(opts, :reasoning_token_budget)

    has_reasoning =
      get_in(model, [Access.key(:capabilities), Access.key(:reasoning), Access.key(:enabled)]) ==
        true

    cond do
      has_reasoning && reasoning_budget && is_integer(reasoning_budget) ->
        opts
        |> PlatformReasoning.add_reasoning_to_additional_fields(reasoning_budget)
        |> ensure_min_max_tokens(reasoning_budget)
        |> set_reasoning_temperature(model)

      has_reasoning && reasoning_effort ->
        budget = Anthropic.map_reasoning_effort_to_budget(reasoning_effort)

        opts
        |> PlatformReasoning.add_reasoning_to_additional_fields(budget)
        |> ensure_min_max_tokens(budget)
        |> set_reasoning_temperature(model)

      (reasoning_effort || reasoning_budget) && !has_reasoning ->
        Logger.warning(
          "Reasoning parameters ignored: model #{inspect(model.id)} does not support extended thinking"
        )

        opts

      true ->
        opts
    end
  end

  defp set_reasoning_temperature(opts, model) do
    existing_temp = Keyword.get(opts, :temperature)

    if existing_temp && existing_temp != 1.0 do
      Logger.warning(
        "Extended thinking requires temperature=1.0 for model #{inspect(model.id)}. " <>
          "Overriding your temperature=#{existing_temp} setting."
      )
    end

    Keyword.put(opts, :temperature, 1.0)
  end

  defp ensure_min_max_tokens(opts, budget_tokens) do
    min_tokens = budget_tokens + 201
    Keyword.update(opts, :max_tokens, min_tokens, fn current -> max(current, min_tokens) end)
  end
end

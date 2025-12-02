defmodule ReqLLM.Providers.Azure.OpenAI do
  @moduledoc """
  OpenAI model family support for Azure OpenAI Service.

  Handles OpenAI models (GPT-4o, GPT-4, etc.) deployed on Azure.

  This module acts as a thin adapter between Azure's deployment-based API
  and OpenAI's native Chat Completions format, delegating encoding to
  `ReqLLM.Provider.Defaults` and applying Azure-specific modifications.

  ## Key Differences from Standard OpenAI

  - No `model` field in request body (deployment determines the model)
  - Uses same message and tool format as OpenAI Chat API

  ## Reasoning Model Support

  For reasoning models (o1, o3, o4, gpt-4.1, gpt-5), this module automatically:
  - Uses `max_completion_tokens` instead of `max_tokens`
  - Supports `reasoning_effort` option (via provider_options)

  ## Structured Output Support

  Structured output is supported via tools with strict mode. When a tool has
  `strict: true`, this module automatically:
  - Sets `additionalProperties: false` on the parameters schema
  - Makes all properties required

  For structured output generation, use `ReqLLM.generate_object/4` which creates
  a synthetic tool to enforce the output schema.

  ## Additional Options

  - `n`: Number of completions to generate (integer, default 1)
  - `parallel_tool_calls`: Whether to allow parallel tool calls (boolean)
  - `service_tier`: Request prioritization ("auto", "default", "priority")
  """

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  alias ReqLLM.Provider.Defaults
  alias ReqLLM.Providers.OpenAI.AdapterHelpers

  require Logger
  require ReqLLM.Debug, as: Debug

  # Model prefixes that use OpenAI-compatible API format
  @openai_compatible_prefixes ["gpt", "o1", "o3", "o4", "text-embedding", "deepseek", "mai-ds"]

  @anthropic_specific_options [
    :anthropic_prompt_cache,
    :anthropic_prompt_cache_ttl,
    :anthropic_version
  ]

  @doc """
  Pre-validates and transforms options for OpenAI models on Azure.
  Warns if Anthropic-specific options are passed.
  """
  def pre_validate_options(_operation, _model, opts) do
    opts
    |> warn_and_remove_anthropic_options()
    |> warn_and_remove_anthropic_thinking_config()
    |> then(&{&1, []})
  end

  defp warn_and_remove_anthropic_options(opts) do
    case opts[:provider_options] do
      provider_opts when is_list(provider_opts) ->
        found_anthropic_opts =
          @anthropic_specific_options
          |> Enum.filter(&Keyword.has_key?(provider_opts, &1))

        if found_anthropic_opts == [] do
          opts
        else
          Logger.warning(
            "Options #{inspect(found_anthropic_opts)} are Anthropic-specific and are ignored for OpenAI models on Azure."
          )

          updated_provider_opts = Keyword.drop(provider_opts, found_anthropic_opts)

          Keyword.put(opts, :provider_options, updated_provider_opts)
        end

      _ ->
        opts
    end
  end

  defp warn_and_remove_anthropic_thinking_config(opts) do
    case opts[:provider_options] do
      provider_opts when is_list(provider_opts) ->
        amrf = provider_opts[:additional_model_request_fields]

        case amrf do
          %{thinking: _} ->
            warn_and_remove_thinking(opts, provider_opts, amrf)

          %{"thinking" => _} ->
            warn_and_remove_thinking(opts, provider_opts, amrf)

          _ ->
            opts
        end

      _ ->
        opts
    end
  end

  defp warn_and_remove_thinking(opts, provider_opts, amrf) do
    Logger.warning(
      "additional_model_request_fields with thinking config is Anthropic-specific " <>
        "and is ignored for OpenAI models on Azure. " <>
        "For OpenAI reasoning models, use reasoning_effort instead."
    )

    updated_amrf = Map.drop(amrf, [:thinking, "thinking"])

    updated_provider_opts =
      if map_size(updated_amrf) == 0 do
        Keyword.delete(provider_opts, :additional_model_request_fields)
      else
        Keyword.put(provider_opts, :additional_model_request_fields, updated_amrf)
      end

    Keyword.put(opts, :provider_options, updated_provider_opts)
  end

  @doc """
  Formats a ReqLLM context into OpenAI Chat Completions request format.

  Delegates encoding to `ReqLLM.Provider.Defaults.default_encode_body/1` then
  applies Azure-specific modifications:
  - Removes `model` field (Azure uses deployment-based routing)
  - Adds token limits appropriate for model type (reasoning vs standard)
  - Adds Azure-specific options (service_tier, reasoning_effort)

  Returns a map ready to be JSON-encoded for the Azure OpenAI API.
  """
  def format_request(model_id, context, opts) do
    warn_if_non_openai_model(model_id)
    provider_opts = opts[:provider_options] || []

    temp_request =
      Req.new(method: :post, url: URI.parse("https://example.com/temp"))
      |> Map.put(:body, {:json, %{}})
      |> Map.put(
        :options,
        Map.new(
          [
            model: model_id,
            context: context,
            operation: opts[:operation] || :chat,
            tools: opts[:tools] || []
          ] ++ Keyword.drop(opts, [:model, :tools, :operation, :provider_options])
        )
      )

    encoded_request = Defaults.default_encode_body(temp_request)

    body =
      case encoded_request.body do
        "" -> %{}
        json_string -> Jason.decode!(json_string)
      end

    final_body =
      body
      |> Map.delete("model")
      |> AdapterHelpers.add_token_limits(model_id, opts)
      |> maybe_put(:n, opts[:n])
      |> maybe_put(:reasoning_effort, provider_opts[:reasoning_effort])
      |> maybe_put(:service_tier, provider_opts[:service_tier])
      |> add_stream_options(opts)
      |> AdapterHelpers.add_parallel_tool_calls(opts, provider_opts)
      |> AdapterHelpers.translate_tool_choice_format()
      |> AdapterHelpers.add_strict_to_tools()
      |> AdapterHelpers.add_response_format(provider_opts)

    Debug.dbug(
      fn -> "Azure OpenAI request body: #{Jason.encode!(final_body, pretty: true)}" end,
      component: :provider
    )

    final_body
  end

  defp warn_if_non_openai_model(model_id) do
    if !Enum.any?(@openai_compatible_prefixes, &String.starts_with?(model_id, &1)) do
      Logger.warning(
        "Model '#{model_id}' does not appear to be OpenAI-compatible. " <>
          "Expected prefix: #{Enum.join(@openai_compatible_prefixes, ", ")}. " <>
          "Proceeding with OpenAI formatting (may fail)."
      )
    end
  end

  defp add_stream_options(body, opts) do
    if opts[:stream] do
      maybe_put(body, :stream_options, %{include_usage: true})
    else
      body
    end
  end

  @doc """
  Formats an embedding request for Azure OpenAI.

  Embedding-specific options (`dimensions`, `encoding_format`) are read from
  `provider_options` where they are placed after schema validation and hoisting.
  """
  def format_embedding_request(_model_id, text, opts) do
    provider_opts = opts[:provider_options] || []

    %{input: text}
    |> maybe_put(:user, opts[:user])
    |> maybe_put(:dimensions, provider_opts[:dimensions])
    |> maybe_put(:encoding_format, provider_opts[:encoding_format])
  end

  @doc """
  Parses an Azure OpenAI response into ReqLLM format.

  Uses the centralized OpenAI response decoding from Provider.Defaults.
  """
  def parse_response(body, model, opts) do
    context = opts[:context] || %ReqLLM.Context{messages: []}
    operation = opts[:operation]

    {:ok, response} = Defaults.decode_response_body_openai_format(body, model)

    merged_response = ReqLLM.Context.merge_response(context, response)

    final_response =
      if operation == :object do
        extract_and_set_object(merged_response)
      else
        merged_response
      end

    {:ok, final_response}
  end

  defp extract_and_set_object(response) do
    extracted_object =
      response
      |> ReqLLM.Response.tool_calls()
      |> ReqLLM.ToolCall.find_args("structured_output")

    %{response | object: extracted_object}
  end

  @doc """
  Extracts usage information from Azure OpenAI response.

  Includes all available fields: input_tokens, output_tokens, total_tokens,
  cached_tokens (from prompt_tokens_details), and reasoning_tokens
  (from completion_tokens_details for o1/o3 models).
  """
  def extract_usage(body, _model) when is_map(body) do
    case body do
      %{"usage" => usage} ->
        cached = get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0
        reasoning = get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) || 0

        {:ok,
         %{
           input_tokens: Map.get(usage, "prompt_tokens", 0),
           output_tokens: Map.get(usage, "completion_tokens", 0),
           total_tokens: Map.get(usage, "total_tokens", 0),
           cached_tokens: cached,
           reasoning_tokens: reasoning
         }}

      _ ->
        {:error, :no_usage}
    end
  end

  def extract_usage(_, _), do: {:error, :no_usage}

  @doc """
  Decodes Server-Sent Events for streaming responses.

  Uses the same SSE format as standard OpenAI.
  """
  def decode_stream_event(event, model) do
    ReqLLM.Provider.Defaults.default_decode_stream_event(event, model)
  end
end

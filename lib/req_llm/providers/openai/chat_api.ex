defmodule ReqLLM.Providers.OpenAI.ChatAPI do
  @moduledoc """
  OpenAI Chat Completions API driver.

  Implements the `ReqLLM.Providers.OpenAI.API` behaviour for OpenAI's Chat Completions endpoint.

  ## Endpoint

  `/v1/chat/completions`

  ## Supported Models

  - GPT-4 family: gpt-4o, gpt-4-turbo, gpt-4
  - GPT-3.5 family: gpt-3.5-turbo
  - Embedding models: text-embedding-3-small, text-embedding-3-large, text-embedding-ada-002
  - Other chat-based models with `"api": "chat"` metadata

  ## Capabilities

  - **Streaming**: Full SSE support with usage tracking via `stream_options`
  - **Tools**: Function calling with tool_choice format conversion
  - **Embeddings**: Dimension and encoding format control
  - **Multi-modal**: Text and image inputs
  - **Token limits**: Automatic handling of max_tokens vs max_completion_tokens

  ## Encoding Specifics

  - Converts internal `tool_choice` format to OpenAI's function-based format
  - Adds `stream_options: {include_usage: true}` for streaming usage metrics
  - Handles reasoning model parameter requirements (max_completion_tokens)
  - Supports embedding-specific options (dimensions, encoding_format)

  ## Decoding

  Uses default OpenAI Chat Completions response format:
  - Standard message structure with role/content
  - Tool calls in OpenAI's native format
  - Usage metrics: input_tokens, output_tokens, total_tokens
  """
  @behaviour ReqLLM.Providers.OpenAI.API

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  require ReqLLM.Debug, as: Debug

  @impl true
  def path, do: "/chat/completions"

  @impl true
  def encode_body(request) do
    context = request.options[:context]
    model_name = request.options[:model]
    operation = request.options[:operation] || :chat
    opts = if is_map(request.options), do: Map.to_list(request.options), else: request.options

    enhanced_body = build_request_body(context, model_name, opts, operation)

    Debug.dbug(
      fn -> "OpenAI ChatAPI request body: #{Jason.encode!(enhanced_body, pretty: true)}" end,
      component: :provider
    )

    Map.put(request, :body, Jason.encode!(enhanced_body))
  end

  @impl true
  def decode_response(response) do
    ReqLLM.Provider.Defaults.default_decode_response(response)
  end

  @impl true
  def decode_stream_event(event, model) do
    ReqLLM.Provider.Defaults.default_decode_stream_event(event, model)
  end

  # ========================================================================
  # Shared Request Building Helpers (used by both Req and Finch paths)
  # ========================================================================

  defp build_request_headers(model, opts) do
    api_key = ReqLLM.Keys.get!(model, opts)

    [
      {"Authorization", "Bearer " <> api_key},
      {"Content-Type", "application/json"}
    ]
  end

  defp build_request_body(context, model_name, opts, operation \\ :chat) do
    temp_request =
      Req.new(method: :post, url: URI.parse("https://example.com/temp"))
      |> Map.put(:body, {:json, %{}})
      |> Map.put(
        :options,
        Map.new([model: model_name, context: context, operation: operation] ++ opts)
      )

    request = ReqLLM.Provider.Defaults.default_encode_body(temp_request)

    body =
      case request.body do
        "" -> %{}
        json_string when is_binary(json_string) -> Jason.decode!(json_string)
      end

    # Convert opts to map for helper functions that expect request.options
    opts_map = if is_list(opts), do: Map.new(opts), else: opts

    # Apply ChatAPI-specific enhancements
    case operation do
      :embedding ->
        add_embedding_options(body, opts_map)

      _ ->
        body
        |> add_token_limits(model_name, opts_map)
        |> add_stream_options(opts_map)
        |> add_reasoning_effort(opts_map)
        |> add_response_format(opts_map)
        |> add_parallel_tool_calls(opts_map)
        |> translate_tool_choice_format()
        |> add_strict_to_tools()
    end
  end

  defp build_request_url(opts) do
    case Keyword.get(opts, :base_url) do
      nil -> ReqLLM.Providers.OpenAI.base_url() <> path()
      base_url -> "#{base_url}#{path()}"
    end
  end

  # ========================================================================

  @impl true
  def attach_stream(model, context, opts, _finch_name) do
    headers = build_request_headers(model, opts) ++ [{"Accept", "text/event-stream"}]

    base_url = ReqLLM.Provider.Options.effective_base_url(ReqLLM.Providers.OpenAI, model, opts)

    cleaned_opts =
      opts
      |> Keyword.delete(:finch_name)
      |> Keyword.delete(:compiled_schema)
      |> Keyword.put(:stream, true)
      |> Keyword.put(:base_url, base_url)

    body = build_request_body(context, model.id, cleaned_opts)
    url = build_request_url(cleaned_opts)

    {:ok, Finch.build(:post, url, headers, Jason.encode!(body))}
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build streaming request: #{Exception.message(error)}"
       )}
  end

  defp add_embedding_options(body, request_options) do
    body
    |> maybe_put(:dimensions, request_options[:dimensions])
    |> maybe_put(:encoding_format, request_options[:encoding_format])
  end

  defp add_token_limits(body, model_name, request_options) do
    body = Map.delete(body, "max_tokens") |> Map.delete("max_completion_tokens")

    if reasoning_model_name?(model_name) do
      maybe_put(
        body,
        :max_completion_tokens,
        request_options[:max_completion_tokens] || request_options[:max_tokens]
      )
    else
      body
      |> maybe_put(:max_tokens, request_options[:max_tokens])
      |> maybe_put(:max_completion_tokens, request_options[:max_completion_tokens])
    end
  end

  defp reasoning_model_name?("gpt-5-chat-latest"), do: false
  defp reasoning_model_name?(<<"gpt-5", _::binary>>), do: true
  defp reasoning_model_name?(<<"gpt-4.1", _::binary>>), do: true
  defp reasoning_model_name?(<<"o1", _::binary>>), do: true
  defp reasoning_model_name?(<<"o3", _::binary>>), do: true
  defp reasoning_model_name?(<<"o4", _::binary>>), do: true
  defp reasoning_model_name?(_), do: false

  defp add_stream_options(body, request_options) do
    if request_options[:stream] do
      maybe_put(body, :stream_options, %{include_usage: true})
    else
      body
    end
  end

  defp add_reasoning_effort(body, request_options) do
    provider_opts = request_options[:provider_options] || []
    maybe_put(body, :reasoning_effort, provider_opts[:reasoning_effort])
  end

  defp translate_tool_choice_format(body) do
    {tool_choice, body_key} =
      cond do
        Map.has_key?(body, :tool_choice) -> {Map.get(body, :tool_choice), :tool_choice}
        Map.has_key?(body, "tool_choice") -> {Map.get(body, "tool_choice"), "tool_choice"}
        true -> {nil, nil}
      end

    case tool_choice do
      map when is_map(map) ->
        type = Map.get(tool_choice, :type) || Map.get(tool_choice, "type")
        name = Map.get(tool_choice, :name) || Map.get(tool_choice, "name")

        if type == "tool" && name do
          replacement =
            if is_map_key(tool_choice, :type) do
              %{type: "function", function: %{name: name}}
            else
              %{"type" => "function", "function" => %{"name" => name}}
            end

          Map.put(body, body_key, replacement)
        else
          body
        end

      atom when not is_nil(atom) and is_atom(atom) ->
        Map.put(body, body_key, to_string(atom))

      _ ->
        body
    end
  end

  defp add_response_format(body, request_options) do
    provider_opts = request_options[:provider_options] || []
    rf = provider_opts[:response_format]

    normalized =
      case rf do
        %{type: "json_schema", json_schema: %{schema: schema}} = m when is_list(schema) ->
          put_in(m, [:json_schema, :schema], ReqLLM.Schema.to_json(schema))

        %{"type" => "json_schema", "json_schema" => %{"schema" => schema}} = m
        when is_list(schema) ->
          js = ReqLLM.Schema.to_json(schema)
          %{m | "json_schema" => Map.put(m["json_schema"], "schema", js)}

        _ ->
          rf
      end

    body
    |> Map.drop(["response_format", :response_format])
    |> maybe_put(:response_format, normalized)
  end

  defp add_parallel_tool_calls(body, request_options) do
    provider_opts = request_options[:provider_options] || []

    ptc =
      request_options[:parallel_tool_calls] ||
        provider_opts[:openai_parallel_tool_calls] ||
        provider_opts[:parallel_tool_calls]

    maybe_put(body, :parallel_tool_calls, ptc)
  end

  defp add_strict_to_tools(body) do
    tools = body[:tools] || body["tools"]

    if tools && is_list(tools) do
      updated_tools =
        Enum.map(tools, fn tool ->
          function = tool[:function] || tool["function"]

          if function && (function[:strict] || function["strict"]) do
            function_with_strict =
              if is_map_key(tool, :function) do
                function
                |> Map.put(:strict, true)
                |> ensure_all_properties_required()
              else
                function
                |> Map.put("strict", true)
                |> ensure_all_properties_required()
              end

            if is_map_key(tool, :function) do
              Map.put(tool, :function, function_with_strict)
            else
              Map.put(tool, "function", function_with_strict)
            end
          else
            tool
          end
        end)

      if is_map_key(body, :tools) do
        Map.put(body, :tools, updated_tools)
      else
        Map.put(body, "tools", updated_tools)
      end
    else
      body
    end
  end

  defp ensure_all_properties_required(function) do
    params = function[:parameters] || function["parameters"]

    if params do
      properties = params[:properties] || params["properties"]

      if properties && is_map(properties) do
        all_property_names = Map.keys(properties)

        updated_params =
          if is_map_key(params, :properties) do
            params
            |> Map.put(:required, all_property_names)
            |> Map.put(:additionalProperties, false)
          else
            params
            |> Map.put("required", Enum.map(all_property_names, &to_string/1))
            |> Map.put("additionalProperties", false)
          end

        if is_map_key(function, :parameters) do
          Map.put(function, :parameters, updated_params)
        else
          Map.put(function, "parameters", updated_params)
        end
      else
        function
      end
    else
      function
    end
  end
end

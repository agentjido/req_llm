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

  @impl true
  def path, do: "/chat/completions"

  @impl true
  def encode_body(request) do
    request = ReqLLM.Provider.Defaults.default_encode_body(request)
    body = Jason.decode!(request.body)

    enhanced_body =
      case request.options[:operation] do
        :embedding ->
          add_embedding_options(body, request.options)

        _ ->
          body
          |> add_token_limits(request.options[:model], request.options)
          |> add_stream_options(request.options)
          |> add_reasoning_effort(request.options)
          |> add_response_format(request.options)
          |> add_parallel_tool_calls(request.options)
          |> translate_tool_choice_format()
          |> add_strict_to_tools()
      end

    Map.put(request, :body, Jason.encode!(enhanced_body))
  end

  @impl true
  def decode_response(response) do
    ReqLLM.Provider.Defaults.default_decode_response(response)
  end

  @impl true
  def decode_sse_event(event, model) do
    ReqLLM.Provider.Defaults.default_decode_sse_event(event, model)
  end

  @impl true
  def attach_stream(model, context, opts, _finch_name) do
    api_key = ReqLLM.Keys.get!(model, opts)

    headers = [
      {"Authorization", "Bearer " <> api_key},
      {"Content-Type", "application/json"},
      {"Accept", "text/event-stream"}
    ]

    url =
      case Keyword.get(opts, :base_url) do
        nil -> ReqLLM.Providers.OpenAI.default_base_url() <> path()
        base_url -> "#{base_url}#{path()}"
      end

    provider_opts = opts |> Keyword.get(:provider_options, []) |> Map.new()

    cleaned_opts =
      opts
      |> Keyword.delete(:finch_name)
      |> Keyword.delete(:compiled_schema)
      |> Keyword.delete(:provider_options)

    req_opts =
      [
        model: model.model,
        context: context,
        stream: true,
        provider_options: provider_opts
      ] ++ cleaned_opts

    options =
      req_opts
      |> Enum.reduce(%{}, fn
        {key, value}, acc when is_list(value) ->
          Map.put(acc, key, Map.new(value))

        {key, value}, acc ->
          Map.put(acc, key, value)
      end)

    temp_request = %Req.Request{
      method: :post,
      url: URI.parse("https://example.com/temp"),
      headers: %{},
      body: {:json, %{}},
      options: options
    }

    encoded_request = encode_body(temp_request)
    body = encoded_request.body

    {:ok, Finch.build(:post, url, headers, body)}
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
    if is_reasoning_model_name?(model_name) do
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

  defp is_reasoning_model_name?("gpt-5-chat-latest"), do: false
  defp is_reasoning_model_name?(<<"gpt-5", _::binary>>), do: true
  defp is_reasoning_model_name?(<<"gpt-4.1", _::binary>>), do: true
  defp is_reasoning_model_name?(<<"o1", _::binary>>), do: true
  defp is_reasoning_model_name?(<<"o3", _::binary>>), do: true
  defp is_reasoning_model_name?(<<"o4", _::binary>>), do: true
  defp is_reasoning_model_name?(_), do: false

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

    type = tool_choice && (Map.get(tool_choice, :type) || Map.get(tool_choice, "type"))
    name = tool_choice && (Map.get(tool_choice, :name) || Map.get(tool_choice, "name"))

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
  end

  defp add_response_format(body, request_options) do
    provider_opts = request_options[:provider_options] || []
    maybe_put(body, :response_format, provider_opts[:response_format])
  end

  defp add_parallel_tool_calls(body, request_options) do
    maybe_put(body, :parallel_tool_calls, request_options[:parallel_tool_calls])
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
                Map.put(function, :strict, true)
              else
                Map.put(function, "strict", true)
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
end

defmodule ReqLLM.Providers.XAI do
  @moduledoc """
  xAI (Grok) provider – OpenAI Chat Completions compatible with xAI's models and features.

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults.
  No custom wrapper modules – leverages the standard OpenAI-compatible implementations.

  ## xAI-Specific Extensions

  Beyond standard OpenAI parameters, xAI supports:
  - `max_completion_tokens` - Preferred over max_tokens for Grok-4 models
  - `reasoning_effort` - Reasoning level (low, medium, high) for Grok-3 mini models only
  - `search_parameters` - Live Search configuration with web search capabilities
  - `parallel_tool_calls` - Allow parallel function calls (default: true)
  - `stream_options` - Streaming configuration (include_usage)

  ## Model Compatibility Notes

  - `reasoning_effort` is only supported for grok-3-mini and grok-3-mini-fast models
  - Grok-4 models do not support `stop`, `presence_penalty`, or `frequency_penalty`
  - Live Search via `search_parameters` incurs additional costs per source

  See `provider_schema/0` for the complete xAI-specific schema and
  `ReqLLM.Provider.Options` for inherited OpenAI parameters.

  ## Configuration

      # Add to .env file (automatically loaded)
      XAI_API_KEY=xai-...
  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :xai,
    base_url: "https://api.x.ai/v1",
    metadata: "priv/models_dev/xai.json",
    default_env_key: "XAI_API_KEY",
    provider_schema: [
      max_completion_tokens: [
        type: :integer,
        doc: "Maximum completion tokens (preferred over max_tokens for Grok-4)"
      ],
      search_parameters: [
        type: :map,
        doc: "Live Search configuration with mode, sources, dates, and citations"
      ],
      parallel_tool_calls: [
        type: :boolean,
        doc: "Allow parallel function calls (default: true)"
      ],
      stream_options: [
        type: :map,
        doc: "Streaming options including usage reporting"
      ]
    ]

  use ReqLLM.Provider.Defaults

  import ReqLLM.Provider.Utils,
    only: [maybe_put: 3, maybe_put_skip: 4, ensure_parsed_body: 1]

  require Logger

  @doc """
  Custom prepare_request for :object operations to maintain xAI-specific max_completion_tokens handling.

  Ensures that structured output requests have adequate token limits while delegating
  other operations to the default implementation.
  """
  @impl ReqLLM.Provider
  def prepare_request(:object, model_spec, prompt, opts) do
    max_tokens = Keyword.get(opts, :max_tokens) || Keyword.get(opts, :max_completion_tokens)

    opts_with_tokens =
      case max_tokens do
        nil ->
          Keyword.put(opts, :max_tokens, 4096)

        tokens when tokens < 200 ->
          Keyword.put(opts, :max_tokens, 200)

        _tokens ->
          opts
      end

    ReqLLM.Provider.Defaults.prepare_request(
      __MODULE__,
      :object,
      model_spec,
      prompt,
      opts_with_tokens
    )
  end

  # Override to reject unsupported operations
  def prepare_request(:embedding, _model_spec, _input, _opts) do
    supported_operations = [:chat, :object]

    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: :embedding not supported by #{inspect(__MODULE__)}. Supported operations: #{inspect(supported_operations)}"
     )}
  end

  # Delegate other operations to default implementation
  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @impl ReqLLM.Provider
  def extract_usage(body, _model) when is_map(body) do
    case body do
      %{"usage" => usage} ->
        normalized_usage = Map.put_new(usage, "cached_tokens", 0)
        {:ok, normalized_usage}

      _ ->
        {:error, :no_usage_found}
    end
  end

  def extract_usage(_, _), do: {:error, :invalid_body}

  @impl ReqLLM.Provider
  def translate_options(_operation, model, opts) do
    warnings = []

    # Handle stream? -> stream alias for backward compatibility
    {stream_value, opts} = Keyword.pop(opts, :stream?)
    opts = if stream_value, do: Keyword.put(opts, :stream, stream_value), else: opts

    # Translate canonical reasoning_effort from atom to string
    {reasoning_effort, opts} = Keyword.pop(opts, :reasoning_effort)

    opts =
      case reasoning_effort do
        :low -> Keyword.put(opts, :reasoning_effort, "low")
        :medium -> Keyword.put(opts, :reasoning_effort, "medium")
        :high -> Keyword.put(opts, :reasoning_effort, "high")
        :default -> Keyword.put(opts, :reasoning_effort, "default")
        nil -> opts
        other -> Keyword.put(opts, :reasoning_effort, other)
      end

    opts = Keyword.delete(opts, :reasoning_token_budget)

    # Handle max_tokens -> max_completion_tokens translation (xAI preference)
    {max_tokens_value, opts} = Keyword.pop(opts, :max_tokens)

    {opts, warnings} =
      if max_tokens_value && !Keyword.has_key?(opts, :max_completion_tokens) do
        warning =
          "xAI prefers max_completion_tokens over max_tokens. Consider updating your code."

        {Keyword.put(opts, :max_completion_tokens, max_tokens_value), [warning | warnings]}
      else
        {opts, warnings}
      end

    # Handle web_search_options -> search_parameters alias
    {web_search_options, opts} = Keyword.pop(opts, :web_search_options)

    {opts, warnings} =
      if web_search_options do
        warning = "web_search_options is deprecated, use search_parameters instead"
        current_search = Keyword.get(opts, :search_parameters, %{})
        merged_search = Map.merge(web_search_options, current_search)
        {Keyword.put(opts, :search_parameters, merged_search), [warning | warnings]}
      else
        {opts, warnings}
      end

    # Remove unsupported parameters with warnings
    unsupported_params = [:logit_bias, :service_tier]

    {opts, warnings} =
      Enum.reduce(unsupported_params, {opts, warnings}, fn param, {acc_opts, acc_warnings} ->
        case Keyword.pop(acc_opts, param) do
          {nil, remaining_opts} ->
            {remaining_opts, acc_warnings}

          {_value, remaining_opts} ->
            warning = "#{param} is not supported by xAI and will be ignored"
            {remaining_opts, [warning | acc_warnings]}
        end
      end)

    # Validate reasoning_effort model compatibility
    {reasoning_effort, opts} = Keyword.pop(opts, :reasoning_effort)

    {opts, warnings} =
      if reasoning_effort do
        model_name = model.model

        if String.contains?(model_name, "grok-4") do
          warning = "reasoning_effort is not supported for Grok-4 models and will be ignored"
          {opts, [warning | warnings]}
        else
          {Keyword.put(opts, :reasoning_effort, reasoning_effort), warnings}
        end
      else
        {opts, warnings}
      end

    {opts, Enum.reverse(warnings)}
  end

  @doc """
  Custom body encoding that adds xAI-specific extensions to the default OpenAI-compatible format.

  Adds support for:
  - max_completion_tokens (preferred over max_tokens for Grok-4)
  - reasoning_effort (low, medium, high) for grok-3-mini models
  - search_parameters (Live Search configuration)
  - parallel_tool_calls (with skip for true default)
  - stream_options (streaming configuration)
  """
  @impl ReqLLM.Provider
  def encode_body(request) do
    # Start with default encoding
    request = ReqLLM.Provider.Defaults.default_encode_body(request)

    # Parse the encoded body to add xAI-specific options
    body = Jason.decode!(request.body)

    enhanced_body =
      body
      |> maybe_put(:max_completion_tokens, request.options[:max_completion_tokens])
      |> maybe_put(:reasoning_effort, request.options[:reasoning_effort])
      |> maybe_put(:search_parameters, request.options[:search_parameters])
      |> maybe_put_skip(:parallel_tool_calls, request.options[:parallel_tool_calls], [true])
      |> maybe_put(:stream_options, request.options[:stream_options])

    # Re-encode with xAI extensions
    encoded_body = Jason.encode!(enhanced_body)
    Map.put(request, :body, encoded_body)
  end

  @doc """
  Decodes xAI API responses based on operation type and streaming mode.

  ## Response Handling

  - **Chat operations**: Converts to ReqLLM.Response struct
  - **Streaming**: Creates response with chunk stream
  - **Non-streaming**: Merges context with assistant response

  ## Error Handling

  Non-200 status codes are converted to ReqLLM.Error.API.Response exceptions.
  """
  @impl ReqLLM.Provider
  def decode_response({req, resp}) do
    case resp.status do
      200 ->
        decode_success_response(req, resp)

      status ->
        decode_error_response(req, resp, status)
    end
  end

  defp decode_success_response(req, resp) do
    operation = req.options[:operation]
    decode_chat_response(req, resp, operation)
  end

  defp decode_error_response(req, resp, status) do
    err =
      ReqLLM.Error.API.Response.exception(
        reason: "xAI API error",
        status: status,
        response_body: resp.body
      )

    {req, err}
  end

  defp decode_chat_response(req, resp, operation) do
    model_name = req.options[:model]
    model = %ReqLLM.Model{provider: :xai, model: model_name}
    is_streaming = req.options[:stream] == true

    if is_streaming do
      decode_streaming_response(req, resp, model_name)
    else
      decode_non_streaming_response(req, resp, model, operation)
    end
  end

  defp decode_streaming_response(req, resp, model_name) do
    # Real-time streaming - use the stream created by Stream step
    # The request has already been initiated by the initial Req.request call
    # We just need to return the configured stream, not make another request
    real_time_stream = Req.Request.get_private(req, :real_time_stream, [])

    response = %ReqLLM.Response{
      id: "stream-#{System.unique_integer([:positive])}",
      model: model_name,
      context: req.options[:context] || %ReqLLM.Context{messages: []},
      message: nil,
      stream?: true,
      stream: real_time_stream,
      usage: %{
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        cached_tokens: 0,
        reasoning_tokens: 0
      },
      finish_reason: nil,
      provider_meta: %{}
    }

    {req, %{resp | body: response}}
  end

  defp decode_non_streaming_response(req, resp, model, operation) do
    body = ensure_parsed_body(resp.body)
    {:ok, response} = ReqLLM.Provider.Defaults.decode_response_body_openai_format(body, model)

    final_response =
      case operation do
        :object ->
          extract_and_set_object(response)

        _ ->
          response
      end

    merged_response = merge_response_with_context(req, final_response)
    {req, %{resp | body: merged_response}}
  end

  defp extract_and_set_object(response) do
    extracted_object =
      case ReqLLM.Response.tool_calls(response) do
        [] ->
          nil

        tool_calls ->
          case Enum.find(tool_calls, &(&1.name == "structured_output")) do
            nil -> nil
            %{arguments: object} -> object
          end
      end

    %{response | object: extracted_object}
  end

  defp merge_response_with_context(req, response) do
    context = req.options[:context] || %ReqLLM.Context{messages: []}
    ReqLLM.Context.merge_response(context, response)
  end
end

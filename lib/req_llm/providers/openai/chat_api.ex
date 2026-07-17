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

  require ReqLLM.Debug, as: Debug

  alias ReqLLM.Providers.OpenAI.ChatAPI.Request

  @impl true
  def path, do: "/chat/completions"

  @impl true
  def encode_body(request) do
    context = request.options[:context]
    model_name = request.options[:model]
    operation = request.options[:operation] || :chat
    opts = if is_map(request.options), do: Map.to_list(request.options), else: request.options

    enhanced_body = Request.build_body(context, model_name, opts, operation)

    Debug.dbug(
      fn -> "OpenAI ChatAPI request body: #{Jason.encode!(enhanced_body, pretty: true)}" end,
      component: :provider
    )

    ReqLLM.Provider.Defaults.encode_body_from_map(request, enhanced_body)
  end

  @impl true
  def decode_response(response) do
    ReqLLM.Provider.Defaults.default_decode_response(response)
  end

  @impl true
  def decode_stream_event(event, model) do
    ReqLLM.Provider.Defaults.default_decode_stream_event(event, model)
  end

  defp build_request_headers(model, opts) do
    ReqLLM.Providers.OpenAI.auth_header_list(
      ReqLLM.Providers.OpenAI.resolve_request_credential!(model, opts)
    ) ++
      [{"Content-Type", "application/json"}]
  end

  defp build_request_url(opts) do
    case Keyword.get(opts, :base_url) do
      nil -> ReqLLM.Providers.OpenAI.base_url() <> path()
      base_url -> "#{base_url}#{path()}"
    end
  end

  @impl true
  def attach_stream(model, context, opts, _finch_name) do
    base_headers = build_request_headers(model, opts) ++ [{"Accept", "text/event-stream"}]
    custom_headers = ReqLLM.Provider.Utils.extract_custom_headers(opts[:req_http_options])
    headers = base_headers ++ custom_headers

    base_url = ReqLLM.Provider.Options.effective_base_url(ReqLLM.Providers.OpenAI, model, opts)

    cleaned_opts =
      opts
      |> Keyword.delete(:finch_name)
      |> Keyword.delete(:compiled_schema)
      |> Keyword.put(:stream, true)
      |> Keyword.put(:base_url, base_url)

    body = Request.build_body(context, model.id, cleaned_opts, :chat)
    url = build_request_url(cleaned_opts)

    encoded = body |> ReqLLM.Schema.apply_property_ordering() |> Jason.encode!()
    {:ok, Finch.build(:post, url, headers, encoded)}
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build streaming request: #{Exception.message(error)}"
       )}
  end
end

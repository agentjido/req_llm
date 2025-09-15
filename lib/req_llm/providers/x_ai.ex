defmodule ReqLLM.Providers.XAI do
  @moduledoc """
  xAI provider implementation using the Provider behavior.

  xAI provides the Grok family of models with advanced reasoning capabilities
  and optional Live Search functionality for real-time information access.

  ## Configuration

  Set your xAI API key via JidoKeys (automatically picks up from .env):

  # Option 1: Set directly in JidoKeys
    ReqLLM.put_key(:xai_api_key, "xai-...")
    
    # Option 2: Add to .env file (automatically loaded via JidoKeys+Dotenvy)
    XAI_API_KEY=xai-...

  ## Examples

      # Simple text generation
      model = ReqLLM.Model.from("xai:grok-3")
      {:ok, response} = ReqLLM.generate_text(model, "Hello!")

      # Streaming with reasoning model
      {:ok, stream} = ReqLLM.stream_text(model, "Explain quantum physics", stream: true)

      # Tool calling
      tools = [%ReqLLM.Tool{name: "get_weather", ...}]
      {:ok, response} = ReqLLM.generate_text(model, "What's the weather?", tools: tools)

      # Using Live Search (Grok models only)
      {:ok, response} = ReqLLM.generate_text(
        model,
        "What's the latest news about AI?",
        provider_options: [live_search: true]
      )

  ## Model-specific Notes

  - Grok 4 is a reasoning-only model (no non-reasoning mode)
  - Grok 4 does not support `presence_penalty`, `frequency_penalty`, or `stop` parameters
  - Live Search is available for real-time information (additional cost applies)
  - Knowledge cutoff is November 2024 for Grok 3 and Grok 4 models

  ## Reasoning Token Budget

  Grok models use a two-phase approach with internal reasoning before tool execution.
  Ensure adequate token limits when using tool calling:

      # Insufficient for tool calling
      ReqLLM.generate_text(model, "weather query", tools: tools, max_tokens: 100)

      # Adequate for reasoning + tool execution
      ReqLLM.generate_text(model, "weather query", tools: tools, max_tokens: 500)

  The provider automatically defaults to 500 tokens for Grok models when `max_tokens` is not specified.

  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :xai,
    base_url: "https://api.x.ai/v1",
    metadata: "priv/models_dev/xai.json",
    default_env_key: "XAI_API_KEY",
    context_wrapper: ReqLLM.Providers.XAI.Context,
    response_wrapper: ReqLLM.Providers.XAI.Response,
    provider_schema: [
      live_search: [
        type: :boolean,
        default: false,
        doc: "Enable Live Search for real-time information access (additional cost applies)"
      ],
      # xAI-specific Live Search functionality
      reasoning_effort: [
        type: {:in, ~w(none default low medium high)},
        doc: "Reasoning effort level (not supported by Grok 4)"
      ],

      # xAI reasoning parameters (Note: Grok 4 doesn't support reasoning_effort)
      enable_cached_prompt: [
        type: :boolean,
        default: true,
        doc: "Enable automatic caching for repeated prompts to reduce costs"
      ],

      # xAI caching control
      service_tier: [
        type: {:in, ~w(auto default performance)},
        doc: "Performance tier for xAI requests"
      ]
    ]

  import ReqLLM.Provider.Utils,
    only: [prepare_options!: 3, maybe_put: 3, ensure_parsed_body: 1]

  # Model-specific performance controls
  @doc """
  Attaches the xAI plugin to a Req request.

  ## Parameters

    * `request` - The Req request to attach to
    * `model_input` - The model (ReqLLM.Model struct, string, or tuple) that triggers this provider
    * `opts` - Options keyword list (validated against comprehensive schema)

  ## Request Options

    * `:temperature` - Controls randomness (0.0-2.0). Defaults to 0.7
    * `:max_tokens` - Maximum tokens to generate. Defaults to 1024
    * `:stream?` - Enable streaming responses. Defaults to false
    * `:base_url` - Override base URL. Defaults to provider default
    * `:messages` - Chat messages to send
    * `:live_search` - Enable Live Search for real-time information
    * `:reasoning_effort` - Reasoning effort level (not supported by Grok 4)
    * `:enable_cached_prompt` - Enable prompt caching for cost reduction
    * All options from ReqLLM.Provider.Options schemas are supported

  Note: Grok 4 models do not support `presence_penalty`, `frequency_penalty`, or `stop` parameters.

  """
  @impl ReqLLM.Provider
  def prepare_request(:chat, model_input, %ReqLLM.Context{} = context, opts) do
    with {:ok, model} <- ReqLLM.Model.from(model_input) do
      http_opts = Keyword.get(opts, :req_http_options, [])

      request =
        Req.new([url: "/chat/completions", method: :post, receive_timeout: 30_000] ++ http_opts)
        |> attach(model, Keyword.put(opts, :context, context))

      {:ok, request}
    end
  end

  def prepare_request(operation, _model, _input, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: #{inspect(operation)} not supported by xAI provider. Supported operations: [:chat]"
     )}
  end

  @spec attach(Req.Request.t(), ReqLLM.Model.t() | String.t() | {atom(), keyword()}, keyword()) ::
          Req.Request.t()
  @impl ReqLLM.Provider
  def attach(%Req.Request{} = request, model_input, user_opts \\ []) do
    %ReqLLM.Model{} = model = ReqLLM.Model.from!(model_input)

    if model.provider != provider_id() do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    api_key = ReqLLM.Keys.get!(model, user_opts)

    # Extract tools separately to avoid validation issues
    {tools, other_opts} = Keyword.pop(user_opts, :tools, [])

    # Extract provider-specific options (already validated by dynamic schema)
    provider_opts = Keyword.get(other_opts, :provider_options, [])

    # Remove provider_options from main opts since we handle them separately
    {_provider_options, core_opts} = Keyword.pop(other_opts, :provider_options, [])

    # Prepare validated core options
    opts = prepare_options!(__MODULE__, model, core_opts)

    # Add tools back after validation
    opts = Keyword.put(opts, :tools, tools)

    # Merge provider-specific options into opts for encoding
    opts = Keyword.merge(opts, provider_opts)

    base_url = Keyword.get(user_opts, :base_url, default_base_url())
    req_keys = __MODULE__.supported_provider_options() ++ [:model, :context]

    request
    |> Req.Request.register_options(req_keys)
    |> Req.Request.merge_options(Keyword.take(opts, req_keys) ++ [base_url: base_url])
    |> Req.Request.put_header("authorization", "Bearer #{api_key}")
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.append_request_steps(llm_encode_body: &__MODULE__.encode_body/1)
    |> ReqLLM.Step.Stream.maybe_attach(opts[:stream])
    |> Req.Request.append_response_steps(llm_decode_response: &__MODULE__.decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
  end

  @impl ReqLLM.Provider
  def extract_usage(body, _model) when is_map(body) do
    case body do
      %{"usage" => usage} -> {:ok, usage}
      _ -> {:error, :no_usage_found}
    end
  end

  def extract_usage(_, _), do: {:error, :invalid_body}

  @doc """
  Wraps raw xAI response data for protocol-based decoding.
  """
  def wrap_response(raw_data) do
    %ReqLLM.Providers.XAI.Response{payload: raw_data}
  end

  # Req pipeline steps
  @impl ReqLLM.Provider
  def encode_body(request) do
    context_data =
      case request.options[:context] do
        %ReqLLM.Context{} = ctx ->
          ctx
          |> wrap_context()
          |> ReqLLM.Context.Codec.encode_request()

        _ ->
          %{messages: request.options[:messages] || []}
      end

    # Get the model name
    model = request.options[:model]
    model_name = if is_struct(model, ReqLLM.Model), do: model.model, else: model

    body =
      %{model: model_name}
      |> Map.merge(context_data)
      |> maybe_put(:temperature, request.options[:temperature])
      |> maybe_put(:max_tokens, request.options[:max_tokens] || default_max_tokens(model_name))
      |> maybe_put(:top_p, request.options[:top_p])
      |> maybe_put(:stream, request.options[:stream])
      |> maybe_put(:user, request.options[:user])
      |> maybe_put(:seed, request.options[:seed])

    # Add xAI-specific provider options
    body =
      body
      |> maybe_put(:live_search, request.options[:live_search])
      |> maybe_put(:reasoning_effort, request.options[:reasoning_effort])
      |> maybe_put(:enable_cached_prompt, request.options[:enable_cached_prompt])
      |> maybe_put(:service_tier, request.options[:service_tier])

    # Handle Grok 4 limitations - skip unsupported parameters for reasoning models
    body =
      if is_grok_4_model?(model_name) do
        # Grok 4 doesn't support these parameters
        body
      else
        body
        |> maybe_put(:frequency_penalty, request.options[:frequency_penalty])
        |> maybe_put(:presence_penalty, request.options[:presence_penalty])
        |> maybe_put(:stop, request.options[:stop])
      end

    # Handle tools if provided
    body =
      case request.options[:tools] do
        tools when is_list(tools) and (is_list(tools) and tools != []) ->
          body = Map.put(body, :tools, Enum.map(tools, &ReqLLM.Tool.to_schema(&1, :openai)))

          # Handle tool_choice if provided, default to "auto" for xAI
          case request.options[:tool_choice] do
            nil -> Map.put(body, :tool_choice, "auto")
            choice -> Map.put(body, :tool_choice, choice)
          end

        _ ->
          body
      end

    # Handle response format if provided
    body =
      case request.options[:response_format] do
        format when is_map(format) ->
          Map.put(body, :response_format, format)

        _ ->
          body
      end

    try do
      encoded_body = Jason.encode!(body)

      request
      |> Req.Request.put_header("content-type", "application/json")
      |> Map.put(:body, encoded_body)
    rescue
      error ->
        reraise error, __STACKTRACE__
    end
  end

  @impl ReqLLM.Provider
  def decode_response({req, resp}) do
    case resp.status do
      200 ->
        body = ensure_parsed_body(resp.body)
        # Return raw parsed data directly - no wrapping needed
        {req, %{resp | body: body}}

      status ->
        err =
          ReqLLM.Error.API.Response.exception(
            reason: "xAI API error",
            status: status,
            response_body: resp.body
          )

        {req, err}
    end
  end

  # Default token limits for different model types
  defp default_max_tokens(model_name) when is_binary(model_name) do
    if String.starts_with?(model_name, "grok-") do
      # Adequate for reasoning + tool execution
      500
    else
      # Fallback used elsewhere in library
      1024
    end
  end

  defp default_max_tokens(_), do: 1024

  # Private helper to identify Grok 4 models
  defp is_grok_4_model?(model_name) when is_binary(model_name) do
    String.starts_with?(model_name, "grok-4")
  end

  defp is_grok_4_model?(_), do: false
end

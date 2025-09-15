defmodule ReqLLM.Providers.Groq do
  @moduledoc """
  Groq provider implementation using the Provider behavior.

  Groq provides fast LLM inference with OpenAI-compatible API endpoints.
  It offers high-performance inference for various open-source models.

  ## Configuration

  Set your Groq API key via JidoKeys (automatically picks up from .env):

      # Option 1: Set directly in JidoKeys
      ReqLLM.put_key(:groq_api_key, "gsk_...")
      
      # Option 2: Add to .env file (automatically loaded via JidoKeys+Dotenvy)
      GROQ_API_KEY=gsk_...

  ## Examples

      # Simple text generation
      model = ReqLLM.Model.from("groq:llama3-8b-8192")
      {:ok, response} = ReqLLM.generate_text(model, "Hello!")

      # Streaming
      {:ok, stream} = ReqLLM.stream_text(model, "Tell me a story", stream: true)

      # Tool calling
      tools = [%ReqLLM.Tool{name: "get_weather", ...}]
      {:ok, response} = ReqLLM.generate_text(model, "What's the weather?", tools: tools)

  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :groq,
    base_url: "https://api.groq.com/openai/v1",
    metadata: "priv/models_dev/groq.json",
    default_env_key: "GROQ_API_KEY",
    context_wrapper: ReqLLM.Providers.Groq.Context,
    response_wrapper: ReqLLM.Providers.Groq.Response,
    provider_schema: [
      service_tier: [
        type: {:in, ~w(auto on_demand flex performance)},
        doc: "Performance tier for Groq requests"
      ],
      # Groq-specific performance and service options
      reasoning_effort: [
        type: {:in, ~w(none default low medium high)},
        doc: "Reasoning effort level"
      ],
      # Reasoning capabilities
      reasoning_format: [
        type: :string,
        doc: "Format for reasoning output"
      ],
      search_settings: [
        type: :map,
        doc: "Web search configuration with include/exclude domains"
      ],
      # Search and compound features
      compound_custom: [
        type: :map,
        doc: "Custom configuration for Compound systems"
      ],
      logit_bias: [
        type: :map,
        doc: "Logit bias adjustments for tokens"
      ]
    ]

  import ReqLLM.Provider.Utils,
    only: [prepare_options!: 3, maybe_put: 3, ensure_parsed_body: 1]

  # OpenAI-compatible options that Groq supports
  @doc """
  Attaches the Groq plugin to a Req request.

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
    * `:system` - System message
    * `:service_tier` - Performance tier (auto, on_demand, flex, performance)
    * `:reasoning_effort` - Reasoning effort level (none, default, low, medium, high)
    * `:reasoning_format` - Format for reasoning output
    * All options from ReqLLM.Provider.Options schemas are supported

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
         "operation: #{inspect(operation)} not supported by Groq provider. Supported operations: [:chat]"
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
    # Groq uses Bearer token authentication
    |> Req.Request.merge_options(
      Keyword.take(opts, req_keys) ++ [base_url: base_url, auth: {:bearer, api_key}]
    )
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

    # Get the model name (Groq uses model names like "llama3-8b-8192")
    model = request.options[:model]
    model_name = if is_struct(model, ReqLLM.Model), do: model.model, else: model

    body =
      %{model: model_name}
      |> Map.merge(context_data)
      |> maybe_put(:temperature, request.options[:temperature])
      |> maybe_put(:max_tokens, request.options[:max_tokens])
      |> maybe_put(:top_p, request.options[:top_p])
      |> maybe_put(:stream, request.options[:stream])
      |> maybe_put(:frequency_penalty, request.options[:frequency_penalty])
      |> maybe_put(:presence_penalty, request.options[:presence_penalty])
      |> maybe_put(:user, request.options[:user])
      |> maybe_put(:seed, request.options[:seed])
      # Groq-specific provider options
      |> maybe_put(:logit_bias, request.options[:logit_bias])
      # Skip service_tier if it's "auto" (not available on free tier)
      |> maybe_put_groq_service_tier(request.options[:service_tier])
      # Skip reasoning_effort if it's "default" (problematic default value)
      |> maybe_put_groq_reasoning_effort(request.options[:reasoning_effort])
      |> maybe_put(:reasoning_format, request.options[:reasoning_format])
      |> maybe_put(:search_settings, request.options[:search_settings])
      |> maybe_put(:compound_custom, request.options[:compound_custom])

    # Handle tools if provided
    body =
      case request.options[:tools] do
        tools when is_list(tools) and (is_list(tools) and tools != []) ->
          body = Map.put(body, :tools, Enum.map(tools, &ReqLLM.Tool.to_schema(&1, :openai)))

          # Handle tool_choice if provided
          case request.options[:tool_choice] do
            nil -> body
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
            reason: "Groq API error",
            status: status,
            response_body: resp.body
          )

        {req, err}
    end
  end

  # Private helper functions for Groq-specific parameter handling
  defp maybe_put_groq_service_tier(body, "auto"), do: body
  defp maybe_put_groq_service_tier(body, nil), do: body
  defp maybe_put_groq_service_tier(body, value), do: maybe_put(body, :service_tier, value)

  defp maybe_put_groq_reasoning_effort(body, "default"), do: body
  defp maybe_put_groq_reasoning_effort(body, nil), do: body
  defp maybe_put_groq_reasoning_effort(body, value), do: maybe_put(body, :reasoning_effort, value)
end

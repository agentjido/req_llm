defmodule ReqLLM.Providers.Google do
  @moduledoc """
  Google Gemini provider implementation using the Provider behavior.

  Supports Google's Gemini API with features including:
  - Text generation with Gemini models
  - Streaming responses
  - Tool calling
  - Multi-modal inputs (text, images, audio, video)
  - Various safety settings

  ## Configuration

  Set your Google API key via JidoKeys (automatically picks up from .env):

      # Option 1: Set directly in JidoKeys
      ReqLLM.put_key(:google_api_key, "AIza...")
      
      # Option 2: Add to .env file (automatically loaded via JidoKeys+Dotenvy)
      GOOGLE_API_KEY=AIza...

  ## Examples

      # Simple text generation
      model = ReqLLM.Model.from("google:gemini-1.5-flash")
      {:ok, response} = ReqLLM.generate_text(model, "Hello!")

      # Streaming
      {:ok, stream} = ReqLLM.stream_text(model, "Tell me a story", stream: true)

      # Tool calling
      tools = [%ReqLLM.Tool{name: "get_weather", ...}]
      {:ok, response} = ReqLLM.generate_text(model, "What's the weather?", tools: tools)

  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :google,
    base_url: "https://generativelanguage.googleapis.com/v1beta",
    metadata: "priv/models_dev/google.json",
    default_env_key: "GOOGLE_API_KEY",
    context_wrapper: ReqLLM.Providers.Google.Context,
    response_wrapper: ReqLLM.Providers.Google.Response,
    provider_schema: [
      safety_settings: [
        type: {:list, :map},
        doc: "Safety filter settings for content generation"
      ],
      candidate_count: [
        type: :pos_integer,
        default: 1,
        doc: "Number of response candidates to generate"
      ]
    ]

  import ReqLLM.Provider.Utils,
    only: [prepare_options!: 3, maybe_put: 3, ensure_parsed_body: 1]

  @doc """
  Attaches the Google plugin to a Req request.

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
    * All options from ReqLLM.Provider.Options schemas are supported

  """
  @impl ReqLLM.Provider
  def prepare_request(:chat, model_input, %ReqLLM.Context{} = context, opts) do
    with {:ok, model} <- ReqLLM.Model.from(model_input) do
      http_opts = Keyword.get(opts, :req_http_options, [])

      request =
        Req.new(
          [url: "/models/#{model.model}:generateContent", method: :post, receive_timeout: 30_000] ++
            http_opts
        )
        |> attach(model, Keyword.put(opts, :context, context))

      {:ok, request}
    end
  end

  def prepare_request(operation, _model, _input, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: #{inspect(operation)} not supported by Google provider. Supported operations: [:chat]"
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

    if !ReqLLM.Provider.Registry.model_exists?("#{provider_id()}:#{model.model}") do
      raise ReqLLM.Error.Invalid.Parameter.exception(parameter: "model: #{model.model}")
    end

    api_key = ReqLLM.Keys.get!(model, user_opts)

    # Extract tools separately to avoid validation issues
    {tools, other_opts} = Keyword.pop(user_opts, :tools, [])

    # Prepare validated options and extract what Req needs
    opts = prepare_options!(__MODULE__, model, other_opts)

    # Add tools back after validation
    opts = Keyword.put(opts, :tools, tools)
    base_url = Keyword.get(user_opts, :base_url, default_base_url())
    req_keys = __MODULE__.supported_provider_options() ++ [:model, :context]

    request
    |> Req.Request.register_options(req_keys)
    # Google uses query parameter for API key
    |> Req.Request.merge_options(
      Keyword.take(opts, req_keys) ++ [base_url: base_url, params: [key: api_key]]
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
      %{"usageMetadata" => usage} -> {:ok, usage}
      _ -> {:error, :no_usage_found}
    end
  end

  def extract_usage(_, _), do: {:error, :invalid_body}

  # Parameter validation helpers
  defp validate_parameter_ranges(opts) do
    with :ok <- validate_temperature(opts[:temperature]),
         :ok <- validate_top_p(opts[:top_p]),
         :ok <- validate_top_k(opts[:top_k]) do
      validate_max_tokens(opts[:max_tokens])
    end
  end

  defp validate_temperature(nil), do: :ok
  defp validate_temperature(temp) when is_number(temp) and temp >= 0.0 and temp <= 2.0, do: :ok

  defp validate_temperature(temp),
    do: {:error, "temperature must be between 0.0 and 2.0, got #{temp}"}

  defp validate_top_p(nil), do: :ok
  defp validate_top_p(top_p) when is_number(top_p) and top_p >= 0.0 and top_p <= 1.0, do: :ok
  defp validate_top_p(top_p), do: {:error, "top_p must be between 0.0 and 1.0, got #{top_p}"}

  defp validate_top_k(nil), do: :ok
  defp validate_top_k(top_k) when is_integer(top_k) and top_k >= 1, do: :ok
  defp validate_top_k(top_k), do: {:error, "top_k must be >= 1, got #{top_k}"}

  defp validate_max_tokens(nil), do: :ok

  defp validate_max_tokens(max_tokens) when is_integer(max_tokens) and max_tokens >= 1, do: :ok

  defp validate_max_tokens(max_tokens), do: {:error, "max_tokens must be >= 1, got #{max_tokens}"}

  # Req pipeline steps
  @impl ReqLLM.Provider
  def encode_body(request) do
    # Validate parameter ranges before proceeding
    case validate_parameter_ranges(request.options) do
      :ok ->
        nil

      {:error, reason} ->
        raise ReqLLM.Error.Invalid.Parameter.exception(parameter: reason)
    end

    context_data =
      case request.options[:context] do
        %ReqLLM.Context{} = ctx ->
          ctx
          |> wrap_context()
          |> ReqLLM.Context.Codec.encode_request()

        _ ->
          %{contents: request.options[:messages] || []}
      end

    tools_data =
      case request.options[:tools] do
        tools when is_list(tools) and (is_list(tools) and tools != []) ->
          %{
            tools: [%{functionDeclarations: Enum.map(tools, &ReqLLM.Tool.to_schema(&1, :google))}]
          }

        _ ->
          %{}
      end

    # Handle candidate_count as a direct option if passed
    candidate_count = request.options[:candidate_count] || 1

    generation_config =
      %{}
      |> maybe_put(:temperature, request.options[:temperature])
      |> maybe_put(:maxOutputTokens, request.options[:max_tokens])
      |> maybe_put(:topP, request.options[:top_p])
      |> maybe_put(:topK, request.options[:top_k])
      |> maybe_put(:candidateCount, candidate_count)

    body =
      %{}
      |> Map.merge(context_data)
      |> Map.merge(tools_data)
      |> maybe_put(:generationConfig, generation_config)
      |> maybe_put(:safetySettings, request.options[:safety_settings])

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
            reason: "Google API error",
            status: status,
            response_body: resp.body
          )

        {req, err}
    end
  end
end

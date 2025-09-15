defmodule ReqLLM.Providers.OpenRouter do
  @moduledoc """
  OpenRouter provider implementation using the Provider behavior.

  OpenRouter is a unified API for accessing multiple AI models through a single endpoint.
  It normalizes request/response schemas and provides model routing capabilities.

  ## Tool Calling Support

  OpenRouter supports tool calling with compatible models using OpenAI-compatible format.
  Confirmed working models:

  - `openrouter:openai/gpt-4` 
  - `openrouter:openai/gpt-4-turbo`
  - `openrouter:openai/gpt-3.5-turbo`
  - `openrouter:anthropic/claude-3-haiku`
  - `openrouter:google/gemini-2.0-flash-001`

  ## Configuration

  Set your OpenRouter API key via JidoKeys (automatically picks up from .env):

      # Option 1: Set directly in JidoKeys
      ReqLLM.put_key(:openrouter_api_key, "sk-or-...")
      
      # Option 2: Add to .env file (automatically loaded via JidoKeys+Dotenvy)
      OPENROUTER_API_KEY=sk-or-...

  ## Examples

      # Simple text generation
      model = ReqLLM.Model.from("openrouter:anthropic/claude-3-haiku")
      {:ok, response} = ReqLLM.generate_text(model, "Hello!")

      # Streaming
      {:ok, stream} = ReqLLM.stream_text(model, "Tell me a story", stream: true)

      # Tool calling
      tools = [%ReqLLM.Tool{name: "get_weather", ...}]
      {:ok, response} = ReqLLM.generate_text(model, "What's the weather?", tools: tools)

  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :openrouter,
    base_url: "https://openrouter.ai/api/v1",
    metadata: "priv/models_dev/openrouter.json",
    default_env_key: "OPENROUTER_API_KEY",
    context_wrapper: ReqLLM.Providers.OpenRouter.Context,
    response_wrapper: ReqLLM.Providers.OpenRouter.Response,
    provider_schema: [
      repetition_penalty: [
        type: :float,
        doc: "Repetition penalty for reducing repetitive text"
      ],
      # OpenRouter-specific options
      top_logprobs: [
        type: :pos_integer,
        doc: "Number of top log probabilities to return"
      ],
      min_p: [
        type: :float,
        doc: "Minimum probability threshold"
      ],
      top_a: [
        type: :float,
        doc: "Top-a sampling parameter"
      ],
      models: [
        type: {:list, :string},
        doc: "List of models to route between"
      ],
      provider: [
        type: :map,
        doc: "Provider-specific routing configuration"
      ],
      usage: [
        type: :map,
        doc: "Usage tracking configuration"
      ],
      transforms: [
        type: {:list, :string},
        doc: "List of transforms to apply"
      ]
    ]

  import ReqLLM.Provider.Utils,
    only: [prepare_options!: 3, maybe_put: 3, ensure_parsed_body: 1]

  @doc """
  Attaches the OpenRouter plugin to a Req request.

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
        Req.new([url: "/chat/completions", method: :post, receive_timeout: 30_000] ++ http_opts)
        |> attach(model, Keyword.put(opts, :context, context))

      {:ok, request}
    end
  end

  def prepare_request(operation, _model, _input, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: #{inspect(operation)} not supported by OpenRouter provider. Supported operations: [:chat]"
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

    # Prepare validated options and extract what Req needs
    opts = prepare_options!(__MODULE__, model, other_opts)

    # Add tools back after validation
    opts = Keyword.put(opts, :tools, tools)
    base_url = Keyword.get(user_opts, :base_url, default_base_url())
    req_keys = __MODULE__.supported_provider_options() ++ [:model, :context]

    request
    |> Req.Request.register_options(req_keys)
    # OpenRouter uses Bearer token authentication
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

  # Parameter validation helpers
  defp validate_parameter_ranges(opts) do
    with :ok <- validate_temperature(opts[:temperature]),
         :ok <- validate_top_p(opts[:top_p]),
         :ok <- validate_top_k(opts[:top_k]),
         :ok <- validate_max_tokens(opts[:max_tokens]),
         :ok <- validate_frequency_penalty(opts[:frequency_penalty]),
         :ok <- validate_presence_penalty(opts[:presence_penalty]),
         :ok <- validate_repetition_penalty(opts[:repetition_penalty]),
         :ok <- validate_min_p(opts[:min_p]) do
      validate_top_a(opts[:top_a])
    end
  end

  defp validate_temperature(nil), do: :ok
  defp validate_temperature(temp) when is_number(temp) and temp >= 0.0 and temp <= 2.0, do: :ok

  defp validate_temperature(temp),
    do: {:error, "temperature must be between 0.0 and 2.0, got #{temp}"}

  defp validate_top_p(nil), do: :ok
  defp validate_top_p(top_p) when is_number(top_p) and top_p > 0.0 and top_p <= 1.0, do: :ok
  defp validate_top_p(top_p), do: {:error, "top_p must be between 0.0 and 1.0, got #{top_p}"}

  defp validate_top_k(nil), do: :ok
  defp validate_top_k(top_k) when is_integer(top_k) and top_k >= 1, do: :ok
  defp validate_top_k(top_k), do: {:error, "top_k must be >= 1, got #{top_k}"}

  defp validate_max_tokens(nil), do: :ok

  defp validate_max_tokens(max_tokens) when is_integer(max_tokens) and max_tokens >= 1, do: :ok

  defp validate_max_tokens(max_tokens), do: {:error, "max_tokens must be >= 1, got #{max_tokens}"}

  defp validate_frequency_penalty(nil), do: :ok

  defp validate_frequency_penalty(penalty)
       when is_number(penalty) and penalty >= -2.0 and penalty <= 2.0,
       do: :ok

  defp validate_frequency_penalty(penalty),
    do: {:error, "frequency_penalty must be between -2.0 and 2.0, got #{penalty}"}

  defp validate_presence_penalty(nil), do: :ok

  defp validate_presence_penalty(penalty)
       when is_number(penalty) and penalty >= -2.0 and penalty <= 2.0,
       do: :ok

  defp validate_presence_penalty(penalty),
    do: {:error, "presence_penalty must be between -2.0 and 2.0, got #{penalty}"}

  defp validate_repetition_penalty(nil), do: :ok

  defp validate_repetition_penalty(penalty)
       when is_number(penalty) and penalty > 0.0 and penalty <= 2.0,
       do: :ok

  defp validate_repetition_penalty(penalty),
    do: {:error, "repetition_penalty must be between 0.0 and 2.0, got #{penalty}"}

  defp validate_min_p(nil), do: :ok
  defp validate_min_p(min_p) when is_number(min_p) and min_p >= 0.0 and min_p <= 1.0, do: :ok
  defp validate_min_p(min_p), do: {:error, "min_p must be between 0.0 and 1.0, got #{min_p}"}

  defp validate_top_a(nil), do: :ok
  defp validate_top_a(top_a) when is_number(top_a) and top_a >= 0.0 and top_a <= 1.0, do: :ok
  defp validate_top_a(top_a), do: {:error, "top_a must be between 0.0 and 1.0, got #{top_a}"}

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
          %{messages: request.options[:messages] || []}
      end

    # Get the model name (OpenRouter uses full model names like "anthropic/claude-3-haiku")
    model = request.options[:model]
    model_name = if is_struct(model, ReqLLM.Model), do: model.model, else: model

    body =
      %{model: model_name}
      |> Map.merge(context_data)
      |> maybe_put(:temperature, request.options[:temperature])
      |> maybe_put(:max_tokens, request.options[:max_tokens])
      |> maybe_put(:top_p, request.options[:top_p])
      |> maybe_put(:top_k, request.options[:top_k])
      |> maybe_put(:stream, request.options[:stream])
      |> maybe_put(:frequency_penalty, request.options[:frequency_penalty])
      |> maybe_put(:presence_penalty, request.options[:presence_penalty])
      |> maybe_put(:repetition_penalty, request.options[:repetition_penalty])
      |> maybe_put(:logit_bias, request.options[:logit_bias])
      |> maybe_put(:top_logprobs, request.options[:top_logprobs])
      |> maybe_put(:min_p, request.options[:min_p])
      |> maybe_put(:top_a, request.options[:top_a])
      |> maybe_put(:user, request.options[:user])
      |> maybe_put(:models, request.options[:models])
      |> maybe_put(:provider, request.options[:provider])
      |> maybe_put(:reasoning, request.options[:reasoning])
      |> maybe_put(:usage, request.options[:usage])
      |> maybe_put(:transforms, request.options[:transforms])
      |> maybe_put(:seed, request.options[:seed])

    # Handle tools if provided
    body =
      case request.options[:tools] do
        tools when is_list(tools) and (is_list(tools) and tools != []) ->
          Map.put(body, :tools, Enum.map(tools, &ReqLLM.Tool.to_schema(&1, :openai)))

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
            reason: "OpenRouter API error",
            status: status,
            response_body: resp.body
          )

        {req, err}
    end
  end
end

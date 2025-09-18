defmodule ReqLLM.Providers.OpenRouter do
  @moduledoc """
  OpenRouter provider – OpenAI Chat Completions compatible with OpenRouter's unified API.

  ## Protocol Usage

  Uses the generic `ReqLLM.Context.Codec` and `ReqLLM.Response.Codec` protocols.
  No custom wrapper modules – leverages the standard OpenAI-compatible codecs.

  ## OpenRouter-Specific Extensions

  Beyond standard OpenAI parameters, OpenRouter supports:
  - `openrouter_models` - Array of model IDs for routing/fallback preferences
  - `openrouter_route` - Routing strategy (e.g., "fallback") 
  - `openrouter_provider` - Provider preferences object for routing decisions
  - `openrouter_transforms` - Array of prompt transforms to apply
  - `openrouter_top_k` - Top-k sampling (not available for OpenAI models)
  - `openrouter_repetition_penalty` - Repetition penalty for reducing repetitive text
  - `openrouter_min_p` - Minimum probability threshold for sampling
  - `openrouter_top_a` - Top-a sampling parameter
  - `app_referer` - HTTP-Referer header for app identification
  - `app_title` - X-Title header for app title in rankings

  ## App Attribution Headers

  OpenRouter supports optional headers for app discoverability:
  - Set `HTTP-Referer` header for app identification
  - Set `X-Title` header for app title in rankings

  See `provider_schema/0` for the complete OpenRouter-specific schema and
  `ReqLLM.Provider.Options` for inherited OpenAI parameters.

  ## Configuration

      # Add to .env file (automatically loaded)
      OPENROUTER_API_KEY=sk-or-...
  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :openrouter,
    base_url: "https://openrouter.ai/api/v1",
    metadata: "priv/models_dev/openrouter.json",
    default_env_key: "OPENROUTER_API_KEY",
    provider_schema: [
      openrouter_models: [
        type: {:list, :string},
        doc: "Array of model IDs for routing/fallback preferences"
      ],
      openrouter_route: [
        type: :string,
        doc: "Routing strategy (e.g., 'fallback')"
      ],
      openrouter_provider: [
        type: :map,
        doc: "Provider preferences object for routing decisions"
      ],
      openrouter_transforms: [
        type: {:list, :string},
        doc: "Array of prompt transforms to apply"
      ],
      openrouter_top_k: [
        type: :integer,
        doc: "Top-k sampling (not available for OpenAI models)"
      ],
      openrouter_repetition_penalty: [
        type: :float,
        doc: "Repetition penalty for reducing repetitive text"
      ],
      openrouter_min_p: [
        type: :float,
        doc: "Minimum probability threshold for sampling"
      ],
      openrouter_top_a: [
        type: :float,
        doc: "Top-a sampling parameter"
      ],
      openrouter_top_logprobs: [
        type: :integer,
        doc: "Number of top log probabilities to return"
      ],
      app_referer: [
        type: :string,
        doc: "HTTP-Referer header for app identification on OpenRouter"
      ],
      app_title: [
        type: :string,
        doc: "X-Title header for app title in OpenRouter rankings"
      ]
    ]

  import ReqLLM.Provider.Utils,
    only: [maybe_put: 3, ensure_parsed_body: 1]

  require Logger

  # Helper for validation and translation
  defp validate_and_translate!(provider_mod, model, raw_opts) do
    # Separate context and special test/internal options from user options
    {context, remaining_opts} = Keyword.pop(raw_opts, :context)

    # Extract internal/test options that shouldn't be validated
    internal_keys = [:req_options, :on_unsupported, :fixture, :req_http_options, :compiled_schema]
    {internal_opts, user_opts} = Keyword.split(remaining_opts, internal_keys)

    schema = provider_mod.provider_extended_generation_schema()
    {:ok, valid_opts} = NimbleOptions.validate(user_opts, schema)

    # Apply provider-specific translations
    translated_opts =
      case provider_mod.translate_options(:chat, model, valid_opts) do
        {translated_opts, warnings} when is_list(warnings) ->
          # Emit warnings to the logger
          Enum.each(warnings, &Logger.warning/1)
          translated_opts

        translated_opts ->
          translated_opts
      end

    # Merge back all the options
    final_opts = Keyword.merge(translated_opts, internal_opts)

    if context do
      Keyword.put(final_opts, :context, context)
    else
      final_opts
    end
  end

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
    * `:openrouter_models` - Array of model IDs for routing/fallback preferences
    * `:openrouter_route` - Routing strategy (e.g., "fallback")
    * `:openrouter_provider` - Provider preferences object for routing decisions
    * `:openrouter_transforms` - Array of prompt transforms to apply
    * `:openrouter_top_k` - Top-k sampling (not available for OpenAI models)
    * `:openrouter_repetition_penalty` - Repetition penalty for reducing repetitive text
    * `:app_referer` - HTTP-Referer header for app identification
    * `:app_title` - X-Title header for app title in rankings
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

  def prepare_request(:object, model_input, %ReqLLM.Context{} = context, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    structured_output_tool =
      ReqLLM.Tool.new!(
        name: "structured_output",
        description: "Generate structured output matching the provided schema",
        parameter_schema: compiled_schema.schema,
        callback: fn _args -> {:ok, "structured output generated"} end
      )

    opts_with_tool =
      Keyword.update(opts, :tools, [structured_output_tool], fn tools ->
        [structured_output_tool | tools]
      end)

    opts_with_choice =
      Keyword.put(opts_with_tool, :tool_choice, %{
        type: "function",
        function: %{name: "structured_output"}
      })

    opts_with_max_tokens =
      case Keyword.get(opts_with_choice, :max_tokens) do
        nil -> Keyword.put(opts_with_choice, :max_tokens, 4096)
        tokens when tokens < 200 -> Keyword.put(opts_with_choice, :max_tokens, 200)
        _value -> opts_with_choice
      end

    prepare_request(:chat, model_input, context, opts_with_max_tokens)
  end

  def prepare_request(operation, _model, _input, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: #{inspect(operation)} not supported by OpenRouter provider. Supported operations: [:chat, :object]"
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
    {tools, other_opts} = Keyword.pop(user_opts, :tools, [])
    provider_opts = Keyword.get(other_opts, :provider_options, [])
    {_provider_options, core_opts} = Keyword.pop(other_opts, :provider_options, [])

    # Use new validation approach
    opts = validate_and_translate!(__MODULE__, model, core_opts)
    opts = Keyword.put(opts, :tools, tools)
    opts = Keyword.merge(opts, provider_opts)

    base_url = Keyword.get(user_opts, :base_url, default_base_url())
    req_keys = __MODULE__.supported_provider_options() ++ [:context]
    model_name = model.model

    # Extract app attribution headers if provided
    {app_referer, opts} = Keyword.pop(opts, :app_referer)
    {app_title, opts} = Keyword.pop(opts, :app_title)

    request =
      request
      |> Req.Request.register_options(req_keys ++ [:model])
      |> Req.Request.merge_options(
        Keyword.take(opts, req_keys) ++
          [model: model_name, base_url: base_url, auth: {:bearer, api_key}]
      )
      |> ReqLLM.Step.Error.attach()
      |> Req.Request.append_request_steps(llm_encode_body: &__MODULE__.encode_body/1)
      |> ReqLLM.Step.Stream.maybe_attach(opts[:stream])
      |> Req.Request.append_response_steps(llm_decode_response: &__MODULE__.decode_response/1)
      |> ReqLLM.Step.Usage.attach(model)

    # Add optional app attribution headers
    request =
      if app_referer do
        Req.Request.put_header(request, "HTTP-Referer", app_referer)
      else
        request
      end

    if app_title do
      Req.Request.put_header(request, "X-Title", app_title)
    else
      request
    end
  end

  @impl ReqLLM.Provider
  def extract_usage(body, _model) when is_map(body) do
    case body do
      %{"usage" => usage} -> {:ok, usage}
      _ -> {:error, :no_usage_found}
    end
  end

  def extract_usage(_, _), do: {:error, :invalid_body}

  @impl ReqLLM.Provider
  def translate_options(_operation, model, opts) do
    warnings = []

    # Handle stream? -> stream alias for backward compatibility
    {stream_value, opts} = Keyword.pop(opts, :stream?)
    opts = if stream_value, do: Keyword.put(opts, :stream, stream_value), else: opts

    # Handle legacy parameter names -> OpenRouter prefixed names
    legacy_mappings = [
      {:models, :openrouter_models},
      {:route, :openrouter_route},
      {:provider, :openrouter_provider},
      {:transforms, :openrouter_transforms},
      {:top_k, :openrouter_top_k},
      {:repetition_penalty, :openrouter_repetition_penalty},
      {:min_p, :openrouter_min_p},
      {:top_a, :openrouter_top_a},
      {:top_logprobs, :openrouter_top_logprobs}
    ]

    {opts, warnings} =
      Enum.reduce(legacy_mappings, {opts, warnings}, fn {legacy_key, new_key},
                                                        {acc_opts, acc_warnings} ->
        case Keyword.pop(acc_opts, legacy_key) do
          {nil, remaining_opts} ->
            {remaining_opts, acc_warnings}

          {value, remaining_opts} ->
            warning = "#{legacy_key} is deprecated, use #{new_key} instead"
            {Keyword.put(remaining_opts, new_key, value), [warning | acc_warnings]}
        end
      end)

    # Validate top_k with OpenAI models warning
    {top_k, opts} = Keyword.pop(opts, :openrouter_top_k)

    {opts, warnings} =
      if top_k && String.starts_with?(model.model, "openai/") do
        warning =
          "openrouter_top_k is not available for OpenAI models on OpenRouter and will be ignored"

        {opts, [warning | warnings]}
      else
        opts = if top_k, do: Keyword.put(opts, :openrouter_top_k, top_k), else: opts
        {opts, warnings}
      end

    {opts, Enum.reverse(warnings)}
  end

  # Req pipeline steps
  @impl ReqLLM.Provider
  def encode_body(request) do
    context_data =
      case request.options[:context] do
        %ReqLLM.Context{} = ctx ->
          model = request.options[:model]
          ReqLLM.Context.Codec.encode_request(ctx, model)

        _ ->
          %{messages: request.options[:messages] || []}
      end

    model_name = request.options[:model]

    body =
      %{model: model_name}
      |> Map.merge(context_data)
      |> add_basic_options(request.options)
      |> maybe_put(:stream, request.options[:stream])
      |> maybe_put(:models, request.options[:openrouter_models])
      |> maybe_put(:route, request.options[:openrouter_route])
      |> maybe_put(:provider, request.options[:openrouter_provider])
      |> maybe_put(:transforms, request.options[:openrouter_transforms])
      |> maybe_put(:top_k, request.options[:openrouter_top_k])
      |> maybe_put(:repetition_penalty, request.options[:openrouter_repetition_penalty])
      |> maybe_put(:min_p, request.options[:openrouter_min_p])
      |> maybe_put(:top_a, request.options[:openrouter_top_a])
      |> maybe_put(:top_logprobs, request.options[:openrouter_top_logprobs])

    body =
      case request.options[:tools] do
        tools when is_list(tools) and tools != [] ->
          body = Map.put(body, :tools, Enum.map(tools, &ReqLLM.Tool.to_schema(&1, :openai)))

          case request.options[:tool_choice] do
            nil -> body
            choice -> Map.put(body, :tool_choice, choice)
          end

        _ ->
          body
      end

    body =
      case request.options[:response_format] do
        format when is_map(format) -> Map.put(body, :response_format, format)
        _ -> body
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
        model_name = req.options[:model]
        model = %ReqLLM.Model{provider: :openrouter, model: model_name}
        is_streaming = req.options[:stream] == true

        if is_streaming do
          chunk_stream =
            resp.body
            |> Stream.flat_map(&ReqLLM.Response.Codec.decode_sse_event(&1, model))
            |> Stream.reject(&is_nil/1)

          response = %ReqLLM.Response{
            id: "stream-#{System.unique_integer([:positive])}",
            model: model_name,
            context: req.options[:context] || %ReqLLM.Context{messages: []},
            message: nil,
            stream?: true,
            stream: chunk_stream,
            usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
            finish_reason: nil,
            provider_meta: %{}
          }

          {req, %{resp | body: response}}
        else
          body = ensure_parsed_body(resp.body)
          {:ok, response} = ReqLLM.Response.Codec.decode_response(body, model)

          # Merge original context with the assistant response
          merged_response =
            ReqLLM.Context.merge_response(
              req.options[:context] || %ReqLLM.Context{messages: []},
              response
            )

          {req, %{resp | body: merged_response}}
        end

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

  # Helper function for adding basic body options
  defp add_basic_options(body, request_options) do
    # Define the standard OpenAI options that OpenRouter supports in the request body
    body_options = [
      :temperature,
      :max_tokens,
      :top_p,
      :frequency_penalty,
      :presence_penalty,
      :user,
      :seed,
      :logit_bias,
      :n
    ]

    Enum.reduce(body_options, body, fn key, acc ->
      maybe_put(acc, key, request_options[key])
    end)
  end
end

defmodule ReqLLM.Providers.XAI do
  @moduledoc """
  xAI (Grok) provider – OpenAI Chat Completions compatible with xAI's models and features.

  ## Protocol Usage

  Uses the generic `ReqLLM.Context.Codec` and `ReqLLM.Response.Codec` protocols.
  No custom wrapper modules – leverages the standard OpenAI-compatible codecs.

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
      reasoning_effort: [
        type: {:in, ~w(low medium high)},
        doc: "Reasoning effort level (grok-3-mini models only)"
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

  import ReqLLM.Provider.Utils,
    only: [maybe_put: 3, maybe_put_skip: 4, ensure_parsed_body: 1]

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
  Attaches the xAI plugin to a Req request.

  ## Parameters

    * `request` - The Req request to attach to
    * `model_input` - The model (ReqLLM.Model struct, string, or tuple) that triggers this provider
    * `opts` - Options keyword list (validated against comprehensive schema)

  ## Request Options

    * `:temperature` - Controls randomness (0.0-2.0). Defaults to 0.7
    * `:max_tokens` - Maximum tokens to generate. Defaults to 1024
    * `:max_completion_tokens` - Preferred over max_tokens for Grok-4
    * `:stream?` - Enable streaming responses. Defaults to false
    * `:base_url` - Override base URL. Defaults to provider default
    * `:messages` - Chat messages to send
    * `:system` - System message
    * `:reasoning_effort` - Reasoning effort (low, medium, high) for grok-3-mini models
    * `:search_parameters` - Live Search configuration
    * `:parallel_tool_calls` - Allow parallel function calls (default: true)
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
      case Keyword.get(opts_with_choice, :max_completion_tokens) ||
             Keyword.get(opts_with_choice, :max_tokens) do
        nil -> Keyword.put(opts_with_choice, :max_completion_tokens, 4096)
        tokens when tokens < 200 -> Keyword.put(opts_with_choice, :max_completion_tokens, 200)
        _value -> opts_with_choice
      end

    prepare_request(:chat, model_input, context, opts_with_max_tokens)
  end

  def prepare_request(operation, _model, _input, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: #{inspect(operation)} not supported by xAI provider. Supported operations: [:chat, :object]"
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
      |> maybe_put(:max_completion_tokens, request.options[:max_completion_tokens])
      |> maybe_put(:reasoning_effort, request.options[:reasoning_effort])
      |> maybe_put(:search_parameters, request.options[:search_parameters])
      |> maybe_put_skip(:parallel_tool_calls, request.options[:parallel_tool_calls], [true])
      |> maybe_put(:stream_options, request.options[:stream_options])

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
        model = %ReqLLM.Model{provider: :xai, model: model_name}
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
            reason: "xAI API error",
            status: status,
            response_body: resp.body
          )

        {req, err}
    end
  end

  # Helper function for adding basic body options
  defp add_basic_options(body, request_options) do
    # Define the standard OpenAI options that xAI supports in the request body
    body_options = [
      :temperature,
      :max_tokens,
      :top_p,
      :frequency_penalty,
      :presence_penalty,
      :user,
      :seed,
      :n
    ]

    Enum.reduce(body_options, body, fn key, acc ->
      maybe_put(acc, key, request_options[key])
    end)
  end
end

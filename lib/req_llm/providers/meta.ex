defmodule ReqLLM.Providers.Meta do
  @moduledoc """
  Meta Model API provider using the OpenAI-compatible Responses API.

  Meta exposes Muse models at `https://api.meta.ai/v1`. This provider supports
  text generation, streaming, reasoning effort, encrypted reasoning continuity,
  tool calling, structured output, and prompt-cache retention controls through
  ReqLLM's standard APIs.

  Requests default to stateless operation with encrypted reasoning returned so
  ReqLLM can preserve reasoning context across tool calls and conversation turns.

  ## Configuration

      MODEL_API_KEY=your-api-key

  ## Examples

      ReqLLM.generate_text("meta:muse-spark-1.1", "Hello!")

      ReqLLM.stream_text("meta:muse-spark-1.1", "Solve this carefully",
        reasoning_effort: :high,
        max_tokens: 1024
      )

      ReqLLM.generate_text("meta:muse-spark-1.1", "Summarize this conversation",
        provider_options: [prompt_cache_retention: "24h"]
      )

  Meta's native Llama payload helpers used by Amazon Bedrock live in
  `ReqLLM.Providers.Meta.Llama`.
  """

  use ReqLLM.Provider,
    id: :meta,
    default_base_url: "https://api.meta.ai/v1",
    default_env_key: "MODEL_API_KEY"

  use ReqLLM.Provider.Defaults

  alias ReqLLM.Providers.Meta.Llama
  alias ReqLLM.Providers.OpenAI.AdapterHelpers
  alias ReqLLM.Providers.OpenAI.ResponsesAPI

  @encrypted_reasoning_include ["reasoning.encrypted_content"]

  @provider_schema [
    include: [
      type: {:list, :string},
      doc: "Additional Responses API data to include in the response."
    ],
    max_output_tokens: [
      type: :pos_integer,
      doc: "Maximum generated tokens used by Meta's Responses API."
    ],
    parallel_tool_calls: [
      type: :boolean,
      doc: "Allow the model to request multiple tool calls in one response."
    ],
    prompt_cache_retention: [
      type: {:in, ["in_memory", "24h"]},
      doc: "Retention policy for Meta's automatic prompt cache."
    ],
    reasoning_summary: [
      type: {:in, [:auto, :concise, :detailed, "auto", "concise", "detailed"]},
      doc: "Requested reasoning summary detail."
    ],
    response_format: [
      type: :map,
      doc: "OpenAI-compatible JSON schema response format."
    ],
    store: [
      type: :boolean,
      doc: "Whether Meta may retain the response for server-side continuation."
    ]
  ]

  @doc false
  def display_name, do: "Meta Model API"

  def pre_validate_options(_operation, _model, opts) do
    ReqLLM.Provider.Reasoning.normalize_effort_option(opts)
  end

  @impl ReqLLM.Provider
  def prepare_request(:chat, model_spec, input, opts) do
    prepare_responses_request(model_spec, input, opts, :chat)
  end

  def prepare_request(:object, model_spec, input, opts) do
    prepare_object_request(model_spec, input, opts)
  end

  def prepare_request(operation, _model_spec, _input, _opts) do
    unsupported_operation(operation)
  end

  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts) do
    warnings = []

    {max_tokens, opts} = Keyword.pop(opts, :max_tokens)
    {opts, warnings} = translate_max_tokens(max_tokens, opts, warnings)
    {opts, warnings} = enforce_minimum_output_tokens(opts, warnings)
    {opts, warnings} = translate_reasoning_effort(opts, warnings)
    {opts, warnings} = drop_reasoning_token_budget(opts, warnings)

    {opts, Enum.reverse(warnings)}
  end

  @impl ReqLLM.Provider
  def build_body(request) do
    request = put_meta_defaults(request)

    request
    |> ResponsesAPI.build_body()
    |> maybe_put_store(request.options)
    |> maybe_put_prompt_cache_retention(request.options)
  end

  @impl ReqLLM.Provider
  def decode_response({request, %Req.Response{status: 200} = response}) do
    ResponsesAPI.decode_response({request, response})
  end

  def decode_response({request, response}) do
    error =
      ReqLLM.Error.API.Response.exception(
        reason: "Meta Model API error",
        status: response.status,
        response_body: response.body
      )

    {request, error}
  end

  @impl ReqLLM.Provider
  def decode_stream_event(event, model), do: ResponsesAPI.decode_stream_event(event, model)

  @impl ReqLLM.Provider
  def decode_stream_event(event, model, state) do
    ResponsesAPI.decode_stream_event(event, model, state)
  end

  @doc false
  def init_stream_state, do: ResponsesAPI.init_stream_state()

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    processed_opts =
      ReqLLM.Provider.Options.process_stream!(
        __MODULE__,
        opts[:operation] || :chat,
        model,
        context,
        opts
      )

    processed_opts =
      processed_opts
      |> put_meta_defaults()
      |> Keyword.put(:context, context)
      |> Keyword.put(:model, model.provider_model_id || model.id)
      |> Keyword.put(:req_llm_model, model)
      |> Keyword.put(:stream, true)

    api_key = ReqLLM.Keys.get!(model, processed_opts)
    base_url = ReqLLM.Provider.Options.effective_base_url(__MODULE__, model, processed_opts)

    headers =
      [
        {"Authorization", "Bearer " <> api_key},
        {"Content-Type", "application/json"},
        {"Accept", "text/event-stream"}
      ] ++ ReqLLM.Provider.Utils.extract_custom_headers(processed_opts[:req_http_options])

    body =
      %{options: processed_opts}
      |> build_body()
      |> ReqLLM.Schema.apply_property_ordering()
      |> Jason.encode!()

    url = String.trim_trailing(base_url, "/") <> ResponsesAPI.path()

    {:ok, Finch.build(:post, url, headers, body)}
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason:
           "Failed to build Meta Responses API streaming request: #{Exception.message(error)}"
       )}
  end

  @deprecated "Use ReqLLM.Providers.Meta.Llama.format_request/2"
  def format_request(context, opts \\ []), do: Llama.format_request(context, opts)

  @deprecated "Use ReqLLM.Providers.Meta.Llama.format_llama_prompt/1"
  def format_llama_prompt(messages), do: Llama.format_llama_prompt(messages)

  @deprecated "Use ReqLLM.Providers.Meta.Llama.parse_response/2"
  def parse_response(body, opts), do: Llama.parse_response(body, opts)

  @deprecated "Use ReqLLM.Providers.Meta.Llama.extract_usage/1"
  def extract_usage(body), do: Llama.extract_usage(body)

  @deprecated "Use ReqLLM.Providers.Meta.Llama.parse_stop_reason/1"
  def parse_stop_reason(reason), do: Llama.parse_stop_reason(reason)

  defp prepare_responses_request(model_spec, input, opts, operation) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(input, opts),
         opts_with_context =
           opts
           |> Keyword.put(:context, context)
           |> Keyword.put(:operation, operation),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, operation, model, opts_with_context) do
      processed_opts = put_meta_defaults(processed_opts)
      timeout = Keyword.get(processed_opts, :receive_timeout, thinking_timeout())

      request =
        Req.new(
          [
            url: ResponsesAPI.path(),
            method: :post,
            receive_timeout: timeout,
            pool_timeout: timeout
          ] ++ Keyword.get(opts, :req_http_options, [])
        )
        |> Req.Request.register_options(request_option_keys())
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, request_option_keys()) ++
            [
              model: model.id,
              base_url: Keyword.get(processed_opts, :base_url, default_base_url()),
              api_mod: ResponsesAPI
            ]
        )
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  defp prepare_object_request(model_spec, prompt, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)
    schema_name = Map.get(compiled_schema, :name, "output_schema")

    schema =
      compiled_schema.schema
      |> ReqLLM.Schema.to_json()
      |> AdapterHelpers.enforce_strict_recursive()

    response_format = %{
      type: "json_schema",
      json_schema: %{
        name: schema_name,
        strict: true,
        schema: schema
      }
    }

    opts =
      opts
      |> put_object_provider_options(response_format)
      |> ReqLLM.Provider.Options.put_model_max_tokens_default(model_spec, fallback: 4096)

    prepare_responses_request(model_spec, prompt, opts, :object)
  end

  defp request_option_keys do
    supported_provider_options() ++
      [
        :api_mod,
        :compiled_schema,
        :context,
        :defer_http_events_until_telemetry?,
        :max_output_tokens,
        :model,
        :operation,
        :provider_options,
        :reasoning_effort,
        :stream,
        :stream_transport,
        :text
      ]
  end

  defp put_meta_defaults(%{options: options} = request) do
    %{request | options: put_meta_defaults(options)}
  end

  defp put_meta_defaults(opts) when is_list(opts) do
    provider_opts =
      opts
      |> Keyword.get(:provider_options, [])
      |> Keyword.put_new(:store, false)
      |> Keyword.put_new(:include, @encrypted_reasoning_include)

    Keyword.put(opts, :provider_options, provider_opts)
  end

  defp put_meta_defaults(opts) when is_map(opts) do
    provider_opts =
      opts
      |> Map.get(:provider_options, [])
      |> Keyword.put_new(:store, false)
      |> Keyword.put_new(:include, @encrypted_reasoning_include)

    Map.put(opts, :provider_options, provider_opts)
  end

  defp maybe_put_prompt_cache_retention(body, opts) do
    case option_value(opts, :prompt_cache_retention) do
      nil -> body
      retention -> Map.put(body, "prompt_cache_retention", retention)
    end
  end

  defp maybe_put_store(body, opts) do
    case provider_option_value(opts, :store) do
      nil -> body
      store -> Map.put(body, "store", store)
    end
  end

  defp put_object_provider_options(opts, response_format) do
    provider_opts =
      case Keyword.get(opts, :provider_options, []) do
        provider_opts when is_map(provider_opts) ->
          provider_opts
          |> Map.put(:response_format, response_format)
          |> Map.put(:parallel_tool_calls, false)

        provider_opts ->
          provider_opts
          |> Keyword.put(:response_format, response_format)
          |> Keyword.put(:parallel_tool_calls, false)
      end

    Keyword.put(opts, :provider_options, provider_opts)
  end

  defp unsupported_operation(operation) do
    supported_operations = [:chat, :object]

    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: #{inspect(operation)} not supported by #{inspect(__MODULE__)}. Supported operations: #{inspect(supported_operations)}"
     )}
  end

  defp translate_max_tokens(nil, opts, warnings), do: {opts, warnings}

  defp translate_max_tokens(max_tokens, opts, warnings) do
    if Keyword.has_key?(opts, :max_output_tokens) do
      {opts,
       [
         "Meta uses max_output_tokens; ignored max_tokens because max_output_tokens is set."
         | warnings
       ]}
    else
      {Keyword.put(opts, :max_output_tokens, max_tokens),
       ["Meta uses max_output_tokens; translated max_tokens." | warnings]}
    end
  end

  defp enforce_minimum_output_tokens(opts, warnings) do
    case Keyword.get(opts, :max_output_tokens) do
      tokens when is_integer(tokens) and tokens < 16 ->
        {Keyword.put(opts, :max_output_tokens, 16),
         ["Raised :max_output_tokens to Meta API minimum (16)." | warnings]}

      _tokens ->
        {opts, warnings}
    end
  end

  defp translate_reasoning_effort(opts, warnings) do
    case Keyword.pop(opts, :reasoning_effort) do
      {nil, opts} ->
        {opts, warnings}

      {:default, opts} ->
        {opts, warnings}

      {:none, opts} ->
        {Keyword.put(opts, :reasoning_effort, "minimal"),
         [
           "Meta Muse models do not accept reasoning_effort :none; translated it to :minimal."
           | warnings
         ]}

      {effort, opts} when effort in [:minimal, :low, :medium, :high, :xhigh] ->
        {Keyword.put(opts, :reasoning_effort, Atom.to_string(effort)), warnings}

      {effort, opts} when is_binary(effort) ->
        {Keyword.put(opts, :reasoning_effort, effort), warnings}
    end
  end

  defp drop_reasoning_token_budget(opts, warnings) do
    case Keyword.pop(opts, :reasoning_token_budget) do
      {nil, opts} ->
        {opts, warnings}

      {_budget, opts} ->
        {opts,
         [
           "Meta exposes reasoning effort but not reasoning_token_budget; removed the token budget."
           | warnings
         ]}
    end
  end

  defp thinking_timeout do
    Application.get_env(:req_llm, :thinking_timeout, 300_000)
  end

  defp option_value(options, key) when is_list(options) do
    Keyword.get(options, key) || Keyword.get(Keyword.get(options, :provider_options, []), key)
  end

  defp option_value(options, key) when is_map(options) do
    Map.get(options, key) || Keyword.get(Map.get(options, :provider_options, []), key)
  end

  defp option_value(_options, _key), do: nil

  defp provider_option_value(options, key) when is_list(options) do
    provider_option_from_container(Keyword.get(options, :provider_options, []), key)
  end

  defp provider_option_value(options, key) when is_map(options) do
    case Map.fetch(options, :provider_options) do
      {:ok, provider_opts} -> provider_option_from_container(provider_opts, key)
      :error -> Map.get(options, key) || Map.get(options, Atom.to_string(key))
    end
  end

  defp provider_option_value(_options, _key), do: nil

  defp provider_option_from_container(provider_opts, key) when is_list(provider_opts) do
    Keyword.get(provider_opts, key)
  end

  defp provider_option_from_container(provider_opts, key) when is_map(provider_opts) do
    Map.get(provider_opts, key) || Map.get(provider_opts, Atom.to_string(key))
  end

  defp provider_option_from_container(_provider_opts, _key), do: nil
end

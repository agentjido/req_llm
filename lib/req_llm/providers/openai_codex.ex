defmodule ReqLLM.Providers.OpenAICodex do
  @moduledoc """
  OpenAI Codex provider backed by the ChatGPT Codex responses endpoint.

  Uses OAuth credentials against `https://chatgpt.com/backend-api/codex/responses`
  and reuses the standard OpenAI Responses API encoding/decoding where possible.
  """

  use ReqLLM.Provider,
    id: :openai_codex,
    default_base_url: "https://chatgpt.com/backend-api"

  alias ReqLLM.Providers.OpenAI
  alias ReqLLM.Providers.OpenAI.ResponsesAPI

  @provider_schema [
    access_token: [
      type: :string,
      doc: "OAuth access token used as Authorization Bearer credential"
    ],
    auth_mode: [
      type: {:in, [:api_key, :oauth]},
      default: :oauth,
      doc: "Authentication mode. OpenAI Codex only supports :oauth."
    ],
    oauth_file: [
      type: :string,
      doc: "Path to an oauth/auth JSON file with provider credentials"
    ],
    auth_file: [
      type: :string,
      doc: "Alias for :oauth_file"
    ],
    oauth_http_options: [
      type: {:list, :any},
      doc: "Req options for OAuth refresh HTTP requests"
    ],
    chatgpt_account_id: [
      type: :string,
      doc: "Explicit ChatGPT account id override for Codex requests"
    ],
    codex_originator: [
      type: :string,
      default: "pi",
      doc: "Originator header sent to the ChatGPT Codex backend"
    ],
    max_completion_tokens: [
      type: :integer,
      doc: "Maximum completion tokens for responses-style models"
    ],
    openai_structured_output_mode: [
      type: {:in, [:auto, :json_schema, :tool_strict]},
      default: :auto,
      doc: "Structured output strategy reused from the OpenAI provider"
    ],
    openai_json_schema_strict: [
      type: :boolean,
      default: true,
      doc: "Whether json_schema structured output uses strict mode"
    ],
    response_format: [
      type: :map,
      doc: "Responses API response format configuration"
    ],
    openai_parallel_tool_calls: [
      type: {:or, [:boolean, nil]},
      default: nil,
      doc: "Override parallel_tool_calls setting"
    ],
    previous_response_id: [
      type: :string,
      doc: "Previous response ID for tool resume flow"
    ],
    store: [
      type: {:in, [false]},
      default: false,
      doc: "Codex requests are always sent with store disabled"
    ],
    tool_outputs: [
      type: {:list, :any},
      doc: "Tool execution results for Responses API tool resume flow"
    ],
    service_tier: [
      type: {:or, [:atom, :string]},
      doc: "Service tier for request prioritization"
    ],
    openai_stream_transport: [
      type: {:in, [:sse, :websocket, "sse", "websocket"]},
      default: :sse,
      doc: "Streaming transport for the Codex Responses endpoint"
    ],
    openai_reuse_websocket: [
      type: :boolean,
      default: false,
      doc:
        "Request that higher-level agent runtimes reuse one Codex Responses WebSocket across multiple response.create turns."
    ],
    openai_websocket_session: [
      type: :any,
      doc:
        "Existing ReqLLM.Streaming.WebSocketSession pid to reuse for Codex Responses streams. " <>
          "When set, ReqLLM sends the response.create event on that socket and leaves socket ownership to the caller."
    ],
    verbosity: [
      type: {:or, [:atom, :string]},
      doc: "Text verbosity. Defaults to medium."
    ]
  ]

  @codex_response_statuses ~w(completed incomplete failed cancelled queued in_progress)

  @impl ReqLLM.Provider
  def oauth_provider_id, do: "openai-codex"

  @impl ReqLLM.Provider
  def refresh_oauth_credentials(credentials, opts) do
    ReqLLM.Providers.OpenAI.OAuth.refresh(credentials, opts)
  end

  def account_id_from_token(token) do
    ReqLLM.Providers.OpenAI.OAuth.account_id_from_token(token)
  end

  @impl ReqLLM.Provider
  def prepare_request(:chat, model_spec, prompt, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(prompt, opts),
         opts_with_context = Keyword.put(opts, :context, context),
         http_opts = Keyword.get(opts, :req_http_options, []),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, :chat, model, opts_with_context) do
      req_keys =
        supported_provider_options() ++
          [
            :context,
            :operation,
            :text,
            :stream,
            :model,
            :provider_options,
            :service_tier,
            :max_completion_tokens,
            :reasoning_effort
          ]

      timeout = get_timeout(processed_opts)

      request =
        Req.new(
          [
            url: codex_path(),
            method: :post,
            receive_timeout: timeout,
            pool_timeout: timeout
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: model.id,
              base_url:
                ReqLLM.Provider.Options.effective_base_url(__MODULE__, model, processed_opts)
            ]
        )
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  def prepare_request(:object, model_spec, prompt, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)
    {:ok, model} = ReqLLM.model(model_spec)

    case OpenAI.determine_output_mode(model, opts) do
      :json_schema ->
        prepare_json_schema_request(model_spec, prompt, compiled_schema, opts)

      :tool_strict ->
        prepare_strict_tool_request(model_spec, prompt, compiled_schema, opts)
    end
  end

  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    {:ok, %LLMDB.Model{} = model} = ReqLLM.model(model_input)

    if model.provider != __MODULE__.provider_id() do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    ensure_oauth_mode!(user_opts)

    credential = ReqLLM.Auth.resolve!(model, user_opts)
    account_id = resolve_account_id!(credential, user_opts)
    originator = codex_originator(user_opts)
    extra_option_keys = ReqLLM.Provider.Defaults.extra_option_keys(__MODULE__)

    request
    |> Req.Request.put_header("content-type", "application/json")
    |> Req.Request.put_header("authorization", "Bearer #{credential.token}")
    |> Req.Request.put_header("chatgpt-account-id", account_id)
    |> Req.Request.put_header("originator", originator)
    |> Req.Request.register_options(extra_option_keys)
    |> Req.Request.merge_options(
      ReqLLM.Provider.Defaults.finch_option(request) ++
        [
          model: model.provider_model_id || model.id,
          auth: {:bearer, credential.token}
        ] ++ user_opts
    )
    |> attach_retry(user_opts)
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.append_request_steps(llm_encode_body: &encode_body/1)
    |> Req.Request.append_response_steps(llm_decode_response: &decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> ReqLLM.Step.Fixture.maybe_attach(model, user_opts)
  end

  @impl ReqLLM.Provider
  def encode_body(request) do
    context = request.options[:context] || %ReqLLM.Context{messages: []}
    model_name = request.options[:model] || request.options[:id]
    body = build_codex_body(context, model_name, request.options, request)
    encoded = body |> ReqLLM.Schema.apply_property_ordering() |> Jason.encode!()
    Map.put(request, :body, encoded)
  end

  @impl ReqLLM.Provider
  def decode_response({req, resp}) do
    case resp do
      %Req.Response{status: 200, body: body} when is_binary(body) ->
        decode_sse_response({req, resp, body})

      _ ->
        ResponsesAPI.decode_response({req, resp})
    end
  end

  @impl ReqLLM.Provider
  def init_stream_state(_model), do: ResponsesAPI.init_stream_state()

  @impl ReqLLM.Provider
  def decode_stream_event(event, model) do
    {chunks, _state} = decode_stream_event(event, model, nil)
    chunks
  end

  @impl ReqLLM.Provider
  def decode_stream_event(event, model, state) do
    normalized_event = normalize_stream_event!(event)
    ResponsesAPI.decode_stream_event(normalized_event, model, state)
  end

  def stream_transport(_model, opts) do
    provider_opts = Keyword.get(opts, :provider_options, [])

    case Keyword.get(provider_opts, :openai_stream_transport, :sse) do
      transport when transport in [:websocket, "websocket"] -> :websocket
      _ -> :http
    end
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    opts = normalize_stream_opts(opts)
    ensure_oauth_mode!(opts)

    credential = ReqLLM.Auth.resolve!(model, opts)
    account_id = resolve_account_id!(credential, opts)
    base_url = ReqLLM.Provider.Options.effective_base_url(__MODULE__, model, opts)

    cleaned_opts =
      opts
      |> Keyword.delete(:finch_name)
      |> Keyword.delete(:compiled_schema)
      |> Keyword.put(:provider_options, Keyword.get(opts, :provider_options, []))
      |> Keyword.put(:stream, true)
      |> Keyword.put(:model, model.id)
      |> Keyword.put(:context, context)
      |> Keyword.put(:base_url, base_url)

    body = build_codex_body(context, model.id, cleaned_opts, nil)
    url = codex_url(base_url)

    headers = [
      {"authorization", "Bearer " <> credential.token},
      {"chatgpt-account-id", account_id},
      {"originator", codex_originator(opts)},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"},
      {"openai-beta", "responses=experimental"}
    ]

    encoded = body |> ReqLLM.Schema.apply_property_ordering() |> Jason.encode!()
    {:ok, Finch.build(:post, url, headers, encoded)}
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build OpenAI Codex streaming request: #{Exception.message(error)}"
       )}
  end

  def attach_websocket_stream(model, context, opts) do
    opts = normalize_stream_opts(opts)
    ensure_oauth_mode!(opts)

    credential = ReqLLM.Auth.resolve!(model, opts)
    account_id = resolve_account_id!(credential, opts)
    base_url = ReqLLM.Provider.Options.effective_base_url(__MODULE__, model, opts)
    headers = websocket_headers(credential.token, account_id, opts)
    url = codex_websocket_url(base_url)

    cleaned_opts =
      opts
      |> Keyword.delete(:finch_name)
      |> Keyword.delete(:compiled_schema)
      |> Keyword.put(:provider_options, Keyword.get(opts, :provider_options, []))
      |> Keyword.put(:stream, nil)
      |> Keyword.put(:model, model.id)
      |> Keyword.put(:context, context)
      |> Keyword.put(:base_url, base_url)

    body = build_codex_body(context, model.id, cleaned_opts, nil)
    create_event = Map.put(body, "type", "response.create")

    {:ok,
     %{
       url: url,
       headers: headers,
       initial_messages: [Jason.encode!(create_event)],
       http_context: ReqLLM.Providers.OpenAI.WebSocket.http_context(url, headers),
       canonical_json: body
     }}
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build OpenAI Codex websocket request: #{Exception.message(error)}"
       )}
  end

  def start_responses_session(%LLMDB.Model{} = model, opts \\ []) do
    opts = normalize_stream_opts(opts)
    ensure_oauth_mode!(opts)

    credential = ReqLLM.Auth.resolve!(model, opts)
    account_id = resolve_account_id!(credential, opts)
    base_url = ReqLLM.Provider.Options.effective_base_url(__MODULE__, model, opts)

    ReqLLM.Streaming.WebSocketSession.start_link(codex_websocket_url(base_url),
      headers: websocket_headers(credential.token, account_id, opts)
    )
  end

  defp build_codex_body(context, model_name, opts, request) do
    opts = opts |> ensure_provider_options() |> force_store_false()
    body = ResponsesAPI.build_request_body(context, model_name, opts, request)
    provider_opts = provider_options(opts)
    instructions = extract_instructions(context) || ""

    body =
      if tool_resume_body?(body) do
        Map.delete(body, "previous_response_id")
      else
        body
      end

    body
    |> Map.put("input", Enum.reject(List.wrap(body["input"]), &system_input?/1))
    |> Map.delete("max_output_tokens")
    |> Map.put("store", false)
    |> Map.put("stream", true)
    |> Map.put("include", ["reasoning.encrypted_content"])
    |> Map.put_new("text", %{"verbosity" => normalize_codex_verbosity(provider_opts[:verbosity])})
    |> Map.put("instructions", instructions)
    |> maybe_put_parallel_tool_calls(provider_opts[:openai_parallel_tool_calls])
  end

  defp ensure_provider_options(opts) when is_list(opts),
    do: Keyword.put_new(opts, :provider_options, [])

  defp ensure_provider_options(opts), do: opts

  defp force_store_false(opts) when is_list(opts) do
    provider_opts = opts |> Keyword.get(:provider_options, []) |> provider_options_store_false()
    Keyword.put(opts, :provider_options, provider_opts)
  end

  defp force_store_false(opts) when is_map(opts) do
    provider_opts = opts |> Map.get(:provider_options, []) |> provider_options_store_false()
    Map.put(opts, :provider_options, provider_opts)
  end

  defp provider_options_store_false(provider_opts) when is_list(provider_opts),
    do: Keyword.put(provider_opts, :store, false)

  defp provider_options_store_false(provider_opts) when is_map(provider_opts),
    do: provider_opts |> Map.to_list() |> Keyword.put(:store, false)

  defp provider_options_store_false(_provider_opts), do: [store: false]

  defp tool_resume_body?(%{"input" => input}) when is_list(input) do
    Enum.any?(input, fn
      %{"type" => "function_call_output", "call_id" => id} when is_binary(id) -> true
      _ -> false
    end)
  end

  defp tool_resume_body?(_), do: false

  defp normalize_stream_event!(%{data: "[DONE]"} = event), do: event

  defp normalize_stream_event!(%{data: data} = event) when is_map(data) do
    case stream_event_type(event, data) do
      "error" ->
        raise RuntimeError, codex_error_message(data)

      "response.failed" ->
        message = get_in(data, ["response", "error", "message"]) || "Codex response failed"
        raise RuntimeError, message

      "response.done" ->
        put_event_type(event, data, "response.completed")

      "response.completed" ->
        normalize_response_status(event, data)

      "response.incomplete" ->
        normalize_response_status(event, data)

      _ ->
        event
    end
  end

  defp normalize_stream_event!(event), do: event

  defp stream_event_type(event, data) do
    Map.get(event, :event) || Map.get(event, "event") || data["event"] || data["type"]
  end

  defp put_event_type(event, data, type) do
    data =
      data
      |> Map.put("type", type)
      |> Map.put("event", type)
      |> normalize_response_payload()

    event
    |> Map.put(:data, data)
    |> Map.put(:event, type)
  end

  defp normalize_response_status(event, data) do
    normalized = normalize_response_payload(data)

    event
    |> Map.put(:data, normalized)
    |> maybe_put_event(stream_event_type(event, normalized))
  end

  defp maybe_put_event(event, nil), do: event
  defp maybe_put_event(event, type), do: Map.put(event, :event, type)

  defp normalize_response_payload(data) do
    update_in(data, ["response"], fn
      %{} = response ->
        case Map.get(response, "status") do
          status when status in @codex_response_statuses -> response
          status when is_binary(status) -> Map.put(response, "status", status)
          _ -> response
        end

      other ->
        other
    end)
  end

  defp codex_error_message(%{"message" => message}) when is_binary(message) and message != "",
    do: "Codex error: " <> message

  defp codex_error_message(%{"code" => code}) when is_binary(code) and code != "",
    do: "Codex error: " <> code

  defp codex_error_message(data), do: "Codex error: " <> Jason.encode!(data)

  defp extract_instructions(%ReqLLM.Context{messages: messages}) do
    messages
    |> Enum.filter(&(&1.role == :system))
    |> Enum.map(&message_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp message_text(%ReqLLM.Message{content: content}) when is_binary(content),
    do: String.trim(content)

  defp message_text(%ReqLLM.Message{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", &(&1.text || ""))
    |> String.trim()
  end

  defp message_text(_message), do: ""

  defp system_input?(%{"role" => "system"}), do: true
  defp system_input?(_item), do: false

  defp provider_options(opts) when is_list(opts), do: Keyword.get(opts, :provider_options, [])
  defp provider_options(opts) when is_map(opts), do: Map.get(opts, :provider_options, [])
  defp provider_options(_opts), do: []

  defp ensure_oauth_mode!(opts) do
    provider_opts = provider_options(opts)
    auth_mode = Keyword.get(opts, :auth_mode) || Keyword.get(provider_opts, :auth_mode) || :oauth

    if auth_mode not in [:oauth, "oauth"] do
      raise ReqLLM.Error.Invalid.Parameter.exception(
              parameter: "OpenAI Codex requires provider_options[:auth_mode] to be :oauth"
            )
    end
  end

  defp resolve_account_id!(credential, opts) do
    explicit =
      Keyword.get(opts, :chatgpt_account_id) ||
        opts |> provider_options() |> Keyword.get(:chatgpt_account_id)

    explicit || credential.account_id ||
      raise ReqLLM.Error.Invalid.Parameter.exception(
              parameter:
                "OpenAI Codex requires :chatgpt_account_id or an OAuth token containing chatgpt_account_id"
            )
  end

  defp codex_originator(opts) do
    opts
    |> provider_options()
    |> Keyword.get(:codex_originator, "pi")
  end

  defp codex_path, do: "/codex/responses"

  defp codex_url(base_url) do
    normalized = String.replace_trailing(base_url, "/", "")

    cond do
      String.ends_with?(normalized, "/codex/responses") -> normalized
      String.ends_with?(normalized, "/codex") -> normalized <> "/responses"
      true -> normalized <> codex_path()
    end
  end

  defp codex_websocket_url(base_url) do
    base_url
    |> codex_url()
    |> ReqLLM.Providers.OpenAI.WebSocket.websocket_url("")
  end

  defp websocket_headers(token, account_id, opts) do
    request_id = codex_request_id(opts)

    [
      {"authorization", "Bearer " <> token},
      {"chatgpt-account-id", account_id},
      {"originator", codex_originator(opts)},
      {"openai-beta", "responses_websockets=2026-02-06"},
      {"x-client-request-id", request_id},
      {"session_id", request_id}
    ] ++ ReqLLM.Provider.Utils.extract_custom_headers(opts[:req_http_options])
  end

  defp codex_request_id(opts) do
    opts
    |> provider_options()
    |> Keyword.get_lazy(:session_id, fn -> "req_#{System.unique_integer([:positive])}" end)
  end

  defp normalize_stream_opts(opts) when is_list(opts) do
    provider_opts =
      opts
      |> provider_options()
      |> Keyword.put_new(:auth_mode, :oauth)

    opts
    |> Keyword.put(:provider_options, provider_opts)
    |> Keyword.put_new(:auth_mode, :oauth)
  end

  defp normalize_stream_opts(opts), do: opts

  defp get_timeout(opts) do
    Keyword.get(opts, :receive_timeout) ||
      Application.get_env(:req_llm, :thinking_timeout, 300_000)
  end

  defp maybe_put_parallel_tool_calls(map, nil), do: Map.put(map, "parallel_tool_calls", true)
  defp maybe_put_parallel_tool_calls(map, value), do: Map.put(map, "parallel_tool_calls", value)

  defp normalize_codex_verbosity(nil), do: "medium"
  defp normalize_codex_verbosity(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_codex_verbosity(value) when is_binary(value), do: value

  defp attach_retry(request, opts) do
    max_retries = Keyword.get(opts, :max_retries, 3)

    Req.Request.merge_options(request,
      retry: &should_retry?/2,
      max_retries: max_retries,
      retry_log_level: false
    )
  end

  def should_retry?(request, %Req.TransportError{reason: reason})
      when reason in [:closed, :timeout, :econnrefused] do
    delay_for_retry(request)
  end

  def should_retry?(request, %Req.Response{status: status})
      when status in [429, 500, 502, 503, 504] do
    delay_for_retry(request)
  end

  def should_retry?(_request, _response_or_exception), do: false

  defp delay_for_retry(request) do
    retry_count = request.options[:retry_count] || 0
    {:delay, min(1_000 * trunc(:math.pow(2, retry_count)), 8_000)}
  end

  defp prepare_json_schema_request(model_spec, prompt, compiled_schema, opts) do
    schema_name = Map.get(compiled_schema, :name, "output_schema")
    json_schema = ReqLLM.Schema.to_json(compiled_schema.schema)

    provider_opts = Keyword.get(opts, :provider_options, [])
    strict = Keyword.get(provider_opts, :openai_json_schema_strict, true)

    json_schema =
      if strict do
        enforce_strict_schema_requirements(json_schema)
      else
        json_schema
      end

    response_format = %{
      type: "json_schema",
      json_schema: %{
        name: schema_name,
        strict: strict,
        schema: json_schema
      }
    }

    opts_with_format =
      opts
      |> Keyword.update(
        :provider_options,
        [response_format: response_format, openai_parallel_tool_calls: false],
        fn existing_provider_opts ->
          existing_provider_opts
          |> Keyword.put(:response_format, response_format)
          |> Keyword.put(:openai_parallel_tool_calls, false)
        end
      )
      |> put_default_max_tokens_for_model(model_spec)
      |> Keyword.put(:operation, :object)

    prepare_request(:chat, model_spec, prompt, opts_with_format)
  end

  defp prepare_strict_tool_request(model_spec, prompt, compiled_schema, opts) do
    structured_output_tool =
      ReqLLM.Tool.new!(
        name: "structured_output",
        description: "Generate structured output matching the provided schema",
        parameter_schema: compiled_schema.schema,
        strict: true,
        callback: fn _args -> {:ok, "structured output generated"} end
      )

    opts_with_tool =
      opts
      |> Keyword.update(:tools, [structured_output_tool], &[structured_output_tool | &1])
      |> Keyword.put(:tool_choice, %{
        type: "function",
        function: %{name: "structured_output"}
      })
      |> Keyword.update(
        :provider_options,
        [],
        &Keyword.put(&1, :openai_parallel_tool_calls, false)
      )
      |> put_default_max_tokens_for_model(model_spec)
      |> Keyword.put(:operation, :object)

    prepare_request(:chat, model_spec, prompt, opts_with_tool)
  end

  defp put_default_max_tokens_for_model(opts, model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, _model} ->
        Keyword.put_new(opts, :max_completion_tokens, 4096)

      _ ->
        Keyword.put_new(opts, :max_completion_tokens, 4096)
    end
  end

  defp enforce_strict_schema_requirements(schema) do
    ReqLLM.Providers.OpenAI.AdapterHelpers.enforce_strict_recursive(schema)
  end

  defp decode_sse_response({req, resp, body}) do
    {:ok, model} =
      ReqLLM.model(%{provider: :openai_codex, id: req.options[:model] || req.options[:id]})

    context = req.options[:context] || %ReqLLM.Context{messages: []}
    events = ReqLLM.Streaming.SSE.parse_sse_binary(body)
    state = ResponsesAPI.init_stream_state()

    {chunks, _state} =
      Enum.reduce(events, {[], state}, fn event, {acc_chunks, acc_state} ->
        {event_chunks, next_state} = decode_stream_event(event, model, acc_state)
        {acc_chunks ++ event_chunks, next_state}
      end)

    metadata = extract_metadata(chunks)
    builder = ReqLLM.Provider.ResponseBuilder.for_model(model)

    case builder.build_response(chunks, metadata, context: context, model: model) do
      {:ok, response} ->
        {req, %{resp | body: response}}

      {:error, error} ->
        {req,
         ReqLLM.Error.API.Response.exception(
           reason: "Failed to decode OpenAI Codex SSE response: #{Exception.message(error)}",
           status: resp.status,
           response_body: body
         )}
    end
  rescue
    error ->
      {req,
       ReqLLM.Error.API.Response.exception(
         reason: "Failed to decode OpenAI Codex SSE response: #{Exception.message(error)}",
         status: resp.status,
         response_body: body
       )}
  end

  defp extract_metadata(chunks) do
    Enum.reduce(chunks, %{}, fn
      %ReqLLM.StreamChunk{type: :meta, metadata: meta}, acc when is_map(meta) ->
        usage =
          Map.get(meta, :usage) || Map.get(meta, "usage")

        acc =
          if is_map(usage) do
            Map.update(acc, :usage, usage, &ReqLLM.Usage.merge(&1, usage))
          else
            acc
          end

        Map.merge(acc, Map.drop(meta, [:usage, "usage", :terminal?, "terminal?"]))

      _chunk, acc ->
        acc
    end)
  end
end

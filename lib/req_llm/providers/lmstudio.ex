defmodule ReqLLM.Providers.LMStudio do
  @moduledoc """
  Local inference through LM Studio's OpenAI-compatible API.

  Supports chat, streaming, tool calling, image inputs, structured output, and
  embeddings when the selected model supports them. Model identifiers come from
  LM Studio's `/v1/models` endpoint; catalog membership is not required.

      model = ReqLLM.model!(%{provider: :lmstudio, id: "my-local-model"})
      ReqLLM.generate_text(model, "Hello!", reasoning_effort: :none)

  The default endpoint is `http://127.0.0.1:1234/v1`. Override it with `base_url`
  on a request or model, or `config :req_llm, :lmstudio, base_url: "..."`.

  Authentication is optional. For servers requiring a token, use `api_key`,
  `config :req_llm, :lmstudio_api_key`, or `LMSTUDIO_API_KEY`, in that order.

  Provider options include `ttl` (JIT-loaded model idle time in seconds),
  `repeat_penalty`, and `response_format`. Context size and model loading are
  configured in LM Studio. See the LM Studio provider guide for details.
  """

  use ReqLLM.Provider,
    id: :lmstudio,
    default_base_url: "http://127.0.0.1:1234/v1",
    default_env_key: "LMSTUDIO_API_KEY"

  @reasoning_efforts [:none, :minimal, :low, :medium, :high, :xhigh]
  @reasoning_effort_strings Enum.map(@reasoning_efforts, &Atom.to_string/1)

  @provider_schema [
    ttl: [type: :non_neg_integer, doc: "Idle time in seconds for a JIT-loaded model"],
    repeat_penalty: [type: :float, doc: "Repetition penalty supported by the model runtime"],
    response_format: [type: :map, doc: "OpenAI-compatible response format configuration"]
  ]

  @doc "Returns the provider name used in diagnostics."
  def display_name, do: "LM Studio"

  @doc """
  Prepares chat, structured-output, or embedding requests.

  Explicit model maps are normalized without requiring catalog membership.
  Structured output uses the compiled schema as a native JSON response format.
  Unsupported operations return a structured parameter error.
  """
  @impl ReqLLM.Provider
  def prepare_request(:object, model_spec, prompt, opts) do
    ReqLLM.Provider.Defaults.prepare_json_schema_object_request(
      __MODULE__,
      model_spec,
      prompt,
      opts,
      strict: true
    )
  end

  def prepare_request(operation, model_spec, input, opts) when operation in [:chat, :embedding] do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  def prepare_request(operation, _model_spec, _input, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "LM Studio does not support operation #{inspect(operation)}"
     )}
  end

  @doc """
  Attaches the standard ReqLLM request and response pipeline with optional auth.

  A configured LM Studio key becomes a bearer token; an absent key adds no auth.
  Provider model identifiers are preserved on the wire.
  """
  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    {:ok, %LLMDB.Model{} = model} = ReqLLM.model(model_input)

    if model.provider != provider_id() do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    request
    |> Req.Request.put_header("content-type", "application/json")
    |> put_auth(optional_api_key(user_opts))
    |> Req.Request.register_options(ReqLLM.Provider.Defaults.extra_option_keys(__MODULE__))
    |> Req.Request.merge_options(
      ReqLLM.Provider.Defaults.finch_option(request) ++
        user_opts ++ [model: model.provider_model_id || model.id]
    )
    |> ReqLLM.Step.Retry.attach(user_opts)
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.prepend_request_steps(llm_encode_body: &encode_body/1)
    |> Req.Request.append_response_steps(llm_decode_response: &decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> ReqLLM.Step.Telemetry.attach(model, user_opts)
    |> ReqLLM.Step.Fixture.maybe_attach(model, user_opts)
  end

  @doc """
  Builds a Finch SSE request with the same model, endpoint, and auth as chat.

  Uses the provider body encoder to preserve tools, images, structured-output
  schemas, and translated options. Construction failures return an API error.
  """
  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    opts =
      ReqLLM.Provider.Options.process_stream!(
        __MODULE__,
        opts[:operation] || :chat,
        model,
        context,
        opts
      )

    url = String.trim_trailing(Keyword.fetch!(opts, :base_url), "/") <> "/chat/completions"

    headers =
      [{"Content-Type", "application/json"}, {"Accept", "text/event-stream"}] ++
        auth_headers(optional_api_key(opts)) ++
        ReqLLM.Provider.Utils.extract_custom_headers(opts[:req_http_options])

    {:ok, Finch.build(:post, url, headers, encode_stream_body(model, context, opts))}
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build LM Studio stream request: #{Exception.message(error)}"
       )}
  end

  @doc """
  Extends the OpenAI-compatible body with LM Studio's chat inference controls.

  TTL, repetition penalty, and reasoning effort are emitted for chat and object
  requests. Embeddings retain the default embedding body format.
  """
  @impl ReqLLM.Provider
  def build_body(request) do
    body = ReqLLM.Provider.Defaults.default_build_body(request)

    if request.options[:operation] == :embedding do
      body
    else
      body
      |> maybe_put(:ttl, request.options[:ttl])
      |> maybe_put(:repeat_penalty, request.options[:repeat_penalty])
      |> maybe_put(:reasoning_effort, request.options[:reasoning_effort])
    end
  end

  @doc """
  Normalizes reasoning effort while retaining canonical atoms for validation.

  The default effort is omitted and `:max` is clamped to `:xhigh` with a warning.
  Unsupported values are omitted with a warning. Reprocessing is idempotent;
  conversion to the wire string occurs only when building the request body.
  """
  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts) do
    {effort, opts} = Keyword.pop(opts, :reasoning_effort)

    case effort do
      value when value in [nil, :default, "default"] ->
        {opts, []}

      value when value in @reasoning_efforts or value in @reasoning_effort_strings ->
        {Keyword.put(opts, :reasoning_effort, normalize_effort(value)), []}

      value when value in [:max, "max"] ->
        {Keyword.put(opts, :reasoning_effort, :xhigh),
         ["LM Studio reasoning_effort :max was clamped to :xhigh"]}

      _ ->
        {opts, ["Unsupported LM Studio reasoning_effort #{inspect(effort)} will be ignored"]}
    end
  end

  defp optional_api_key(opts) do
    with nil <- Keyword.get(opts, :api_key),
         nil <- Application.get_env(:req_llm, :lmstudio_api_key),
         nil <- System.get_env(default_env_key()) do
      nil
    else
      key when is_binary(key) and byte_size(key) > 0 -> key
      _ -> raise ReqLLM.Error.Invalid.Parameter, parameter: "LM Studio API key must be non-empty"
    end
  end

  defp put_auth(request, nil), do: request

  defp put_auth(request, key) do
    request
    |> Req.Request.put_header("authorization", "Bearer " <> key)
    |> Req.Request.merge_options(auth: {:bearer, key})
  end

  defp auth_headers(nil), do: []
  defp auth_headers(key), do: [{"Authorization", "Bearer " <> key}]

  defp maybe_put(body, _key, nil), do: body

  defp maybe_put(body, :reasoning_effort, value),
    do: Map.put(body, :reasoning_effort, to_string(value))

  defp maybe_put(body, key, value), do: Map.put(body, key, value)

  defp normalize_effort(effort) when is_atom(effort), do: effort
  defp normalize_effort(effort), do: String.to_existing_atom(effort)

  defp encode_stream_body(model, context, opts) do
    req_opts =
      opts
      |> Keyword.delete(:finch_name)
      |> Keyword.put(:model, model.provider_model_id || model.id)
      |> Keyword.put(:context, context)
      |> Keyword.put(:stream, true)

    Req.new(method: :post, url: "http://localhost")
    |> Req.Request.register_options(
      ReqLLM.Provider.Defaults.extra_option_keys(__MODULE__) ++ [:context, :operation]
    )
    |> Req.Request.merge_options(req_opts)
    |> encode_body()
    |> Req.Steps.encode_body()
    |> Map.fetch!(:body)
  end
end

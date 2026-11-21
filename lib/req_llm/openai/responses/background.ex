defmodule ReqLLM.OpenAI.Responses.Background do
  @moduledoc """
  Submits, retrieves, and cancels OpenAI background responses over HTTP.

  Each operation returns a `ReqLLM.Response`. Persist its `id` to resume by ID
  from another process using the same OpenAI project. Read the provider status
  at `response.provider_meta["status"]`. The provider metadata also retains the
  original `"output"` items, `"usage"`, `"error"`, and `"incomplete_details"`
  when returned.

  Callers manage polling, verified webhooks, and local tool execution. See the
  [OpenAI guide](openai.html#background-responses) for a complete example.
  """

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  alias LLMDB.Model
  alias ReqLLM.{Context, Error, Pricing, PricingContext, Response, TimeoutBudget}
  alias ReqLLM.Provider.{Defaults, Options}
  alias ReqLLM.Providers.OpenAI
  alias ReqLLM.Providers.OpenAI.ResponsesAPI
  alias ReqLLM.Usage.Cost

  @auth_model %Model{provider: :openai, id: "responses"}
  @discounts %{"2h" => 0.7, "8h" => 0.6}
  @windows ["soonest", "2h", "8h"]
  @background_schema NimbleOptions.new!(
                       completion_window: [type: {:in, @windows}, default: "soonest"],
                       continuation_id: [type: :string]
                     )
  @lookup_schema NimbleOptions.new!(
                   completion_window: [type: {:in, @windows}],
                   include: [type: {:list, :string}, default: []]
                 )

  @doc """
  Submits a background response and returns once OpenAI accepts it.

  `:background_options` is a keyword list or atom-keyed map. Its
  `:completion_window` defaults to `"soonest"` and also accepts `"2h"` or `"8h"`.
  The discounted windows use `service_tier: "default"` (Standard). Pass the
  same `:continuation_id` on related submissions to qualify for queue priority.

  The remaining options use the OpenAI generation options, including tools,
  `:previous_response_id`, and `:store`. `:store` defaults to `false` for this
  operation. Submissions use nonstreaming HTTP and are sent once.
  """
  @spec submit(ReqLLM.model_input(), Context.prompt(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def submit(model_spec, prompt, opts \\ []) do
    with :ok <- validate_keyword(opts),
         {background_opts, opts} <- Keyword.pop(opts, :background_options, []),
         {:ok, background_opts} <- validate_options(background_opts, @background_schema),
         :ok <- validate_continuation_id(background_opts[:continuation_id]),
         {:ok, %Model{provider: :openai} = model} <- ReqLLM.model(model_spec),
         opts = ReqLLM.ModelInput.merge_tuple_defaults(model_spec, :chat, opts),
         {:ok, opts} <- Options.process(OpenAI, :chat, model, opts),
         :ok <- validate_submission(opts, background_opts[:completion_window]),
         {:ok, context} <- Context.normalize(prompt, opts),
         :ok <- ReqLLM.ProviderFileReference.validate_context(context, :openai) do
      body = submit_body(model, context, opts, background_opts)

      send_request(:post, ResponsesAPI.path(), model, opts,
        json: body,
        context: context,
        window: background_opts[:completion_window]
      )
    else
      {:ok, %Model{provider: provider}} ->
        {:error,
         Error.Invalid.Provider.exception(
           provider: provider,
           message: "Background Responses requires OpenAI"
         )}

      {:error, _} = error ->
        error
    end
  rescue
    error in [Error.Invalid.Parameter, Jason.EncodeError] -> {:error, error}
  end

  @doc """
  Retrieves the current response by its saved ID.

  Pass the original `:completion_window` for pricing when it is absent from the
  provider response. `:include` accepts OpenAI response fields such as
  `"reasoning.encrypted_content"`. Use the original project's credentials and
  any required project header in `:req_http_options`.
  """
  @spec retrieve(String.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def retrieve(id, opts \\ []), do: lookup(:get, id, opts)

  @doc """
  Requests cancellation by ID and returns OpenAI's response with its status.
  Accepts the same authentication, timeout, and pricing options as `retrieve/2`.
  """
  @spec cancel(String.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def cancel(id, opts \\ []), do: lookup(:post, id, opts)

  defp lookup(method, id, opts) do
    with :ok <- validate_response_id(id),
         :ok <- validate_keyword(opts),
         {lookup_opts, opts} <- Keyword.split(opts, [:completion_window, :include]),
         {:ok, lookup_opts} <- validate_options(lookup_opts, @lookup_schema) do
      case method do
        :get ->
          params = Enum.map(lookup_opts[:include], &{:"include[]", &1})

          send_request(:get, ResponsesAPI.path() <> "/" <> id, @auth_model, opts,
            params: params,
            id: id,
            window: lookup_opts[:completion_window]
          )

        :post ->
          send_request(:post, ResponsesAPI.path() <> "/" <> id <> "/cancel", @auth_model, opts,
            id: id,
            window: lookup_opts[:completion_window]
          )
      end
    end
  end

  defp send_request(method, path, model, opts, settings) do
    with {:ok, http_opts} <- http_options(opts[:req_http_options]) do
      deadline = TimeoutBudget.deadline(opts)
      credential = OpenAI.resolve_request_credential!(model, opts)
      base_url = Options.effective_base_url(OpenAI, model, opts)
      url = String.trim_trailing(base_url, "/") <> path

      timeout =
        opts[:receive_timeout] || http_opts[:receive_timeout] ||
          Application.get_env(:req_llm, :receive_timeout, 30_000)

      request =
        http_opts
        |> Defaults.merge_finch_options(pool_timeout: timeout)
        |> Keyword.merge(OpenAI.auth_req_options(credential))
        |> Keyword.merge(
          method: method,
          url: url,
          receive_timeout: timeout,
          params: settings[:params] || [],
          body: nil,
          into: nil,
          json: settings[:json],
          redirect: false,
          http_errors: :return,
          retry: if(method == :get, do: :safe_transient, else: false)
        )
        |> Keyword.reject(fn {key, value} -> key == :json and is_nil(value) end)
        |> Req.new()
        |> ReqLLM.Auth.validate_request!(credential)
        |> ReqLLM.Step.Error.attach()

      with {:ok, response} <- TimeoutBudget.request(request, deadline) do
        decode_response(request, response, model, settings)
      end
    end
  rescue
    error in Error.Invalid.Parameter -> {:error, error}
  end

  defp submit_body(model, context, opts, background_opts) do
    provider_opts = Keyword.put_new(opts[:provider_options] || [], :store, false)
    opts = Keyword.merge(opts, provider_options: provider_opts, responses_transport: :background)
    window = background_opts[:completion_window]

    body =
      ResponsesAPI.build_request_body(context, model.provider_model_id || model.id, opts, nil)

    background =
      %{"completion_window" => window}
      |> maybe_put("continuation_id", background_opts[:continuation_id])

    body
    |> Map.put("background", true)
    |> Map.put("background_options", background)
    |> Map.put("store", provider_opts[:store])
    |> put_standard_tier(window)
  end

  defp put_standard_tier(body, window) when is_map_key(@discounts, window),
    do: Map.put(body, "service_tier", "default")

  defp put_standard_tier(body, _window), do: body

  defp validate_submission(opts, window) do
    tier = opts[:service_tier] || get_in(opts, [:provider_options, :service_tier])

    cond do
      opts[:stream] ->
        invalid("background responses use nonstreaming HTTP")

      is_map_key(@discounts, window) and tier not in [nil, :default, "default"] ->
        invalid("the #{window} completion window requires service_tier: \"default\"")

      true ->
        :ok
    end
  end

  defp decode_response(request, %Req.Response{status: 200} = response, model, settings) do
    body = ReqLLM.Provider.Utils.ensure_parsed_body(response.body)

    with %{"id" => id, "status" => status, "model" => response_model} <- body,
         true <-
           is_binary(id) and id != "" and is_binary(status) and status != "" and
             is_binary(response_model),
         true <- settings[:id] in [nil, id] do
      model = resolve_response_model(model, response_model)

      request =
        request
        |> Req.Request.register_options([:context])
        |> Req.Request.merge_options(context: settings[:context])
        |> Req.Request.put_private(:req_llm_model, model)

      case ResponsesAPI.decode_response({request, %{response | body: body}}) do
        {_, %Req.Response{body: %Response{} = decoded}} ->
          {:ok, enrich_response(decoded, body, model, request.url, settings[:window])}

        {_, error} ->
          {:error, error}
      end
    else
      _ ->
        {:error,
         Error.API.Response.exception(
           reason: "unexpected OpenAI background response",
           status: 200,
           response_body: body
         )}
    end
  end

  defp decode_response(request, response, _model, _settings) do
    {_, error} = ReqLLM.Step.Error.handle({request, response})
    {:error, error}
  end

  defp resolve_response_model(@auth_model, id) do
    case LLMDB.model(:openai, id) do
      {:ok, model} -> model
      {:error, _} -> %Model{provider: :openai, id: id}
    end
  end

  defp resolve_response_model(model, _id), do: model

  defp enrich_response(response, body, model, url, requested_window) do
    window = returned_window(body, requested_window)

    meta =
      response.provider_meta
      |> Map.put("output", body["output"] || [])
      |> maybe_put("usage", body["usage"])
      |> maybe_put("completion_window", window)

    usage = if is_map(body["usage"]), do: price_usage(response.usage, model, url, meta, window)

    %{
      response
      | provider_meta: meta,
        error: body["error"],
        finish_reason: finish_reason(body["status"], response.finish_reason),
        usage: usage
    }
  end

  defp finish_reason(status, _reason) when status in ["queued", "in_progress"], do: nil
  defp finish_reason("failed", _reason), do: :error
  defp finish_reason("cancelled", _reason), do: :cancelled
  defp finish_reason(status, reason) when status in ["completed", "incomplete"], do: reason
  defp finish_reason(_status, _reason), do: :unknown

  defp returned_window(%{"background_options" => %{"completion_window" => window}}, _requested)
       when window in @windows, do: window

  defp returned_window(_body, requested), do: requested

  defp price_usage(usage, model, url, meta, window) when is_map(usage) do
    pricing_context = PricingContext.from_openai(url, meta, %{completion_window: window})

    case {window, pricing_context} do
      {"soonest", _context} ->
        Cost.apply(usage, model, pricing_context: pricing_context)

      {window, %{api: "responses", service_tier: "default", regional_processing: _}}
      when is_map_key(@discounts, window) ->
        model = with_window_discount(model, window)
        Cost.apply(usage, model, pricing_context: pricing_context)

      _ ->
        Cost.merge(usage, nil)
    end
  end

  defp with_window_discount(model, window) do
    discount = %{
      id: "pricing.background.#{window}",
      applies_to: ["token.*"],
      multiplier: Map.fetch!(@discounts, window)
    }

    components = Pricing.components(model)
    pricing = model.pricing || %{}
    %{model | pricing: Map.put(pricing, :components, [discount | components])}
  end

  defp validate_response_id(id) when is_binary(id) do
    if id =~ ~r/\A[A-Za-z0-9_-]+\z/, do: :ok, else: invalid("invalid OpenAI response ID")
  end

  defp validate_response_id(_id), do: invalid("invalid OpenAI response ID")

  defp validate_continuation_id(nil), do: :ok
  defp validate_continuation_id(""), do: invalid("background continuation_id must be nonempty")
  defp validate_continuation_id(_id), do: :ok

  defp validate_options(opts, schema) when is_map(opts),
    do: validate_options(Map.to_list(opts), schema)

  defp validate_options(opts, schema) do
    with :ok <- validate_keyword(opts),
         {:ok, opts} <- NimbleOptions.validate(opts, schema) do
      {:ok, opts}
    else
      {:error, %NimbleOptions.ValidationError{} = error} -> invalid(Exception.message(error))
      {:error, _} = error -> error
    end
  end

  defp validate_keyword(opts) do
    if Keyword.keyword?(opts), do: :ok, else: invalid("expected a keyword list of options")
  end

  defp http_options(nil), do: {:ok, []}
  defp http_options(opts) when is_map(opts), do: http_options(Map.to_list(opts))

  defp http_options(opts) do
    with :ok <- validate_keyword(opts), do: {:ok, opts}
  end

  defp invalid(reason), do: {:error, Error.Invalid.Parameter.exception(parameter: reason)}
end

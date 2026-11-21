defmodule ReqLLM.Providers.Google.InteractionsAPI do
  @moduledoc """
  Google Gemini Interactions API driver (`/{api_version}/interactions`).

  Supports the GA `steps` wire schema (`Api-Revision: 2026-05-20`) across
  buffered generation, structured JSON outputs (`TextResponseFormat`), stateful
  multi-turn chaining (`previous_interaction_id`), stateless `StepList` replay,
  stateful SSE streaming (`step.start`, `step.delta`, `step.stop`), server-side
  built-in tools, `:provider_block` opaque replay, and background / Managed Agent
  lifecycle operations (`get/2`, `cancel/2`, `delete/2`, `wait/2`, `stream/2`).
  """

  alias ReqLLM.Context
  alias ReqLLM.Error.API.Request, as: RequestError
  alias ReqLLM.Error.API.Response, as: ResponseError
  alias ReqLLM.Error.API.Timeout, as: TimeoutError
  alias ReqLLM.Error.Invalid.Parameter
  alias ReqLLM.Message
  alias ReqLLM.Provider.Defaults
  alias ReqLLM.Provider.Utils
  alias ReqLLM.Providers.Google
  alias ReqLLM.Providers.Google.InteractionsAPI.Decoder
  alias ReqLLM.Providers.Google.InteractionsAPI.Encoder
  alias ReqLLM.Providers.Google.InteractionsAPI.FallbackCoordinator
  alias ReqLLM.Providers.Google.InteractionsAPI.Helpers
  alias ReqLLM.Providers.Google.InteractionsAPI.StepHistory
  alias ReqLLM.Providers.Google.InteractionsAPI.Stream
  alias ReqLLM.StreamChunk
  alias ReqLLM.Streaming
  alias ReqLLM.TimeoutBudget

  @default_receive_timeout 120_000
  @default_poll_interval 5_000
  @default_wait_timeout 600_000
  @default_max_transient_retries 3

  @interactions_only_keys [
    :agent,
    :agent_config,
    :environment,
    :previous_interaction_id,
    :background,
    :interactions_resume_id,
    :last_event_id,
    :continuation_token,
    :store,
    :service_tier,
    :google_file_search,
    :google_mcp_servers,
    :google_code_execution,
    :google_search_types,
    :labels
  ]

  @polling_statuses ~w(in_progress queued)
  @transient_http_statuses [408, 429, 500, 502, 503, 504]

  @doc false
  @spec api_revision() :: String.t()
  defdelegate api_revision, to: Helpers

  @doc false
  @spec interactions_metadata_key() :: String.t()
  defdelegate interactions_metadata_key, to: Helpers

  @doc false
  @spec redact_api_key(String.t()) :: String.t()
  defdelegate redact_api_key(text), to: Helpers

  @doc false
  @spec resolve_mode(keyword() | map()) ::
          {:ok, :interactions | :generate_content} | {:error, Exception.t()}
  def resolve_mode(opts) do
    google_api = Helpers.get_opt(opts, :google_api)

    present_interactions_keys =
      Enum.filter(@interactions_only_keys, &(Helpers.get_opt(opts, &1) != nil))

    has_interactions_only? = present_interactions_keys != []

    case normalize_google_api(google_api) do
      :interactions ->
        {:ok, :interactions}

      :generate_content when has_interactions_only? ->
        keys_str = Enum.map_join(present_interactions_keys, ", ", &inspect/1)

        {:error,
         Parameter.exception(
           parameter:
             "google_api: :generate_content cannot be combined with Interactions-only options (#{keys_str})"
         )}

      :generate_content ->
        {:ok, :generate_content}

      nil when has_interactions_only? ->
        {:ok, :interactions}

      nil ->
        {:ok, :generate_content}

      other ->
        {:error, Parameter.exception(parameter: "invalid google_api: #{inspect(other)}")}
    end
  end

  @doc false
  @spec interactions_mode?(keyword() | map()) :: boolean()
  def interactions_mode?(opts) do
    match?({:ok, :interactions}, resolve_mode(opts))
  end

  @doc false
  @spec validate_options(keyword() | map()) :: :ok | {:error, Exception.t()}
  def validate_options(opts) do
    with {:ok, mode} <- resolve_mode(opts),
         :ok <- validate_store_compat(opts),
         :ok <- validate_target_compat(opts),
         :ok <- validate_generate_content_response_format(opts) do
      validate_thinking_compat(mode, opts)
    end
  end

  @doc false
  @spec explicit_option?(keyword() | map(), atom()) :: boolean()
  defdelegate explicit_option?(opts, key), to: Helpers

  @doc false
  @spec drop_default_include_thoughts(keyword(), boolean()) :: keyword()
  def drop_default_include_thoughts(opts, true), do: opts

  def drop_default_include_thoughts(opts, false) do
    opts
    |> Keyword.delete(:google_include_thoughts)
    |> Helpers.update_provider_options_if_present(
      &Helpers.delete_option(&1, :google_include_thoughts)
    )
  end

  @doc false
  @spec resolve_api_version(keyword() | map()) :: String.t()
  defdelegate resolve_api_version(opts), to: Helpers

  @doc false
  @spec effective_base_url(keyword() | map()) :: String.t()
  defdelegate effective_base_url(opts), to: Helpers

  @doc false
  @spec prepare_request(atom(), LLMDB.Model.t(), Context.t(), keyword(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, Exception.t()}
  def prepare_request(
        operation,
        %LLMDB.Model{} = model,
        %Context{} = context,
        raw_opts,
        processed_opts
      ) do
    resume_id = Helpers.get_opt(processed_opts, :interactions_resume_id)
    resuming? = Helpers.non_empty_binary?(resume_id)

    with :ok <- validate_options(processed_opts),
         :ok <-
           if(resuming?,
             do: :ok,
             else: validate_no_prefill_for_request(model, context, processed_opts)
           ),
         :ok <-
           if(resuming?,
             do: :ok,
             else: ReqLLM.ProviderFileReference.validate_context(context, :google)
           ) do
      explicit_thoughts? = Helpers.explicit_option?(raw_opts, :google_include_thoughts)
      cleaned_opts = drop_default_include_thoughts(processed_opts, explicit_thoughts?)
      effective_url = Helpers.effective_base_url(raw_opts, cleaned_opts)
      final_opts = Keyword.put(cleaned_opts, :base_url, effective_url)

      final_opts =
        if(resuming?, do: Keyword.put(final_opts, :stream, true), else: final_opts)

      http_opts = Keyword.get(final_opts, :req_http_options, [])

      req_keys =
        Google.supported_provider_options() ++
          [
            :context,
            :operation,
            :compiled_schema,
            :text,
            :stream,
            :model,
            :provider_options,
            :tools,
            :tool_choice,
            :response_format,
            :temperature,
            :max_tokens,
            :top_p,
            :top_k,
            :seed,
            :stop,
            :reasoning_effort,
            :reasoning_token_budget,
            :system_prompt,
            :interactions_resume_id,
            :google_api_type
          ]

      timeout =
        Keyword.get(
          final_opts,
          :receive_timeout,
          Application.get_env(:req_llm, :receive_timeout, @default_receive_timeout)
        )

      method = if(resuming?, do: :get, else: :post)

      path =
        if(resuming?,
          do: "/interactions/#{Helpers.encode_path_segment(resume_id)}",
          else: "/interactions"
        )

      headers =
        if resuming? or Keyword.get(final_opts, :stream) == true do
          [{"api-revision", Helpers.api_revision()}, {"accept", "text/event-stream"}]
        else
          [{"api-revision", Helpers.api_revision()}]
        end

      request =
        Req.new(
          [
            url: path,
            method: method,
            params: [],
            receive_timeout: timeout
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(final_opts, req_keys) ++
            [
              operation: operation,
              model: model.id,
              base_url: effective_url,
              google_api_type: :interactions
            ] ++ if(resuming?, do: [stream: true], else: [])
        )
        |> Req.Request.put_headers(headers)
        |> Google.attach(model, final_opts)

      request =
        if resuming? do
          resume_params = Stream.resume_query_params(final_opts)
          existing_params = request.options[:params] || []
          Req.Request.merge_options(request, params: resume_params ++ existing_params)
        else
          request
        end

      {:ok, request}
    end
  end

  @doc false
  @spec encode_body(Req.Request.t()) :: Req.Request.t()
  def encode_body(%Req.Request{} = request) do
    resume_id = Helpers.get_opt(request.options, :interactions_resume_id)

    if Helpers.non_empty_binary?(resume_id) or
         (request.method == :get and is_nil(request.options[:context])) do
      request
    else
      opts = Enum.to_list(request.options)

      case validate_options(opts) do
        :ok -> :ok
        {:error, error} -> raise error
      end

      model = request.private[:req_llm_model] || request.options[:model]
      operation = request.options[:operation] || :chat
      Google.validate_interactions_gemini_options!(operation, model, opts)
      context = request.options[:context] || %Context{messages: []}
      body = Encoder.build_request_body(model, context, opts)
      put_in(request, [Access.key!(:options), :json], body)
    end
  end

  @doc false
  @spec build_request_body(LLMDB.Model.t() | String.t() | nil, Context.t(), keyword()) :: map()
  defdelegate build_request_body(model_or_id, context, opts), to: Encoder

  @doc false
  @spec decode_response({Req.Request.t(), Req.Response.t()}) ::
          {Req.Request.t(), Req.Response.t() | Exception.t()}
  def decode_response({req, %Req.Response{status: status} = resp}) when status in 200..299 do
    if req.options[:stream] == true do
      Defaults.default_decode_response({req, resp})
    else
      case Utils.ensure_parsed_body(resp.body) do
        %{} = body ->
          model = resolve_response_model(req, body)
          context = req.options[:context] || %Context{messages: []}
          background? = Helpers.truthy_opt?(req.options, :background)

          if body["status"] == "failed" and not background? do
            err =
              ResponseError.exception(
                reason: Decoder.extract_failure_reason(body),
                status: status,
                response_body: body
              )

            {req, err}
          else
            case Decoder.decode_interaction_body(body, model, context, Enum.to_list(req.options)) do
              {:ok, decoded} ->
                {req, %{resp | body: decoded}}

              {:error, reason} ->
                err =
                  ResponseError.exception(
                    reason: "Failed to decode Google Interactions response: #{inspect(reason)}",
                    status: status,
                    response_body: body
                  )

                {req, err}
            end
          end

        other ->
          err =
            ResponseError.exception(
              reason: "Unexpected non-JSON-object response from Google Interactions API",
              status: status,
              response_body: other
            )

          {req, err}
      end
    end
  end

  def decode_response({req, %Req.Response{status: status} = resp}) do
    body = Utils.ensure_parsed_body(resp.body)

    err =
      ResponseError.exception(
        reason: Decoder.extract_http_error_reason(body, "Google Interactions API error"),
        status: status,
        response_body: body
      )

    {req, err}
  end

  @doc false
  @spec decode_interaction_body(map(), LLMDB.Model.t(), Context.t(), keyword()) ::
          {:ok, ReqLLM.Response.t()} | {:error, term()}
  def decode_interaction_body(body, model, context, opts \\ []) do
    Decoder.decode_interaction_body(body, model, context, opts)
  end

  @doc false
  @spec interactions_usage_body?(map()) :: boolean()
  defdelegate interactions_usage_body?(body), to: Decoder

  @doc false
  @spec extract_usage(map() | ReqLLM.Response.t(), LLMDB.Model.t() | nil) ::
          {:ok, map()} | {:error, atom()}
  defdelegate extract_usage(body, model), to: Decoder

  @doc false
  @spec attach_stream(LLMDB.Model.t(), Context.t(), keyword(), atom()) ::
          {:ok, Finch.Request.t()} | {:error, Exception.t()}
  defdelegate attach_stream(model, context, opts, finch_name), to: Stream

  @doc false
  @spec stream_event?(term()) :: boolean()
  defdelegate stream_event?(event), to: Stream

  @doc false
  @spec init_stream_state(LLMDB.Model.t() | nil, keyword()) :: map()
  def init_stream_state(model \\ nil, opts \\ []), do: Stream.init_stream_state(model, opts)

  @doc false
  @spec decode_stream_event(map(), LLMDB.Model.t(), map() | nil) :: {[StreamChunk.t()], map()}
  defdelegate decode_stream_event(event, model, state), to: Stream

  @doc false
  @spec flush_stream_state(LLMDB.Model.t(), map() | nil) :: {[StreamChunk.t()], map()}
  defdelegate flush_stream_state(model, state), to: Stream

  @doc false
  @spec decode_stateless_stream_event(map(), LLMDB.Model.t() | nil) :: [StreamChunk.t()]
  defdelegate decode_stateless_stream_event(event, model), to: Stream

  @doc false
  @spec preserve_interactions_steps(ReqLLM.Response.t(), [map()]) :: ReqLLM.Response.t()
  defdelegate preserve_interactions_steps(response, steps), to: StepHistory

  @doc false
  @spec verified_interactions_steps(Message.t() | map()) :: [map()] | nil
  defdelegate verified_interactions_steps(message), to: StepHistory

  @doc """
  Retrieves an existing Interaction by ID (`GET /{api_version}/interactions/{id}`).

  Failed interactions decode as `{:ok, %ReqLLM.Response{finish_reason: :error, error: %ReqLLM.Error.API.Response{}}}`.
  """
  @spec get(String.t() | ReqLLM.Response.t(), keyword()) ::
          {:ok, ReqLLM.Response.t()} | {:error, Exception.t()}
  def get(interaction_or_resp, opts \\ [])

  def get(%ReqLLM.Response{id: id} = resp, opts) when is_list(opts) do
    get(id || "", lifecycle_opts_for_response(resp, opts))
  end

  def get(interaction_id, opts) when is_binary(interaction_id) and is_list(opts) do
    with :ok <- validate_non_empty_interaction_id(interaction_id),
         {:ok, model} <- resolve_lifecycle_model(opts),
         path = "/interactions/#{Helpers.encode_path_segment(interaction_id)}",
         {:ok, %Req.Response{status: status, body: body}} when status in 200..299 <-
           execute_lifecycle_request(:get, path, model, opts, interaction_id, :interactions_get) do
      case Utils.ensure_parsed_body(body) do
        %{} = parsed ->
          context = Keyword.get(opts, :context) || %Context{messages: []}
          effective_model = resolve_lifecycle_model_from_body(opts, parsed, model)
          Decoder.decode_interaction_body(parsed, effective_model, context, opts)

        other ->
          {:error,
           ResponseError.exception(
             reason: "Unexpected non-JSON-object response from Google Interactions API",
             status: status,
             response_body: other
           )}
      end
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        parsed = Utils.ensure_parsed_body(body)

        {:error,
         ResponseError.exception(
           reason: Decoder.extract_http_error_reason(parsed, "Failed to retrieve interaction"),
           status: status,
           response_body: parsed
         )}

      {:error, reason} ->
        {:error, sanitize_lifecycle_error("Failed to retrieve interaction", reason)}
    end
  end

  @doc """
  Cancels an in-progress Interaction (`POST /{api_version}/interactions/{id}/cancel`).
  """
  @spec cancel(String.t() | ReqLLM.Response.t(), keyword()) ::
          {:ok, ReqLLM.Response.t()} | {:error, Exception.t()}
  def cancel(interaction_or_resp, opts \\ [])

  def cancel(%ReqLLM.Response{id: id} = resp, opts) when is_list(opts) do
    cancel(id || "", lifecycle_opts_for_response(resp, opts))
  end

  def cancel(interaction_id, opts) when is_binary(interaction_id) and is_list(opts) do
    with :ok <- validate_non_empty_interaction_id(interaction_id),
         {:ok, model} <- resolve_lifecycle_model(opts),
         path = "/interactions/#{Helpers.encode_path_segment(interaction_id)}/cancel",
         {:ok, %Req.Response{status: status, body: body}} when status in 200..299 <-
           execute_lifecycle_request(
             :post,
             path,
             model,
             opts,
             interaction_id,
             :interactions_cancel
           ) do
      case Utils.ensure_parsed_body(body) do
        %{} = parsed ->
          context = Keyword.get(opts, :context) || %Context{messages: []}
          effective_model = resolve_lifecycle_model_from_body(opts, parsed, model)
          Decoder.decode_interaction_body(parsed, effective_model, context, opts)

        other ->
          {:error,
           ResponseError.exception(
             reason: "Unexpected non-JSON-object response from Google Interactions API",
             status: status,
             response_body: other
           )}
      end
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        parsed = Utils.ensure_parsed_body(body)

        {:error,
         ResponseError.exception(
           reason: Decoder.extract_http_error_reason(parsed, "Failed to cancel interaction"),
           status: status,
           response_body: parsed
         )}

      {:error, reason} ->
        {:error, sanitize_lifecycle_error("Failed to cancel interaction", reason)}
    end
  end

  @doc """
  Deletes a stored Interaction (`DELETE /{api_version}/interactions/{id}`).
  """
  @spec delete(String.t() | ReqLLM.Response.t(), keyword()) :: :ok | {:error, Exception.t()}
  def delete(interaction_or_resp, opts \\ [])

  def delete(%ReqLLM.Response{id: id} = resp, opts) when is_list(opts) do
    delete(id || "", lifecycle_opts_for_response(resp, opts))
  end

  def delete(interaction_id, opts) when is_binary(interaction_id) and is_list(opts) do
    with :ok <- validate_non_empty_interaction_id(interaction_id),
         {:ok, model} <- resolve_lifecycle_model(opts),
         path = "/interactions/#{Helpers.encode_path_segment(interaction_id)}",
         {:ok, %Req.Response{status: status}} when status in 200..299 <-
           execute_lifecycle_request(
             :delete,
             path,
             model,
             opts,
             interaction_id,
             :interactions_delete
           ) do
      :ok
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        parsed = Utils.ensure_parsed_body(body)

        {:error,
         ResponseError.exception(
           reason: Decoder.extract_http_error_reason(parsed, "Failed to delete interaction"),
           status: status,
           response_body: parsed
         )}

      {:error, reason} ->
        {:error, sanitize_lifecycle_error("Failed to delete interaction", reason)}
    end
  end

  @doc """
  Polls `get/2` until an Interaction reaches a non-polling status.

  Returns `{:error, %ReqLLM.Error.API.Response{}}` if the interaction reaches `"failed"`.

  Options:
    * `:poll_interval` - Positive integer milliseconds between polls (default `5_000`)
    * `:timeout` - Total wait timeout in milliseconds (default `600_000`)
    * `:max_transient_retries` - Transient error retries (default `3`)
  """
  @spec wait(String.t() | ReqLLM.Response.t(), keyword()) ::
          {:ok, ReqLLM.Response.t()} | {:error, Exception.t()}
  def wait(interaction_or_resp, opts \\ [])

  def wait(%ReqLLM.Response{id: id} = resp, opts) when is_list(opts) do
    wait(id || "", lifecycle_opts_for_response(resp, opts))
  end

  def wait(interaction_id, opts) when is_binary(interaction_id) and is_list(opts) do
    poll_interval = Keyword.get(opts, :poll_interval, @default_poll_interval)
    wait_timeout = Keyword.get(opts, :timeout, @default_wait_timeout)
    retries = Keyword.get(opts, :max_transient_retries, @default_max_transient_retries)

    with :ok <- validate_non_empty_interaction_id(interaction_id),
         :ok <- validate_wait_options(poll_interval, wait_timeout, retries) do
      get_opts =
        opts
        |> Keyword.drop([:poll_interval, :timeout, :max_transient_retries])
        |> Keyword.update(:req_http_options, [retry: false], &Keyword.put_new(&1, :retry, false))

      deadline = TimeoutBudget.deadline(total_timeout: wait_timeout)

      do_wait(interaction_id, get_opts, poll_interval, deadline, retries, retries)
    end
  end

  defp validate_wait_options(poll_interval, wait_timeout, retries) do
    cond do
      not (is_integer(poll_interval) and poll_interval > 0) ->
        {:error, Parameter.exception(parameter: "poll_interval must be a positive integer")}

      not (is_integer(wait_timeout) and wait_timeout >= 0) ->
        {:error, Parameter.exception(parameter: "timeout must be a non-negative integer")}

      not (is_integer(retries) and retries >= 0) ->
        {:error,
         Parameter.exception(parameter: "max_transient_retries must be a non-negative integer")}

      true ->
        :ok
    end
  end

  @doc """
  Resumes or attaches to an Interaction SSE stream via `GET /{api_version}/interactions/{id}?stream=true`.

  Supports `:last_event_id` to resume from a specific SSE event ID.
  """
  @spec stream(String.t() | ReqLLM.Response.t(), keyword()) ::
          {:ok, ReqLLM.StreamResponse.t()} | {:error, term()}
  def stream(interaction_or_resp, opts \\ [])

  def stream(%ReqLLM.Response{id: id} = resp, opts) when is_list(opts) do
    stream(id || "", lifecycle_opts_for_response(resp, opts))
  end

  def stream(interaction_id, opts) when is_binary(interaction_id) and is_list(opts) do
    if Helpers.non_empty_binary?(interaction_id) do
      with {:ok, model} <- resolve_lifecycle_model(opts) do
        context = Keyword.get(opts, :context) || %Context{messages: []}

        stream_opts =
          opts
          |> Keyword.drop([:model, :context])
          |> Keyword.put(:interactions_resume_id, interaction_id)
          |> Keyword.put(:google_api, :interactions)

        with {:ok, %ReqLLM.StreamResponse{} = primary} <-
               Streaming.start_stream(Google, model, context, stream_opts) do
          if v1beta_stream_fallback_eligible?(interaction_id, stream_opts) do
            fallback_opts = build_v1beta_fallback_opts(stream_opts)
            {:ok, wrap_stream_with_v1beta_fallback(primary, model, context, fallback_opts)}
          else
            {:ok, primary}
          end
        end
      end
    else
      {:error, Parameter.exception(parameter: "interaction_id must be a non-empty string")}
    end
  end

  defp v1beta_stream_fallback_eligible?(interaction_id, opts) do
    effective_url = Helpers.effective_base_url(opts)

    is_nil(Helpers.get_opt(opts, :google_api_version)) and
      not Helpers.non_empty_binary?(Helpers.get_opt(opts, :agent)) and
      not String.starts_with?(interaction_id, "v1beta_") and
      (effective_url == "#{Helpers.ai_studio_host()}/v1" or
         String.ends_with?(effective_url, "/v1"))
  end

  defp build_v1beta_fallback_opts(opts) do
    effective_url = Helpers.effective_base_url(opts)

    opts = Keyword.put(opts, :google_api_version, "v1beta")

    if Helpers.get_opt(opts, :base_url) != nil and String.ends_with?(effective_url, "/v1") do
      Keyword.put(opts, :base_url, String.replace_suffix(effective_url, "/v1", "/v1beta"))
    else
      opts
    end
  end

  @doc false
  def wrap_stream_with_v1beta_fallback(primary, model, context, fallback_opts) do
    {:ok, coordinator} =
      FallbackCoordinator.start_link(self(), fn ->
        Streaming.start_stream(Google, model, context, fallback_opts)
      end)

    start_fallback_once = fn -> FallbackCoordinator.start_fallback(coordinator) end

    wrapped_stream =
      Elixir.Stream.resource(
        fn -> {:primary, stream_stepper(primary.stream), :atomics.new(1, [])} end,
        fn
          {:primary, stepper, unwound} ->
            step_primary_stream(
              stepper,
              unwound,
              coordinator,
              primary.metadata_handle,
              start_fallback_once
            )

          {:streaming, stepper, unwound} ->
            step_next_stream(stepper, unwound)

          :done ->
            {:halt, :done}
        end,
        fn
          {:streaming, stepper, unwound} ->
            halt_stream_and_finish(stepper, unwound, coordinator, primary)

          _ ->
            finish_coordinator_consumer(coordinator, primary, :stream)
        end
      )

    {:ok, metadata_handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        collect_wrapped_metadata(coordinator, primary, start_fallback_once)
      end)

    cancel_fn = fn ->
      cancel_wrapped_stream(metadata_handle, primary, coordinator)
    end

    %{
      primary
      | stream: wrapped_stream,
        metadata_handle: metadata_handle,
        cancel: cancel_fn
    }
  end

  defp step_primary_stream(
         stepper,
         unwound,
         coordinator,
         primary_metadata_handle,
         start_fallback_once
       ) do
    stepper.({:cont, nil})
  rescue
    error ->
      if http_404_error?(error) do
        step_fallback_stream(start_fallback_once)
      else
        reraise error, __STACKTRACE__
      end
  else
    {:suspended, elem, next_stepper} ->
      {[elem], {:streaming, next_stepper, unwound}}

    {_done_or_halted, _acc} ->
      if primary_stream_404?(coordinator, primary_metadata_handle) do
        step_fallback_stream(start_fallback_once)
      else
        {:halt, :done}
      end
  end

  defp halt_stream_and_finish(stepper, unwound, coordinator, primary) do
    if :atomics.exchange(unwound, 1, 1) == 0 do
      stepper.({:halt, nil})
    end

    :ok
  after
    finish_coordinator_consumer(coordinator, primary, :stream)
  end

  defp collect_wrapped_metadata(coordinator, primary, start_fallback_once) do
    primary_meta = safe_await_metadata(primary.metadata_handle)
    not_found? = http_404_metadata?(primary_meta)

    FallbackCoordinator.set_primary_404(coordinator, not_found?)

    if not_found? do
      case start_fallback_once.() do
        {:ok, %ReqLLM.StreamResponse{} = fallback} ->
          safe_await_metadata(fallback.metadata_handle)

        {:error, reason} ->
          %{error: reason}
      end
    else
      primary_meta
    end
  after
    finish_coordinator_consumer(coordinator, primary, :meta)
  end

  defp cancel_wrapped_stream(metadata_handle, primary, coordinator) do
    FallbackCoordinator.safe_stop_metadata_handle(metadata_handle)
    FallbackCoordinator.safe_cancel_stream(primary)
    FallbackCoordinator.safe_stop_metadata_handle(primary.metadata_handle)

    case FallbackCoordinator.cancel(coordinator) do
      {:ok, %ReqLLM.StreamResponse{} = fallback} ->
        FallbackCoordinator.cleanup_fallback(fallback)

      :none ->
        :ok
    end

    :ok
  end

  defp primary_stream_404?(coordinator, primary_metadata_handle) do
    case FallbackCoordinator.primary_404(coordinator) do
      {:known, not_found?} ->
        not_found?

      :stopped ->
        false

      :unknown ->
        primary_meta = safe_await_metadata(primary_metadata_handle)
        http_404_metadata?(primary_meta)
    end
  end

  defp finish_coordinator_consumer(coordinator, primary, consumer) do
    case FallbackCoordinator.finish_consumer(coordinator, consumer) do
      {:cleanup, fallback} ->
        FallbackCoordinator.safe_stop_metadata_handle(primary.metadata_handle)
        FallbackCoordinator.cleanup_fallback(fallback)

      :keep ->
        :ok
    end
  end

  defp safe_await_metadata(handle) when is_pid(handle) do
    ReqLLM.StreamResponse.MetadataHandle.await(handle)
  catch
    :exit, _ -> %{error: :cancelled}
  end

  defp stream_stepper(stream) do
    fn acc -> Enumerable.reduce(stream, acc, fn elem, _acc -> {:suspend, elem} end) end
  end

  defp step_fallback_stream(start_fallback_once) do
    case start_fallback_once.() do
      {:ok, %ReqLLM.StreamResponse{} = fallback} ->
        step_next_stream(stream_stepper(fallback.stream), :atomics.new(1, []))

      {:error, _reason} ->
        {:halt, :done}
    end
  end

  defp step_next_stream(stepper, unwound) do
    case stepper.({:cont, nil}) do
      {:suspended, elem, next_stepper} -> {[elem], {:streaming, next_stepper, unwound}}
      {_done_or_halted, _acc} -> {:halt, :done}
    end
  catch
    kind, reason ->
      :atomics.put(unwound, 1, 1)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp http_404_metadata?(%{error: error}), do: http_404_error?(error)
  defp http_404_metadata?(_), do: false

  defp http_404_error?(%ReqLLM.Error.API.Request{status: 404}), do: true
  defp http_404_error?(%ResponseError{status: 404}), do: true
  defp http_404_error?(%{cause: cause}) when not is_nil(cause), do: http_404_error?(cause)

  defp http_404_error?(error) do
    match?({:api, 404, _, _}, ReqLLM.Streaming.Failure.classify(error))
  end

  @doc false
  def validate_no_prefill_for_request(model, context, opts) do
    prev_id = Helpers.get_opt(opts, :previous_interaction_id)

    if Helpers.non_empty_binary?(prev_id) do
      {_system_instruction, chat_messages} = Encoder.split_system_messages(context.messages, opts)
      delta = StepHistory.select_stateful_delta(chat_messages, prev_id)

      if delta == [] or match?(%Message{role: :assistant}, List.last(delta)) do
        {:error,
         Parameter.exception(
           parameter: "previous_interaction_id requires a follow-up user message or tool result"
         )}
      else
        Google.validate_no_prefill(model, %Context{messages: delta})
      end
    else
      Google.validate_no_prefill(model, context)
    end
  end

  defp do_wait(interaction_id, get_opts, poll_interval, deadline, retries_left, max_retries) do
    remaining = TimeoutBudget.remaining(deadline)

    if remaining == 0 do
      {:error, TimeoutError.exception(kind: :total, timeout: deadline.timeout)}
    else
      configured_timeout =
        Keyword.get(get_opts, :receive_timeout) ||
          get_in(get_opts, [:req_http_options, :receive_timeout]) ||
          @default_receive_timeout

      poll_opts = Keyword.put(get_opts, :receive_timeout, min(configured_timeout, remaining))

      case get(interaction_id, poll_opts) do
        {:ok, %ReqLLM.Response{} = response} ->
          status = response.provider_meta["interaction_status"]

          cond do
            status in @polling_statuses ->
              continue_wait(
                interaction_id,
                get_opts,
                poll_interval,
                deadline,
                max_retries,
                max_retries
              )

            status == "failed" ->
              {:error,
               response.error || ResponseError.exception(reason: "Google Interaction failed")}

            true ->
              {:ok, response}
          end

        {:error, error} ->
          if retries_left > 0 and transient_error?(error) do
            continue_wait(
              interaction_id,
              get_opts,
              poll_interval,
              deadline,
              retries_left - 1,
              max_retries
            )
          else
            {:error, error}
          end
      end
    end
  end

  defp continue_wait(interaction_id, get_opts, poll_interval, deadline, retries_left, max_retries) do
    remaining = TimeoutBudget.remaining(deadline)

    if remaining == 0 do
      {:error, TimeoutError.exception(kind: :total, timeout: deadline.timeout)}
    else
      Process.sleep(min(poll_interval, remaining))
      do_wait(interaction_id, get_opts, poll_interval, deadline, retries_left, max_retries)
    end
  end

  defp transient_error?(%ResponseError{status: status}) when status in @transient_http_statuses,
    do: true

  defp transient_error?(%RequestError{status: status}) when status in @transient_http_statuses,
    do: true

  defp transient_error?(%RequestError{status: nil}), do: true
  defp transient_error?(%Req.TransportError{}), do: true
  defp transient_error?(%Mint.TransportError{}), do: true
  defp transient_error?(%Finch.TransportError{}), do: true

  defp transient_error?(error) do
    case ReqLLM.Streaming.Failure.classify(error) do
      {:transport, _, true} -> true
      {:api, status, _, _} when status in @transient_http_statuses -> true
      _ -> false
    end
  end

  defp execute_lifecycle_request(
         method,
         path,
         model,
         opts,
         interaction_id,
         lifecycle_operation
       ) do
    request_opts = Keyword.put_new(opts, :interaction_id, interaction_id)

    with {:ok, request} <-
           build_lifecycle_request(method, path, model, request_opts, lifecycle_operation),
         {:ok, %Req.Response{status: 404}} = resp <- Req.request(request) do
      if v1beta_fallback_eligible?(request_opts, request) do
        v1beta_opts = build_v1beta_fallback_opts(request_opts)

        with {:ok, retry_req} <-
               build_lifecycle_request(method, path, model, v1beta_opts, lifecycle_operation) do
          Req.request(retry_req)
        end
      else
        resp
      end
    end
  end

  defp v1beta_fallback_eligible?(opts, request) do
    base_url = request.options[:base_url]

    is_nil(Helpers.get_opt(opts, :google_api_version)) and
      not Helpers.non_empty_binary?(Helpers.get_opt(opts, :agent)) and
      is_binary(base_url) and
      (base_url == "#{Helpers.ai_studio_host()}/v1" or String.ends_with?(base_url, "/v1"))
  end

  defp validate_non_empty_interaction_id(interaction_id) do
    if Helpers.non_empty_binary?(interaction_id) do
      :ok
    else
      {:error, Parameter.exception(parameter: "interaction_id must be a non-empty string")}
    end
  end

  defp lifecycle_opts_for_response(%ReqLLM.Response{provider_meta: meta} = resp, opts) do
    opts =
      if is_binary(resp.model) and resp.model != "" do
        Keyword.put_new(opts, :model, resp.model)
      else
        opts
      end

    agent = if is_map(meta), do: meta["agent"] || meta[:agent], else: nil

    if is_binary(agent) and agent != "" do
      Keyword.put_new(opts, :agent, agent)
    else
      opts
    end
  end

  defp build_lifecycle_request(method, path, model, opts, lifecycle_operation) do
    case ReqLLM.Keys.get(model, opts) do
      {:ok, api_key, _source} ->
        base_url = Helpers.effective_base_url(opts)
        http_opts = Keyword.get(opts, :req_http_options, [])
        use_header_auth? = Helpers.use_header_auth?(opts)

        receive_timeout =
          Keyword.get(opts, :receive_timeout) ||
            Keyword.get(http_opts, :receive_timeout) ||
            @default_receive_timeout

        merged_http_opts = Defaults.merge_finch_options(http_opts, pool_timeout: receive_timeout)

        base_headers =
          [{"api-revision", Helpers.api_revision()}, {"accept", "application/json"}] ++
            if(use_header_auth?, do: [{"x-goog-api-key", api_key}], else: [])

        auth_params = if(use_header_auth?, do: [], else: [key: api_key])
        custom_headers = normalize_http_headers(Keyword.get(merged_http_opts, :headers, []))
        custom_params = merged_http_opts |> Keyword.get(:params, []) |> Enum.to_list()

        merged_params =
          if auth_params == [] do
            custom_params
          else
            Enum.reject(custom_params, fn {k, _v} -> to_string(k) == "key" end) ++ auth_params
          end

        rest_http_opts =
          Keyword.drop(merged_http_opts, [
            :headers,
            :params,
            :method,
            :url,
            :base_url,
            :redirect,
            :receive_timeout
          ])

        req =
          rest_http_opts
          |> Keyword.merge(
            method: method,
            url: path,
            base_url: base_url,
            headers: base_headers,
            params: merged_params,
            redirect: false,
            receive_timeout: receive_timeout
          )
          |> Req.new()
          |> Req.Request.put_headers(custom_headers)
          |> ReqLLM.Step.Error.attach()
          |> ReqLLM.Step.Telemetry.attach(model, opts, operation: lifecycle_operation)

        {:ok, req}

      {:error, msg} when is_binary(msg) ->
        {:error, Parameter.exception(parameter: msg)}
    end
  end

  defp normalize_http_headers(headers) when is_list(headers) or is_map(headers) do
    Enum.map(headers, fn {k, v} -> {String.downcase(to_string(k)), v} end)
  end

  defp normalize_http_headers(_), do: []

  defp sanitize_lifecycle_error(_prefix, %_{} = error) do
    error =
      error
      |> redact_error_field(:reason)
      |> redact_error_field(:message)

    case Map.fetch(error, :cause) do
      {:ok, %_{} = cause} ->
        Map.put(error, :cause, sanitize_lifecycle_error("", cause))

      {:ok, cause} when is_binary(cause) ->
        Map.put(error, :cause, Helpers.redact_api_key(cause))

      _ ->
        error
    end
  end

  defp sanitize_lifecycle_error(prefix, reason) do
    RequestError.exception(reason: "#{prefix}: #{Helpers.redact_api_key(inspect(reason))}")
  end

  defp redact_error_field(error, key) do
    case Map.fetch(error, key) do
      {:ok, val} when is_binary(val) -> Map.put(error, key, Helpers.redact_api_key(val))
      _ -> error
    end
  end

  defp resolve_lifecycle_model(opts) do
    case Keyword.get(opts, :model) do
      %LLMDB.Model{} = model ->
        {:ok, model}

      nil ->
        fallback_id =
          case Helpers.get_opt(opts, :agent) do
            agent when is_binary(agent) and agent != "" -> agent
            _ -> "google-interactions"
          end

        {:ok, Helpers.lookup_google_model(fallback_id)}

      model_spec when is_binary(model_spec) ->
        if not String.contains?(model_spec, ":") and Helpers.non_empty_binary?(model_spec) do
          {:ok, Helpers.lookup_google_model(model_spec)}
        else
          ReqLLM.model(model_spec)
        end

      model_spec ->
        ReqLLM.model(model_spec)
    end
  end

  defp resolve_lifecycle_model_from_body(opts, parsed, fallback_model) do
    case {Keyword.get(opts, :model), parsed["model"] || parsed["agent"]} do
      {nil, parsed_id} when is_binary(parsed_id) and parsed_id != "" ->
        Helpers.lookup_google_model(parsed_id)

      _ ->
        fallback_model
    end
  end

  defp resolve_response_model(req, body) do
    case req.private[:req_llm_model] do
      %LLMDB.Model{} = model ->
        model

      _ ->
        model_id =
          body["model"] || body["agent"] || req.options[:agent] || req.options[:model] ||
            "google-interactions"

        Helpers.lookup_google_model(model_id)
    end
  end

  defp validate_store_compat(opts) do
    store = Helpers.get_opt(opts, :store)
    prev_id = Helpers.get_opt(opts, :previous_interaction_id)
    background = Helpers.get_opt(opts, :background)

    cond do
      store == false and Helpers.non_empty_binary?(prev_id) ->
        {:error,
         Parameter.exception(
           parameter: "store: false cannot be combined with previous_interaction_id"
         )}

      store == false and background == true ->
        {:error,
         Parameter.exception(parameter: "store: false cannot be combined with background: true")}

      true ->
        :ok
    end
  end

  defp validate_target_compat(opts) do
    agent = Helpers.get_opt(opts, :agent)
    resume_id = Helpers.get_opt(opts, :interactions_resume_id)
    prev_id = Helpers.get_opt(opts, :previous_interaction_id)
    last_event_id = Helpers.get_opt(opts, :last_event_id)
    continuation_token = Helpers.get_opt(opts, :continuation_token)
    service_tier = Helpers.get_opt(opts, :service_tier)

    cond do
      agent != nil and not Helpers.non_empty_binary?(agent) ->
        {:error, Parameter.exception(parameter: "agent must be a non-empty string")}

      resume_id != nil and not Helpers.non_empty_binary?(resume_id) ->
        {:error,
         Parameter.exception(parameter: "interactions_resume_id must be a non-empty string")}

      prev_id != nil and not Helpers.non_empty_binary?(prev_id) ->
        {:error,
         Parameter.exception(parameter: "previous_interaction_id must be a non-empty string")}

      last_event_id != nil and not Helpers.non_empty_binary?(last_event_id) ->
        {:error, Parameter.exception(parameter: "last_event_id must be a non-empty string")}

      continuation_token != nil and not Helpers.non_empty_binary?(continuation_token) ->
        {:error, Parameter.exception(parameter: "continuation_token must be a non-empty string")}

      not valid_service_tier?(service_tier) ->
        {:error,
         Parameter.exception(parameter: "service_tier must be a non-empty atom or string")}

      true ->
        :ok
    end
  end

  defp validate_generate_content_response_format(opts) do
    if normalize_google_api(Helpers.get_opt(opts, :google_api)) == :generate_content and
         Helpers.get_opt(opts, :response_format) != nil do
      {:error,
       Parameter.exception(
         parameter:
           "google_api: :generate_content cannot be combined with Interactions-only options (:response_format)"
       )}
    else
      :ok
    end
  end

  defp validate_thinking_compat(:interactions, opts) do
    thinking_level = Helpers.get_opt(opts, :google_thinking_level)

    thinking_budget =
      Helpers.get_opt(opts, :google_thinking_budget) ||
        Helpers.get_opt(opts, :reasoning_token_budget)

    if thinking_level != nil and thinking_budget != nil do
      {:error,
       Parameter.exception(
         parameter:
           "google_thinking_budget and google_thinking_level cannot be combined in the same request"
       )}
    else
      :ok
    end
  end

  defp validate_thinking_compat(_mode, _opts), do: :ok

  defp valid_service_tier?(nil), do: true
  defp valid_service_tier?(tier) when is_boolean(tier), do: false

  defp valid_service_tier?(tier) when is_atom(tier),
    do: Helpers.non_empty_binary?(Atom.to_string(tier))

  defp valid_service_tier?(tier) when is_binary(tier), do: Helpers.non_empty_binary?(tier)
  defp valid_service_tier?(_), do: false

  defp normalize_google_api(:interactions), do: :interactions
  defp normalize_google_api("interactions"), do: :interactions
  defp normalize_google_api(:generate_content), do: :generate_content
  defp normalize_google_api("generate_content"), do: :generate_content
  defp normalize_google_api(nil), do: nil
  defp normalize_google_api(other), do: other
end

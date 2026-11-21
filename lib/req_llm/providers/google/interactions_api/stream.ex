defmodule ReqLLM.Providers.Google.InteractionsAPI.Stream do
  @moduledoc false

  alias ReqLLM.Context
  alias ReqLLM.Error.API.Request, as: RequestError
  alias ReqLLM.Error.API.Response, as: ResponseError
  alias ReqLLM.Error.Invalid.Parameter
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Provider.Utils
  alias ReqLLM.Providers.Google
  alias ReqLLM.Providers.Google.InteractionsAPI
  alias ReqLLM.Providers.Google.InteractionsAPI.Decoder
  alias ReqLLM.Providers.Google.InteractionsAPI.Encoder
  alias ReqLLM.Providers.Google.InteractionsAPI.Helpers
  alias ReqLLM.Providers.Google.InteractionsAPI.StepHistory
  alias ReqLLM.StreamChunk

  @interactions_event_types ~w(
    interaction.created
    interaction.status_update
    step.start
    step.delta
    step.stop
    interaction.completed
    error
  )

  def attach_stream(%LLMDB.Model{} = model, %Context{} = context, opts, _finch_name) do
    if Helpers.explicit_option?(opts, :interactions_resume_id) do
      resume_id = Helpers.get_opt(opts, :interactions_resume_id)

      if Helpers.non_empty_binary?(resume_id) do
        attach_resume_stream(model, resume_id, opts)
      else
        {:error,
         Parameter.exception(parameter: "interactions_resume_id must be a non-empty string")}
      end
    else
      attach_create_stream(model, context, opts)
    end
  rescue
    error in [Parameter] ->
      {:error, error}

    error ->
      {:error,
       RequestError.exception(
         reason:
           "Failed to build Google Interactions stream request: #{Helpers.redact_api_key(inspect(error))}"
       )}
  end

  defp attach_create_stream(model, context, opts) do
    with :ok <- InteractionsAPI.validate_no_prefill_for_request(model, context, opts),
         :ok <- ReqLLM.ProviderFileReference.validate_context(context, :google) do
      {req_opts, user_opts} = Keyword.split(opts, stream_req_only_keys())
      operation = Keyword.get(user_opts, :operation, :chat)
      explicit_thoughts? = Helpers.explicit_option?(user_opts, :google_include_thoughts)

      processed_opts =
        ReqLLM.Provider.Options.process_stream!(
          Google,
          operation,
          model,
          context,
          user_opts
        )
        |> InteractionsAPI.drop_default_include_thoughts(explicit_thoughts?)

      with :ok <- InteractionsAPI.validate_options(processed_opts) do
        base_url =
          opts
          |> Helpers.effective_base_url(
            Keyword.merge(processed_opts, Keyword.take(req_opts, [:base_url]))
          )

        query_params = extract_stream_query_params(req_opts, opts)

        opts_with_base =
          Keyword.merge(processed_opts,
            base_url: base_url,
            model_struct: model,
            query_params: query_params
          )

        url = build_stream_url(base_url, nil, opts_with_base)
        headers = build_stream_headers(opts_with_base)

        body =
          Jason.encode_to_iodata!(
            Encoder.build_request_body(model, context, Keyword.put(processed_opts, :stream, true))
          )

        {:ok, Finch.build(:post, url, headers, body)}
      end
    end
  end

  defp attach_resume_stream(model, interaction_id, opts) do
    {req_opts, user_opts} = Keyword.split(opts, stream_req_only_keys())
    operation = Keyword.get(user_opts, :operation, :chat)
    context = Keyword.get(opts, :context) || %Context{messages: []}

    processed_opts =
      ReqLLM.Provider.Options.process_stream!(
        Google,
        operation,
        model,
        context,
        user_opts
      )

    with :ok <- InteractionsAPI.validate_options(processed_opts) do
      merged_for_base =
        processed_opts
        |> Keyword.merge(Keyword.take(req_opts, [:base_url]))
        |> Keyword.put_new(:interaction_id, interaction_id)

      base_url = Helpers.effective_base_url(opts, merged_for_base)
      query_params = extract_stream_query_params(req_opts, opts)

      opts_with_model =
        Keyword.merge(processed_opts,
          base_url: base_url,
          model_struct: model,
          query_params: query_params
        )

      url = build_stream_url(base_url, interaction_id, opts_with_model)
      headers = build_stream_headers(opts_with_model, include_content_type?: false)

      {:ok, Finch.build(:get, url, headers, nil)}
    end
  end

  defp extract_stream_query_params(req_opts, opts) do
    http_params =
      opts
      |> Keyword.get(:req_http_options, [])
      |> Keyword.get(:params, [])
      |> Enum.to_list()

    direct_params =
      req_opts
      |> Keyword.get(:params, [])
      |> Enum.to_list()

    http_params ++ direct_params
  end

  defp stream_req_only_keys do
    [
      :params,
      :model,
      :base_url,
      :finch_name,
      :fixture,
      :retry,
      :max_retries,
      :retry_log_level,
      :google_api_type,
      :interactions_resume_id
    ]
  end

  defp build_stream_headers(opts, header_opts \\ []) do
    include_content_type? = Keyword.get(header_opts, :include_content_type?, true)

    base_headers =
      if include_content_type? do
        [
          {"content-type", "application/json"},
          {"accept", "text/event-stream"},
          {"api-revision", Helpers.api_revision()}
        ]
      else
        [
          {"accept", "text/event-stream"},
          {"api-revision", Helpers.api_revision()}
        ]
      end

    headers_with_auth =
      if Helpers.use_header_auth?(opts) do
        api_key = ReqLLM.Keys.get!(opts[:model_struct] || opts[:model], opts)
        [{"x-goog-api-key", api_key} | base_headers]
      else
        base_headers
      end

    custom_headers =
      opts[:req_http_options]
      |> Utils.extract_custom_headers()
      |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), v} end)

    custom_keys = MapSet.new(custom_headers, fn {k, _v} -> k end)

    filtered_base =
      Enum.reject(headers_with_auth, fn {k, _v} ->
        MapSet.member?(custom_keys, String.downcase(to_string(k)))
      end)

    filtered_base ++ custom_headers
  end

  defp build_stream_url(base_url, nil, opts) do
    append_stream_path_and_query(base_url, "/interactions", [], opts)
  end

  defp build_stream_url(base_url, interaction_id, opts) do
    path = "/interactions/#{Helpers.encode_path_segment(interaction_id)}"
    append_stream_path_and_query(base_url, path, resume_query_params(opts), opts)
  end

  defp append_stream_path_and_query(base_url, suffix_path, extra_params, opts) do
    uri = URI.parse(String.trim_trailing(base_url, "/"))
    base_path = String.trim_trailing(uri.path || "", "/")
    full_path = base_path <> suffix_path

    existing_params =
      if is_binary(uri.query) and uri.query != "" do
        uri.query |> URI.decode_query() |> Enum.to_list()
      else
        []
      end

    custom_params = Keyword.get(opts, :query_params, [])
    combined_params = existing_params ++ custom_params ++ extra_params

    all_params =
      if Helpers.use_header_auth?(opts) do
        combined_params
      else
        api_key = ReqLLM.Keys.get!(opts[:model_struct] || opts[:model], opts)

        filtered =
          Enum.reject(combined_params, fn {k, _v} -> to_string(k) == "key" end)

        filtered ++ [key: api_key]
      end

    query = if(all_params == [], do: nil, else: URI.encode_query(all_params))
    %{uri | path: full_path, query: query} |> URI.to_string()
  end

  def resume_query_params(opts) do
    case Helpers.get_opt(opts, :last_event_id) do
      id when is_binary(id) and id != "" -> [stream: "true", last_event_id: id]
      _ -> [stream: "true"]
    end
  end

  def stream_event?(%{} = event) do
    sse_name =
      Map.get(event, :event) ||
        Map.get(event, "event") ||
        Map.get(event, "event_type") ||
        Map.get(event, :event_type)

    interactions_event_name?(sse_name) or
      case Map.get(event, :data) || Map.get(event, "data") do
        %{"event_type" => event_type} ->
          interactions_event_name?(event_type)

        data when is_binary(data) ->
          if String.contains?(data, "\"event_type\"") do
            case ReqLLM.JSON.decode(data, json_repair: false) do
              {:ok, %{"event_type" => event_type}} -> interactions_event_name?(event_type)
              _ -> false
            end
          else
            false
          end

        _ ->
          false
      end
  end

  def stream_event?(_event), do: false

  defp interactions_event_name?(name) when is_binary(name) do
    name in @interactions_event_types or
      String.starts_with?(name, "interaction.") or
      String.starts_with?(name, "step.")
  end

  defp interactions_event_name?(_), do: false

  def init_stream_state(model \\ nil, opts \\ []) do
    resume_id = Helpers.get_opt(opts, :interactions_resume_id)
    interaction_id = if(Helpers.non_empty_binary?(resume_id), do: resume_id, else: nil)
    provider_meta = %{} |> Helpers.maybe_put_string("interaction_id", interaction_id)

    expect_json_object? =
      Keyword.get(opts, :operation) == :object or
        Helpers.json_response_format?(Helpers.get_opt(opts, :response_format))

    resumed_with_last_event_id? =
      Helpers.non_empty_binary?(Helpers.get_opt(opts, :last_event_id))

    %{
      __api__: :interactions,
      interaction_id: interaction_id,
      response_model: nil,
      response_format: nil,
      expect_json_object?: expect_json_object?,
      resumed_with_last_event_id?: resumed_with_last_event_id?,
      resume_lookup_opts: if(resumed_with_last_event_id?, do: Keyword.put(opts, :model, model)),
      missing_step?: false,
      status: nil,
      steps: %{},
      completed_steps: %{},
      completed_builtins: %{},
      rev_annotations: [],
      usage: nil,
      last_event_id: nil,
      continuation_token: nil,
      provider_meta: provider_meta,
      terminated?: false
    }
  end

  def decode_stream_event(event, model, state) when state in [nil, []],
    do: decode_stream_event(event, model, init_stream_state(model))

  def decode_stream_event(%{event: "done"}, _model, state), do: {[], state}
  def decode_stream_event(%{"event" => "done"}, _model, state), do: {[], state}
  def decode_stream_event(%{data: "[DONE]"}, _model, state), do: {[], state}
  def decode_stream_event(%{"data" => "[DONE]"}, _model, state), do: {[], state}

  def decode_stream_event(_event, _model, %{__api__: :interactions, terminated?: true} = state) do
    {[], state}
  end

  def decode_stream_event(event, model, %{__api__: :interactions} = state) do
    case decode_event_payload(event) do
      {:ok, data} when is_map(data) ->
        state = capture_event_id(state, event, data)
        event_type = data["event_type"] || Map.get(event, :event) || Map.get(event, "event")
        handle_stream_event(event_type, data, model, state)

      :done ->
        {[], state}

      :skip ->
        {[], state}

      :error ->
        {[], state}
    end
  end

  def flush_stream_state(_model, nil), do: {[], init_stream_state()}

  def flush_stream_state(_model, %{__api__: :interactions, terminated?: true} = state) do
    {[], state}
  end

  def flush_stream_state(model, %{__api__: :interactions} = state) do
    {chunks, updated_state} = finalize_open_steps(state)

    final_steps = ordered_completed_steps(updated_state.completed_steps)
    builtin_tools = ordered_builtin_tools(updated_state.completed_builtins)

    usage =
      refresh_existing_usage(
        updated_state.usage,
        updated_state.provider_meta["google_usage"],
        final_steps,
        model
      )

    provider_meta =
      updated_state.provider_meta
      |> Helpers.maybe_put_non_empty_list("builtin_tools", builtin_tools)

    flush_status =
      cond do
        updated_state.status in ["in_progress", "queued"] -> "incomplete"
        is_nil(updated_state.status) and final_steps != [] -> "incomplete"
        true -> updated_state.status
      end

    meta =
      %{
        response_id: updated_state.interaction_id,
        response_model: updated_state.response_model,
        provider_meta: provider_meta,
        google_interactions_steps: final_steps
      }
      |> Helpers.maybe_put_finish_reason(Decoder.resolve_finish_reason(flush_status, final_steps))
      |> Helpers.maybe_put_atom_key(:finish_reason_raw, updated_state.status)
      |> Helpers.maybe_put_usage_meta(usage)
      |> maybe_put_stream_object(
        updated_state.expect_json_object?,
        updated_state.status,
        final_steps
      )

    {chunks ++ [StreamChunk.meta(meta)],
     %{updated_state | usage: usage, provider_meta: provider_meta, terminated?: true}}
  end

  def decode_stateless_stream_event(event, model) do
    case decode_event_payload(event) do
      {:ok, data} when is_map(data) ->
        event_type = data["event_type"] || Map.get(event, :event) || Map.get(event, "event")
        decode_stateless_event_type(event_type, event, data, model)

      _ ->
        []
    end
  end

  defp decode_stateless_event_type(
         "step.delta",
         _event,
         %{
           "index" => index,
           "delta" => %{"type" => "thought_signature", "signature" => sig}
         },
         _model
       )
       when is_integer(index) and is_binary(sig) and sig != "" do
    [
      StreamChunk.thinking("", %{
        signature: sig,
        format: "google-interactions-v1",
        provider_data: %{"type" => "thought"},
        step_index: index
      })
    ]
  end

  defp decode_stateless_event_type(
         "step.stop",
         _event,
         %{"index" => index, "step" => %{} = step} = data,
         model
       )
       when is_integer(index) do
    state = init_stream_state(model)

    {step_chunks, builtin_entry, _fc?} =
      case Decoder.decode_single_step(step, index) do
        :skip -> {[], nil, false}
        result -> result
      end

    step_list =
      if(step["type"] in ["user_input", "function_result"], do: [], else: [step])

    usage = Decoder.normalize_usage(data["usage"], step_list, model)

    builtin_tools =
      if(builtin_entry, do: [builtin_entry], else: [])

    provider_meta =
      state.provider_meta
      |> Helpers.maybe_put_non_empty_list("builtin_tools", builtin_tools)
      |> Helpers.maybe_put_non_empty_map("google_usage", Helpers.stringify_if_map(data["usage"]))

    meta_chunks =
      if usage != nil or builtin_entry != nil do
        meta = %{provider_meta: provider_meta} |> Helpers.maybe_put_usage_meta(usage)
        [StreamChunk.meta(meta)]
      else
        []
      end

    step_chunks ++ meta_chunks
  end

  defp decode_stateless_event_type(_event_type, event, _data, model) do
    {chunks, _state} = decode_stream_event(event, model, init_stream_state(model))
    chunks
  end

  defp decode_event_payload(event) when is_map(event) do
    if sse_wrapper_map?(event) do
      raw_data = fetch_sse_data(event)
      sse_event = Map.get(event, :event) || Map.get(event, "event")

      case raw_data do
        "[DONE]" ->
          :done

        nil ->
          :skip

        data when is_map(data) ->
          {:ok, data}

        data when is_binary(data) ->
          decode_binary_sse_data(data, sse_event)

        _ ->
          :error
      end
    else
      {:ok, event}
    end
  end

  defp decode_event_payload(_), do: :error

  defp sse_wrapper_map?(event) do
    Map.has_key?(event, :data) or Map.has_key?(event, "data") or
      Map.has_key?(event, :event) or Map.has_key?(event, "event")
  end

  defp fetch_sse_data(event) do
    case Map.fetch(event, :data) do
      {:ok, val} -> val
      :error -> Map.get(event, "data")
    end
  end

  defp decode_binary_sse_data(data, sse_event) do
    case ReqLLM.JSON.decode(data, json_repair: false) do
      {:ok, parsed} when is_map(parsed) ->
        {:ok, parsed}

      _ ->
        if sse_event == "error" and Helpers.non_empty_binary?(data) do
          {:ok, %{"event_type" => "error", "error" => %{"message" => String.trim(data)}}}
        else
          :error
        end
    end
  end

  defp capture_event_id(state, event, data) do
    event_id = data["event_id"] || Map.get(event, :id) || Map.get(event, "id")

    if Helpers.non_empty_binary?(event_id) do
      provider_meta = Map.put(state.provider_meta, "last_event_id", event_id)
      %{state | last_event_id: event_id, provider_meta: provider_meta}
    else
      state
    end
  end

  defp handle_stream_event("interaction.created", data, model, state) do
    interaction = data["interaction"] || %{}
    interaction_id = interaction["id"] || state.interaction_id
    agent = interaction["agent"]

    response_model =
      interaction["model"] || agent || state.response_model || Helpers.model_id_fallback(model)

    status = interaction["status"] || state.status
    response_format = interaction["response_format"] || state.response_format

    expect_json_object? =
      state.expect_json_object? or Helpers.json_response_format?(response_format)

    provider_meta =
      state.provider_meta
      |> Helpers.maybe_put_string("interaction_id", interaction_id)
      |> Helpers.maybe_put_string("interaction_status", status)
      |> Helpers.maybe_put_string("agent", agent)
      |> Helpers.maybe_put_string("service_tier", interaction["service_tier"])
      |> Helpers.maybe_put_string("environment_id", interaction["environment_id"])

    next_state = %{
      state
      | interaction_id: interaction_id,
        response_model: response_model,
        response_format: response_format,
        expect_json_object?: expect_json_object?,
        status: status,
        provider_meta: provider_meta
    }

    chunk_meta =
      %{provider_meta: provider_meta}
      |> Helpers.maybe_put_atom_key(:response_id, interaction_id)
      |> Helpers.maybe_put_atom_key(:response_model, response_model)

    {[StreamChunk.meta(chunk_meta)], next_state}
  end

  defp handle_stream_event("interaction.status_update", data, model, state) do
    interaction = if(is_map(data["interaction"]), do: data["interaction"], else: %{})
    interaction_id = data["interaction_id"] || interaction["id"] || state.interaction_id
    status = data["status"] || interaction["status"] || state.status
    steps = ordered_completed_steps(state.completed_steps)
    raw_usage = data["usage"] || interaction["usage"]

    usage =
      normalize_usage_preserving_tokens(
        raw_usage,
        state.usage,
        state.provider_meta["google_usage"],
        steps,
        model
      )

    errors = extract_stream_errors(data) || extract_stream_errors(interaction)
    cont_token = data["continuation_token"] || interaction["continuation_token"]

    error_exception =
      if status == "failed" do
        reason = Decoder.extract_failure_reason(%{"errors" => errors, "error" => data["error"]})
        ResponseError.exception(reason: reason, response_body: data)
      end

    finish_reason = Decoder.resolve_finish_reason(status, steps)

    provider_meta =
      state.provider_meta
      |> Helpers.maybe_put_string("interaction_id", interaction_id)
      |> Helpers.maybe_put_string("interaction_status", status)
      |> Helpers.maybe_put_string("continuation_token", cont_token)
      |> Helpers.maybe_put_non_empty_list("errors", errors)
      |> Helpers.maybe_put_non_empty_map("google_usage", Helpers.stringify_if_map(raw_usage))

    next_state = %{
      state
      | interaction_id: interaction_id,
        status: status,
        usage: usage,
        continuation_token: cont_token || state.continuation_token,
        provider_meta: provider_meta
    }

    meta =
      %{provider_meta: provider_meta}
      |> Helpers.maybe_put_atom_key(:response_id, interaction_id)
      |> Helpers.maybe_put_finish_reason(finish_reason)
      |> Helpers.maybe_put_atom_key(
        :finish_reason_raw,
        if(finish_reason != nil, do: status)
      )
      |> Helpers.maybe_put_atom_key(:error, error_exception)
      |> Helpers.maybe_put_usage_meta(usage)

    {[StreamChunk.meta(meta)], next_state}
  end

  defp handle_stream_event("step.start", %{"index" => index, "step" => step}, _model, state)
       when is_integer(index) and is_map(step) do
    existing = Map.get(state.steps, index)
    entry = merge_started_step_entry(existing, step)

    {start_chunks, next_state} =
      if existing == nil do
        emit_step_start_chunks(step, index, state)
      else
        {[], state}
      end

    {start_chunks, %{next_state | steps: Map.put(next_state.steps, index, entry)}}
  end

  defp handle_stream_event("step.delta", %{"index" => index, "delta" => delta}, _model, state)
       when is_integer(index) and is_map(delta) do
    entry =
      Map.get(state.steps, index) ||
        init_stream_step_entry(%{"type" => infer_step_type_from_delta(delta)})

    {chunks, updated_entry} = apply_step_delta(delta, entry, index)
    {accumulated_chunks, next_state} = accumulate_stream_annotations(chunks, state)
    {accumulated_chunks, %{next_state | steps: Map.put(next_state.steps, index, updated_entry)}}
  end

  defp handle_stream_event("step.stop", %{"index" => index} = data, model, state)
       when is_integer(index) do
    {entry, remaining_steps} = Map.pop(state.steps, index)

    {raw_step_chunks, completed_step, builtin_entry} =
      case {entry, data["step"]} do
        {nil, %{} = step} ->
          normalized_step = Decoder.normalize_decoded_step(step, index, state.interaction_id)

          case Decoder.decode_single_step(normalized_step, index, state.interaction_id) do
            :skip -> {[], nil, nil}
            {chunks, builtin, _fc?} -> {chunks, normalized_step, builtin}
          end

        {entry, %{} = step} when is_map(entry) ->
          merged_entry = merge_stopped_step_entry(entry, step)
          finalize_step_entry(merged_entry, index, false, state.interaction_id)

        _ ->
          finalize_step_entry(entry, index, false, state.interaction_id)
      end

    {step_chunks, state} = accumulate_stream_annotations(raw_step_chunks, state)

    completed_steps =
      if completed_step do
        Map.put(state.completed_steps, index, completed_step)
      else
        state.completed_steps
      end

    completed_builtins =
      if builtin_entry do
        Map.put(state.completed_builtins, index, builtin_entry)
      else
        state.completed_builtins
      end

    ordered_steps = ordered_completed_steps(completed_steps)
    builtin_tools = ordered_builtin_tools(completed_builtins)

    usage =
      case data["usage"] do
        %{} = u when map_size(u) > 0 ->
          Decoder.normalize_usage(u, ordered_steps, model)

        _ ->
          refresh_existing_usage(
            state.usage,
            state.provider_meta["google_usage"],
            ordered_steps,
            model
          )
      end

    provider_meta =
      state.provider_meta
      |> Helpers.maybe_put_non_empty_list("builtin_tools", builtin_tools)
      |> Helpers.maybe_put_non_empty_map("google_usage", Helpers.stringify_if_map(data["usage"]))

    meta_chunks =
      if usage != nil or builtin_entry != nil do
        meta =
          %{provider_meta: provider_meta}
          |> Helpers.maybe_put_usage_meta(usage)

        [StreamChunk.meta(meta)]
      else
        []
      end

    next_state = %{
      state
      | steps: remaining_steps,
        missing_step?: state.missing_step? or (is_nil(entry) and is_nil(data["step"])),
        completed_steps: completed_steps,
        completed_builtins: completed_builtins,
        usage: usage,
        provider_meta: provider_meta
    }

    {step_chunks ++ meta_chunks, next_state}
  end

  defp handle_stream_event("interaction.completed", data, model, state) do
    interaction = data["interaction"] || %{}
    {open_chunks, state} = finalize_open_steps(state)

    interaction_id = interaction["id"] || state.interaction_id
    agent = interaction["agent"]

    response_model =
      interaction["model"] || agent || state.response_model || Helpers.model_id_fallback(model)

    status =
      interaction["status"] ||
        if(state.status in [nil, "in_progress", "queued"], do: "completed", else: state.status)

    response_format = interaction["response_format"] || state.response_format

    expect_json_object? =
      state.expect_json_object? or Helpers.json_response_format?(response_format)

    observed_steps = ordered_completed_steps(state.completed_steps)
    raw_steps = List.wrap(interaction["steps"])
    resolved_call_ids = StepHistory.extract_resolved_call_ids(raw_steps)

    payload_assistant_steps =
      raw_steps
      |> StepHistory.slice_latest_turn_steps()
      |> Enum.reject(&(Map.get(&1, "type") in ["user_input", "function_result"]))

    snapshot_only? =
      state.completed_steps == %{} and not state.resumed_with_last_event_id? and
        payload_assistant_steps != []

    {snapshot_chunks, state, final_steps, builtin_tools} =
      if snapshot_only? do
        {decoded_chunks, decoded_steps, decoded_builtins, _resolved} =
          Decoder.decode_steps_to_chunks(raw_steps, interaction_id)

        {acc_chunks, next_state} = accumulate_stream_annotations(decoded_chunks, state)
        {acc_chunks, next_state, decoded_steps, decoded_builtins}
      else
        {chosen_steps, chosen_builtins} =
          if payload_assistant_steps != [] and
               (state.resumed_with_last_event_id? or
                  length(payload_assistant_steps) > length(observed_steps)) do
            {payload_assistant_steps, Decoder.extract_builtin_tools(payload_assistant_steps)}
          else
            {observed_steps, ordered_builtin_tools(state.completed_builtins)}
          end

        {[], state, chosen_steps, chosen_builtins}
      end

    {recovered_chunks, final_steps, recovery_error} =
      if raw_steps == [] do
        recover_resumed_tool_calls(state, status, interaction_id, final_steps, resolved_call_ids)
      else
        {[], final_steps, nil}
      end

    usage =
      normalize_usage_preserving_tokens(
        interaction["usage"],
        state.usage,
        state.provider_meta["google_usage"],
        final_steps,
        model
      )

    finish_reason = Decoder.resolve_finish_reason(status, final_steps, resolved_call_ids)
    errors = extract_stream_errors(interaction)

    error_exception =
      if status == "failed" do
        ResponseError.exception(
          reason: Decoder.extract_failure_reason(interaction),
          response_body: interaction
        )
      else
        recovery_error
      end

    provider_meta =
      state.provider_meta
      |> Helpers.maybe_put_string("interaction_id", interaction_id)
      |> Helpers.maybe_put_string("interaction_status", status)
      |> Helpers.maybe_put_string("agent", agent)
      |> Helpers.maybe_put_string("service_tier", interaction["service_tier"])
      |> Helpers.maybe_put_string("environment_id", interaction["environment_id"])
      |> Helpers.maybe_put_string("continuation_token", interaction["continuation_token"])
      |> Helpers.maybe_put_non_empty_list("errors", errors)
      |> Helpers.maybe_put_non_empty_list("builtin_tools", builtin_tools)
      |> Helpers.maybe_put_non_empty_map(
        "google_usage",
        Helpers.stringify_if_map(interaction["usage"])
      )

    meta =
      %{
        response_id: interaction_id,
        response_model: response_model,
        finish_reason: finish_reason,
        finish_reason_raw: status,
        provider_meta: provider_meta,
        google_interactions_steps: final_steps,
        terminal?: true
      }
      |> Helpers.maybe_put_atom_key(:error, error_exception)
      |> Helpers.maybe_put_usage_meta(usage)
      |> maybe_put_stream_object(expect_json_object?, status, final_steps)

    next_state = %{
      state
      | interaction_id: interaction_id,
        response_model: response_model,
        response_format: response_format,
        expect_json_object?: expect_json_object?,
        status: status,
        usage: usage,
        provider_meta: provider_meta,
        terminated?: true
    }

    {open_chunks ++ snapshot_chunks ++ recovered_chunks ++ [StreamChunk.meta(meta)], next_state}
  end

  defp handle_stream_event("error", data, model, state) do
    errors = extract_stream_errors(data)
    reason = extract_stream_error_reason(data, errors)
    exception = ResponseError.exception(reason: reason, response_body: data)
    {open_chunks, updated_state} = finalize_open_steps(state)
    final_steps = ordered_completed_steps(updated_state.completed_steps)
    builtin_tools = ordered_builtin_tools(updated_state.completed_builtins)

    usage =
      refresh_existing_usage(
        updated_state.usage,
        updated_state.provider_meta["google_usage"],
        final_steps,
        model
      )

    provider_meta =
      updated_state.provider_meta
      |> Helpers.maybe_put_string("interaction_status", "failed")
      |> Helpers.maybe_put_non_empty_list("errors", errors)
      |> Helpers.maybe_put_non_empty_list("builtin_tools", builtin_tools)

    meta =
      %{
        response_id: updated_state.interaction_id,
        response_model: updated_state.response_model,
        finish_reason: :error,
        finish_reason_raw: "failed",
        error: exception,
        provider_meta: provider_meta,
        google_interactions_steps: final_steps,
        terminal?: true
      }
      |> Helpers.maybe_put_usage_meta(usage)

    next_state = %{
      updated_state
      | status: "failed",
        usage: usage,
        provider_meta: provider_meta,
        terminated?: true
    }

    {open_chunks ++ [StreamChunk.meta(meta)], next_state}
  end

  defp handle_stream_event(_event_type, _data, _model, state), do: {[], state}

  defp recover_resumed_tool_calls(
         %{missing_step?: true, resume_lookup_opts: opts, completed_steps: completed},
         "requires_action",
         id,
         final_steps,
         resolved_ids
       )
       when is_list(opts) and is_binary(id) do
    case InteractionsAPI.get(id, opts) do
      {:ok, %ReqLLM.Response{finish_reason: :tool_calls, message: message} = response} ->
        pending = response |> ReqLLM.Response.tool_calls() |> MapSet.new(& &1.id)
        observed = completed |> Map.values() |> MapSet.new(& &1["id"])
        steps = InteractionsAPI.verified_interactions_steps(message) || []
        first_recovered_index = Enum.max(Map.keys(completed), fn -> -1 end) + 1

        chunks =
          for {step, index} <- Enum.with_index(steps, first_recovered_index),
              step["type"] == "function_call",
              MapSet.member?(pending, step["id"]),
              not MapSet.member?(resolved_ids, step["id"]),
              not MapSet.member?(observed, step["id"]),
              {chunks, _, _} <- [Decoder.decode_single_step(step, index, id)],
              chunk <- chunks,
              do: chunk

        {chunks, steps, nil}

      {:ok, _response} ->
        {[], final_steps,
         ResponseError.exception(reason: "The resumed interaction has no pending tool calls")}

      {:error, error} ->
        {[], final_steps, error}
    end
  end

  defp recover_resumed_tool_calls(_state, _status, _id, final_steps, _resolved_ids),
    do: {[], final_steps, nil}

  defp extract_stream_error_reason(%{"error" => %{"message" => message}}, _errors)
       when is_binary(message) and message != "",
       do: message

  defp extract_stream_error_reason(%{"error" => message}, _errors)
       when is_binary(message) and message != "",
       do: message

  defp extract_stream_error_reason(_data, [%{"message" => message} | _])
       when is_binary(message) and message != "",
       do: message

  defp extract_stream_error_reason(%{"message" => message}, _errors)
       when is_binary(message) and message != "",
       do: message

  defp extract_stream_error_reason(_data, _errors), do: "Google Interactions stream error"

  defp extract_stream_errors(%{"errors" => errors}) when is_list(errors) and errors != [],
    do: errors

  defp extract_stream_errors(%{"error" => %{} = err}) when map_size(err) > 0, do: [err]
  defp extract_stream_errors(_), do: nil

  defp normalize_usage_preserving_tokens(usage_map, _fallback_usage, _raw_usage, steps, model)
       when is_map(usage_map) and map_size(usage_map) > 0 do
    Decoder.normalize_usage(usage_map, steps, model)
  end

  defp normalize_usage_preserving_tokens(_usage_map, fallback_usage, raw_usage, steps, model) do
    refresh_existing_usage(fallback_usage, raw_usage, steps, model)
  end

  defp refresh_existing_usage(_fallback_usage, raw_usage, steps, model)
       when is_map(raw_usage) and map_size(raw_usage) > 0 do
    Decoder.normalize_usage(raw_usage, steps, model)
  end

  defp refresh_existing_usage(fallback_usage, _raw_usage, steps, model)
       when is_map(fallback_usage) do
    if Map.drop(fallback_usage, [:tool_usage]) == %{} do
      Decoder.attach_step_tool_usage(nil, steps, model)
    else
      Decoder.attach_step_tool_usage(fallback_usage, steps, model)
    end
  end

  defp refresh_existing_usage(fallback_usage, _raw_usage, steps, model) do
    Decoder.attach_step_tool_usage(fallback_usage, steps, model)
  end

  defp merge_started_step_entry(nil, step), do: init_stream_step_entry(step)

  defp merge_started_step_entry(existing, step) when is_map(existing) and is_map(step) do
    started = init_stream_step_entry(step)
    effective_type = prefer_populated(started["type"], existing["type"])

    merged =
      Map.merge(started, existing, fn
        "_arg_chunks", _started_val, existing_val ->
          existing_val

        "_summary_chunks", _started_val, existing_val ->
          existing_val

        "_blocks_rev", started_val, existing_val ->
          coalesce_blocks_rev(existing_val ++ started_val)

        "signature", started_val, existing_val ->
          prefer_populated(existing_val, started_val)

        _k, started_val, existing_val ->
          prefer_populated(existing_val, started_val)
      end)

    merged
    |> Map.put("type", effective_type)
    |> drop_inferred_empty_summary(effective_type, existing, step)
  end

  defp coalesce_blocks_rev(blocks_rev) do
    blocks_rev
    |> Enum.reverse()
    |> Enum.reduce([], fn
      {:text_acc, rev_t2, []}, [{:text_acc, rev_t1, []} | rest] ->
        [{:text_acc, rev_t2 ++ rev_t1, []} | rest]

      block, acc ->
        [block | acc]
    end)
  end

  defp merge_stopped_step_entry(entry, step) when is_map(entry) and is_map(step) do
    effective_type = prefer_populated(step["type"], entry["type"])
    summary_chunks = Map.get(entry, "_summary_chunks", [])
    emitted_start_summary? = extract_thought_summary_text(entry["summary"]) != ""
    emitted_delta_summary? = extract_thought_summary_text(summary_chunks) != ""
    has_summary_deltas? = summary_chunks != []
    stop_summary = step["summary"]
    has_stop_summary? = is_list(stop_summary) and stop_summary != []

    summary_from_stop? =
      effective_type == "thought" and
        not emitted_start_summary? and
        not emitted_delta_summary? and
        has_stop_summary?

    merged =
      Map.merge(step, entry, fn
        "_arg_chunks", _step_val, entry_val ->
          entry_val

        "_summary_chunks", _step_val, entry_val ->
          if(effective_type == "thought" and has_stop_summary?, do: [], else: entry_val)

        "_blocks_rev", _step_val, entry_val ->
          entry_val

        "summary", step_val, entry_val ->
          cond do
            effective_type == "thought" and is_list(step_val) and step_val != [] ->
              step_val

            effective_type == "thought" and has_summary_deltas? ->
              entry_val

            true ->
              prefer_populated(entry_val, step_val)
          end

        "arguments", step_val, entry_val ->
          prefer_populated(entry_val, step_val)

        _k, step_val, entry_val ->
          prefer_populated(entry_val, step_val)
      end)
      |> Map.put("type", effective_type)
      |> drop_inferred_empty_summary(effective_type, entry, step)

    merged =
      if effective_type == "thought" and has_stop_summary? do
        Map.put(merged, "_summary_chunks", [])
      else
        merged
      end

    merged =
      if effective_type == "function_call" and is_map(step["arguments"]) do
        Map.put(merged, "_step_arguments", step["arguments"])
      else
        merged
      end

    merged =
      if effective_type == "model_output" and is_list(step["content"]) and
           has_meaningful_model_output_content?(step["content"]) do
        Map.put(merged, "_stop_content", step["content"])
      else
        merged
      end

    if summary_from_stop? do
      Map.put(merged, "_summary_from_stop?", true)
    else
      merged
    end
  end

  defp drop_inferred_empty_summary(merged, effective_type, entry, step)
       when effective_type != "thought" do
    if entry["summary"] == [] and not Map.has_key?(step, "summary") do
      Map.delete(merged, "summary")
    else
      merged
    end
  end

  defp drop_inferred_empty_summary(merged, _effective_type, _entry, _step), do: merged

  defp prefer_populated(val, fallback) when val in [nil, "", [], %{}], do: fallback
  defp prefer_populated(val, _fallback), do: val

  defp init_stream_step_entry(%{"type" => "function_call"} = step) do
    step
    |> Map.put("_arg_chunks", [])
  end

  defp init_stream_step_entry(%{"type" => "thought"} = step) do
    step
    |> Map.put_new("summary", [])
    |> Map.put("_summary_chunks", [])
  end

  defp init_stream_step_entry(%{"type" => "model_output"} = step) do
    {normalized_rev, initial_blocks_rev} =
      step
      |> Map.get("content", [])
      |> List.wrap()
      |> Enum.reduce({[], []}, fn item, {content_acc, blocks_acc} ->
        case item do
          %{"type" => "text", "text" => text} = text_item when is_binary(text) ->
            anns = Map.get(text_item, "annotations", []) |> List.wrap()

            if text != "" or anns != [] do
              {[item | content_acc], [{:text_acc, [text], Enum.reverse(anns)} | blocks_acc]}
            else
              {content_acc, blocks_acc}
            end

          other ->
            {[other | content_acc], [{:item, other} | blocks_acc]}
        end
      end)

    step
    |> Map.put("content", Enum.reverse(normalized_rev))
    |> Map.put("_blocks_rev", initial_blocks_rev)
  end

  defp init_stream_step_entry(step) when is_map(step), do: step

  defp emit_step_start_chunks(%{"type" => "model_output"} = step, _index, state) do
    chunks =
      step
      |> Map.get("content", [])
      |> List.wrap()
      |> Enum.flat_map(&Decoder.decode_model_output_content_item/1)

    accumulate_stream_annotations(chunks, state)
  end

  defp emit_step_start_chunks(%{"type" => "thought"} = step, index, state) do
    summary_text = extract_thought_summary_text(step["summary"])

    chunks =
      if summary_text != "" do
        [
          StreamChunk.thinking(summary_text, %{
            format: "google-interactions-v1",
            provider_data: %{"type" => "thought"},
            step_index: index
          })
        ]
      else
        []
      end

    {chunks, state}
  end

  defp emit_step_start_chunks(_step, _index, state), do: {[], state}

  defp accumulate_stream_annotations(chunks, state) do
    {rev_chunks, next_rev_anns} =
      Enum.reduce(chunks, {[], state.rev_annotations}, fn
        %StreamChunk{type: :meta, metadata: %{annotations: anns} = meta} = chunk,
        {acc_chunks, rev_anns}
        when is_list(anns) and anns != [] ->
          updated_rev = Enum.reverse(anns, rev_anns)

          updated_chunk = %{
            chunk
            | metadata: Map.put(meta, :annotations, Enum.reverse(updated_rev))
          }

          {[updated_chunk | acc_chunks], updated_rev}

        %StreamChunk{
          type: :content_part,
          content_part: %ContentPart{metadata: %{annotations: anns}}
        } = chunk,
        {acc_chunks, rev_anns}
        when is_list(anns) and anns != [] ->
          updated_rev = Enum.reverse(anns, rev_anns)
          {[chunk | acc_chunks], updated_rev}

        chunk, {acc_chunks, rev_anns} ->
          {[chunk | acc_chunks], rev_anns}
      end)

    {Enum.reverse(rev_chunks), %{state | rev_annotations: next_rev_anns}}
  end

  defp infer_step_type_from_delta(%{"type" => "text"}), do: "model_output"
  defp infer_step_type_from_delta(%{"type" => "text_annotation"}), do: "model_output"
  defp infer_step_type_from_delta(%{"type" => "image"}), do: "model_output"
  defp infer_step_type_from_delta(%{"type" => "audio"}), do: "model_output"
  defp infer_step_type_from_delta(%{"type" => "video"}), do: "model_output"
  defp infer_step_type_from_delta(%{"type" => "document"}), do: "model_output"
  defp infer_step_type_from_delta(%{"type" => "thought_summary"}), do: "thought"
  defp infer_step_type_from_delta(%{"type" => "thought_signature"}), do: "thought"
  defp infer_step_type_from_delta(%{"type" => "arguments_delta"}), do: "function_call"
  defp infer_step_type_from_delta(%{"type" => type}) when is_binary(type), do: type
  defp infer_step_type_from_delta(_), do: "model_output"

  defp apply_step_delta(%{"type" => "text"} = delta, entry, _index) do
    text = delta["text"]
    anns = delta["annotations"]

    {text_chunks, entry} =
      if is_binary(text) and text != "" do
        {[StreamChunk.text(text)], push_model_output_text(entry, text)}
      else
        {[], entry}
      end

    {ann_chunks, entry} =
      if is_list(anns) and anns != [] do
        {[StreamChunk.meta(%{annotations: anns})], push_model_output_annotations(entry, anns)}
      else
        {[], entry}
      end

    {text_chunks ++ ann_chunks, entry}
  end

  defp apply_step_delta(%{"type" => "text_annotation", "annotations" => anns}, entry, _index)
       when is_list(anns) do
    updated = push_model_output_annotations(entry, anns)
    chunks = if(anns != [], do: [StreamChunk.meta(%{annotations: anns})], else: [])
    {chunks, updated}
  end

  defp apply_step_delta(%{"type" => "arguments_delta", "arguments" => fragment}, entry, _index)
       when is_binary(fragment) do
    updated = Map.update(entry, "_arg_chunks", [fragment], &[fragment | &1])
    {[], updated}
  end

  defp apply_step_delta(%{"type" => "thought_summary", "content" => content}, entry, index)
       when is_map(content) do
    push_thought_summary_delta(content, entry, index)
  end

  defp apply_step_delta(%{"type" => "thought_summary", "text" => text}, entry, index)
       when is_binary(text) do
    push_thought_summary_delta(%{"type" => "text", "text" => text}, entry, index)
  end

  defp apply_step_delta(%{"type" => "thought_signature", "signature" => sig}, entry, _index)
       when is_binary(sig) do
    updated = Map.put(entry, "signature", sig)
    {[], updated}
  end

  defp apply_step_delta(%{"type" => "image"} = delta, entry, _index) do
    part = Decoder.decode_media_content_part(:image, delta, "image/png")
    content_item = Map.delete(delta, "event_type")
    updated = push_model_output_item(entry, content_item)
    {[StreamChunk.content_part(part)], updated}
  end

  defp apply_step_delta(%{"type" => type} = delta, entry, _index)
       when type in ["audio", "video", "document"] do
    part = Decoder.decode_media_content_part({:file, type}, delta, nil)
    content_item = Map.delete(delta, "event_type")
    updated = push_model_output_item(entry, content_item)
    {[StreamChunk.content_part(part)], updated}
  end

  @appendable_delta_keys ["output", "code", "stdout", "stderr", "text"]

  defp apply_step_delta(delta, entry, _index) when is_map(delta) do
    merged =
      delta
      |> Map.drop(["type", "event_type"])
      |> then(&Map.merge(entry, &1, fn k, v1, v2 -> merge_delta_field(k, v1, v2) end))

    {[], merged}
  end

  defp push_thought_summary_delta(content, entry, index) do
    summary_text = content["text"] || ""

    cond do
      summary_text != "" ->
        meta = %{
          format: "google-interactions-v1",
          provider_data: %{"type" => "thought"},
          step_index: index
        }

        updated = Map.update(entry, "_summary_chunks", [content], &[content | &1])
        {[StreamChunk.thinking(summary_text, meta)], updated}

      Map.get(content, "type") in [nil, "text"] ->
        {[], entry}

      true ->
        updated = Map.update(entry, "_summary_chunks", [content], &[content | &1])
        {[], updated}
    end
  end

  defp push_model_output_text(entry, text) do
    Map.update(entry, "_blocks_rev", [{:text_acc, [text], []}], fn
      [{:text_acc, rev_texts, rev_anns} | rest] ->
        [{:text_acc, [text | rev_texts], rev_anns} | rest]

      blocks ->
        [{:text_acc, [text], []} | blocks]
    end)
  end

  defp push_model_output_annotations(entry, []), do: entry

  defp push_model_output_annotations(entry, anns) do
    Map.update(entry, "_blocks_rev", [{:text_acc, [], Enum.reverse(anns)}], fn
      [{:text_acc, rev_texts, rev_anns} | rest] ->
        [{:text_acc, rev_texts, Enum.reverse(anns, rev_anns)} | rest]

      blocks ->
        [{:text_acc, [], Enum.reverse(anns)} | blocks]
    end)
  end

  defp push_model_output_item(entry, item) do
    Map.update(entry, "_blocks_rev", [{:item, item}], &[{:item, item} | &1])
  end

  defp merge_delta_field(key, v1, v2) when is_binary(v1) and is_binary(v2) do
    if key in @appendable_delta_keys, do: v1 <> v2, else: v2
  end

  defp merge_delta_field(_key, v1, v2) when is_list(v1) and is_list(v2), do: v1 ++ v2

  defp merge_delta_field(_key, v1, v2) when is_map(v1) and is_map(v2) do
    Map.merge(v1, v2, fn nested_key, a, b -> merge_delta_field(nested_key, a, b) end)
  end

  defp merge_delta_field(_key, _v1, v2), do: v2

  defp finalize_step_entry(nil, _index, _open?, _interaction_id), do: {[], nil, nil}

  defp finalize_step_entry(%{"type" => type}, _index, _open?, _interaction_id)
       when type in ["user_input", "function_result"],
       do: {[], nil, nil}

  defp finalize_step_entry(%{"type" => "thought"} = entry, index, _open?, _interaction_id) do
    sig = entry["signature"]

    summary =
      ((entry["summary"] || []) ++ Enum.reverse(Map.get(entry, "_summary_chunks", [])))
      |> coalesce_summary_items()

    clean =
      entry
      |> Map.put("summary", summary)
      |> Map.take(["type", "signature", "summary"])
      |> drop_empty_summary()

    summary_text =
      if Map.get(entry, "_summary_from_stop?") == true do
        extract_thought_summary_text(summary)
      else
        ""
      end

    has_sig? = is_binary(sig) and sig != ""

    chunks =
      if summary_text != "" or has_sig? do
        meta =
          %{
            format: "google-interactions-v1",
            provider_data: %{"type" => "thought"},
            step_index: index
          }
          |> Helpers.maybe_put_atom_key(:signature, if(has_sig?, do: sig))

        [StreamChunk.thinking(summary_text, meta)]
      else
        []
      end

    {chunks, clean, nil}
  end

  defp finalize_step_entry(%{"type" => "model_output"} = entry, _index, _open?, _interaction_id) do
    blocks_rev = Map.get(entry, "_blocks_rev", [])

    if blocks_rev == [] do
      fallback_content = List.wrap(entry["content"])
      chunks = Enum.flat_map(fallback_content, &Decoder.decode_model_output_content_item/1)

      step =
        %{"type" => "model_output", "content" => fallback_content}
        |> Helpers.maybe_put_string("signature", entry["signature"])

      {chunks, step, nil}
    else
      blocks_content = materialize_model_output_blocks(blocks_rev)

      {chunks, content} =
        case entry["_stop_content"] do
          stop_content when is_list(stop_content) and stop_content != [] ->
            reconcile_model_output_with_stop(blocks_content, stop_content)

          _ ->
            {[], blocks_content}
        end

      step =
        %{"type" => "model_output", "content" => content}
        |> Helpers.maybe_put_string("signature", entry["signature"])

      {chunks, step, nil}
    end
  end

  defp finalize_step_entry(%{"type" => "function_call"}, _index, true, _interaction_id),
    do: {[], nil, nil}

  defp finalize_step_entry(%{"type" => "function_call"} = entry, index, false, interaction_id) do
    case entry["name"] do
      name when is_binary(name) and name != "" ->
        raw_args = entry |> Map.get("_arg_chunks", []) |> Enum.reverse() |> IO.iodata_to_binary()
        raw_id = entry["id"]

        call_id =
          if Helpers.non_empty_binary?(raw_id),
            do: raw_id,
            else: Decoder.fallback_call_id(interaction_id, index)

        args_result =
          case raw_args do
            "" ->
              {:ok, entry["arguments"] || %{}}

            json ->
              case decode_tool_call_arguments(json) do
                {:ok, args} ->
                  {:ok, args}

                {:error, :invalid_json} ->
                  case Map.fetch(entry, "_step_arguments") do
                    {:ok, %{} = step_args} -> {:ok, step_args}
                    _ -> {:error, :invalid_json}
                  end
              end
          end

        case args_result do
          {:ok, args} ->
            sig = entry["signature"]

            step =
              %{
                "type" => "function_call",
                "id" => call_id,
                "name" => name,
                "arguments" => args
              }
              |> Helpers.maybe_put_string("signature", sig)

            meta =
              %{id: call_id, index: index}
              |> Helpers.maybe_put_atom_key(
                :signature,
                if(Helpers.non_empty_binary?(sig), do: sig)
              )

            chunk = StreamChunk.tool_call(name, args, meta)
            {[chunk], step, nil}

          {:error, :invalid_json} ->
            {[], nil, nil}
        end

      _ ->
        {[], nil, nil}
    end
  end

  defp finalize_step_entry(%{"type" => _step_type} = entry, _index, _open?, _interaction_id) do
    clean =
      Map.drop(entry, [
        "_text_chunks",
        "_annotations",
        "_arg_chunks",
        "_step_arguments",
        "_summary_chunks",
        "_summary_from_stop?",
        "_content_chunks",
        "_stop_content",
        "_blocks_rev"
      ])

    part = ContentPart.provider_block(:google, clean, %{api: :interactions})
    {[StreamChunk.content_part(part)], clean, Decoder.summarize_builtin_step(clean)}
  end

  defp materialize_model_output_blocks(blocks_rev) do
    blocks_rev
    |> Enum.reverse()
    |> Enum.flat_map(fn
      {:text_acc, rev_texts, rev_anns} ->
        text = rev_texts |> Enum.reverse() |> IO.iodata_to_binary()
        anns = Enum.reverse(rev_anns)

        if text != "" or anns != [] do
          item = %{"type" => "text", "text" => text}
          item = if(anns != [], do: Map.put(item, "annotations", anns), else: item)
          [item]
        else
          []
        end

      {:item, item} ->
        [item]
    end)
  end

  defp reconcile_model_output_with_stop(blocks_content, stop_content) do
    emitted_text = model_output_text(blocks_content)
    stop_text = model_output_text(stop_content)
    emitted_anns = model_output_annotations(blocks_content)
    stop_anns = model_output_annotations(stop_content)
    emitted_items = Enum.reject(blocks_content, &(Map.get(&1, "type") == "text"))
    stop_items = Enum.reject(stop_content, &(Map.get(&1, "type") == "text"))

    text_chunks =
      cond do
        stop_text != "" and String.starts_with?(stop_text, emitted_text) ->
          suffix = String.replace_prefix(stop_text, emitted_text, "")
          if(suffix != "", do: [StreamChunk.text(suffix)], else: [])

        emitted_text == "" and stop_text != "" ->
          [StreamChunk.text(stop_text)]

        true ->
          []
      end

    new_anns = trailing_new_items(stop_anns, emitted_anns, &(&1 == &2))
    ann_chunks = if(new_anns != [], do: [StreamChunk.meta(%{annotations: new_anns})], else: [])

    new_items = trailing_new_items(stop_items, emitted_items, &same_model_output_item?/2)
    item_chunks = Enum.flat_map(new_items, &Decoder.decode_model_output_content_item/1)

    final_content =
      cond do
        stop_text != "" ->
          if emitted_items != [] and stop_items == [] do
            emitted_items ++ stop_content
          else
            stop_content
          end

        emitted_text == "" and stop_items != [] ->
          stop_content

        true ->
          blocks_content
          |> attach_trailing_annotations(new_anns)
          |> Kernel.++(new_items)
      end

    {text_chunks ++ ann_chunks ++ item_chunks, final_content}
  end

  defp has_meaningful_model_output_content?(content) when is_list(content) do
    Enum.any?(content, fn
      %{"type" => "text", "text" => text} = item when is_binary(text) ->
        text != "" or List.wrap(Map.get(item, "annotations")) != []

      %{} ->
        true

      _ ->
        false
    end)
  end

  defp model_output_text(items) do
    Enum.map_join(items, "", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp model_output_annotations(items) do
    Enum.flat_map(items, &List.wrap(Map.get(&1, "annotations")))
  end

  defp trailing_new_items(stop_list, [], _eq_fn), do: stop_list
  defp trailing_new_items([], _emitted_list, _eq_fn), do: []

  defp trailing_new_items(stop_list, emitted_list, eq_fn) do
    if prefix_match?(stop_list, emitted_list, eq_fn) do
      Enum.drop(stop_list, length(emitted_list))
    else
      Enum.reject(stop_list, fn s -> Enum.any?(emitted_list, &eq_fn.(s, &1)) end)
    end
  end

  defp prefix_match?(_stop_list, [], _eq_fn), do: true
  defp prefix_match?([], _emitted_list, _eq_fn), do: false

  defp prefix_match?([s | s_rest], [e | e_rest], eq_fn) do
    eq_fn.(s, e) and prefix_match?(s_rest, e_rest, eq_fn)
  end

  defp same_model_output_item?(a, b) when a == b, do: true

  defp same_model_output_item?(%{"type" => t} = a, %{"type" => t} = b) do
    id_a = item_identity(a)
    id_a != nil and id_a == item_identity(b)
  end

  defp same_model_output_item?(_a, _b), do: false

  defp item_identity(item) do
    Enum.find_value(["id", "uri", "data"], fn key ->
      val = Map.get(item, key)
      if is_binary(val) and val != "", do: {key, val}
    end)
  end

  defp attach_trailing_annotations(blocks_content, []), do: blocks_content

  defp attach_trailing_annotations(blocks_content, new_anns) do
    {updated, attached?} =
      blocks_content
      |> Enum.reverse()
      |> Enum.reduce({[], false}, fn
        %{"type" => "text"} = item, {acc, false} ->
          updated_item = Map.update(item, "annotations", new_anns, &(&1 ++ new_anns))
          {[updated_item | acc], true}

        item, {acc, attached?} ->
          {[item | acc], attached?}
      end)

    if attached? do
      updated
    else
      updated ++ [%{"type" => "text", "text" => "", "annotations" => new_anns}]
    end
  end

  defp extract_thought_summary_text(summary) do
    summary
    |> List.wrap()
    |> Enum.map_join("", fn
      %{"type" => "text", "text" => t} when is_binary(t) -> t
      %{"text" => t} when is_binary(t) -> t
      _ -> ""
    end)
  end

  defp coalesce_summary_items(items) when is_list(items) do
    items
    |> Enum.reduce([], fn
      %{"type" => "text", "text" => t2} = item, [%{"type" => "text", "text" => t1} = prev | rest]
      when is_binary(t1) and is_binary(t2) and map_size(item) == 2 and map_size(prev) == 2 ->
        [%{prev | "text" => t1 <> t2} | rest]

      %{"type" => "text", "text" => ""}, acc ->
        acc

      %{"text" => t2} = item, [%{"text" => t1} = prev | rest]
      when not is_map_key(item, "type") and not is_map_key(prev, "type") and is_binary(t1) and
             is_binary(t2) and map_size(item) == 1 and map_size(prev) == 1 ->
        [%{prev | "text" => t1 <> t2} | rest]

      %{"text" => ""}, acc ->
        acc

      item, acc ->
        [item | acc]
    end)
    |> Enum.reverse()
  end

  defp finalize_open_steps(state) do
    {rev_chunks, completed_steps, completed_builtins} =
      state.steps
      |> Enum.sort_by(fn {idx, _entry} -> idx end)
      |> Enum.reduce({[], state.completed_steps, state.completed_builtins}, fn {idx, entry},
                                                                               {chunks_acc,
                                                                                steps_acc,
                                                                                builtins_acc} ->
        {step_chunks, step, builtin} =
          finalize_step_entry(entry, idx, true, state.interaction_id)

        next_steps = if(step, do: Map.put(steps_acc, idx, step), else: steps_acc)

        next_builtins =
          if(builtin, do: Map.put(builtins_acc, idx, builtin), else: builtins_acc)

        {Enum.reverse(step_chunks, chunks_acc), next_steps, next_builtins}
      end)

    {Enum.reverse(rev_chunks),
     %{
       state
       | steps: %{},
         completed_steps: completed_steps,
         completed_builtins: completed_builtins
     }}
  end

  defp ordered_completed_steps(completed_steps) do
    completed_steps
    |> Enum.sort_by(fn {idx, _step} -> idx end)
    |> Enum.map(fn {_idx, step} -> step end)
  end

  defp ordered_builtin_tools(completed_builtins) do
    completed_builtins
    |> Enum.sort_by(fn {idx, _builtin} -> idx end)
    |> Enum.map(fn {_idx, builtin} -> builtin end)
  end

  defp decode_tool_call_arguments(json) do
    case ReqLLM.JSON.decode(json, json_repair: false) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_json}
    end
  end

  defp drop_empty_summary(%{"summary" => []} = step), do: Map.delete(step, "summary")
  defp drop_empty_summary(step), do: step

  defp maybe_put_stream_object(meta, true, "completed", steps) do
    text =
      steps
      |> Enum.filter(&(Map.get(&1, "type") == "model_output"))
      |> Enum.flat_map(&List.wrap(Map.get(&1, "content")))
      |> Enum.filter(&(Map.get(&1, "type") == "text" and is_binary(Map.get(&1, "text"))))
      |> Enum.map_join("", &Map.get(&1, "text"))

    has_fc? = Enum.any?(steps, &(Map.get(&1, "type") == "function_call"))

    if not has_fc? and text != "" do
      case ReqLLM.JSON.decode(text) do
        {:ok, obj} when is_map(obj) or is_list(obj) -> Map.put(meta, :object, obj)
        _ -> meta
      end
    else
      meta
    end
  end

  defp maybe_put_stream_object(meta, _expect_json_object?, _status, _steps), do: meta
end

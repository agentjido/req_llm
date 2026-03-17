defmodule ReqLLM.Telemetry do
  @moduledoc """
  Shared telemetry helpers for ReqLLM request lifecycle instrumentation.

  This module owns:

  - request correlation IDs
  - request lifecycle events
  - reasoning lifecycle events
  - summary extraction
  - payload policy
  - compatibility emission for `[:req_llm, :token_usage]`
  """

  alias ReqLLM.{Context, Message, ModelHelpers, Response}

  @request_context_key :req_llm_telemetry
  @token_usage_event [:req_llm, :token_usage]
  @request_start_event [:req_llm, :request, :start]
  @request_stop_event [:req_llm, :request, :stop]
  @request_exception_event [:req_llm, :request, :exception]
  @reasoning_start_event [:req_llm, :reasoning, :start]
  @reasoning_update_event [:req_llm, :reasoning, :update]
  @reasoning_stop_event [:req_llm, :reasoning, :stop]

  @type payload_mode :: :none | :raw
  @type lifecycle_mode :: :sync | :stream
  @type transport :: :req | :finch

  @type context :: %{
          request_id: String.t(),
          model: LLMDB.Model.t(),
          operation: atom(),
          mode: lifecycle_mode(),
          transport: transport(),
          payload_mode: payload_mode(),
          original_opts: keyword(),
          request_summary: map(),
          request_payload: any(),
          request_started?: boolean(),
          request_stopped?: boolean(),
          started_at: integer() | nil,
          request_measurement: map() | nil,
          requested_reasoning: map(),
          effective_reasoning: map(),
          reasoning_started?: boolean(),
          reasoning_started_at: integer() | nil,
          reasoning_observation: map(),
          response_summary_state: map()
        }

  @doc """
  Returns the private key used to store telemetry context on Req requests.
  """
  @spec request_context_key() :: atom()
  def request_context_key, do: @request_context_key

  @doc """
  Builds a telemetry context for a request lifecycle.
  """
  @spec new_context(LLMDB.Model.t(), keyword(), keyword()) :: context()
  def new_context(%LLMDB.Model{} = model, opts, extra \\ []) do
    operation = Keyword.get(extra, :operation, Keyword.get(opts, :operation, :chat))
    mode = Keyword.get(extra, :mode, :sync)
    transport = Keyword.get(extra, :transport, :req)
    payload_mode = payload_mode(opts)
    request_input = request_input(operation, opts)
    requested_reasoning = requested_reasoning(model, operation, opts)

    %{
      request_id: request_id(),
      model: model,
      operation: operation,
      mode: mode,
      transport: transport,
      payload_mode: payload_mode,
      original_opts: opts,
      request_summary: summarize_request(operation, request_input),
      request_payload: request_payload(operation, request_input, payload_mode),
      request_started?: false,
      request_stopped?: false,
      started_at: nil,
      request_measurement: nil,
      requested_reasoning: requested_reasoning,
      effective_reasoning: disable_effective_reasoning(requested_reasoning),
      reasoning_started?: false,
      reasoning_started_at: nil,
      reasoning_observation: new_reasoning_observation(),
      response_summary_state: new_response_summary_state(operation)
    }
  end

  @doc """
  Emits request start telemetry and returns the updated context.
  """
  @spec start_request(context(), any()) :: context()
  def start_request(%{request_started?: true} = context, _request_source), do: context

  def start_request(context, request_source) do
    now = System.monotonic_time()
    measurement = %{system_time: System.system_time()}
    effective_reasoning = effective_reasoning(context.model, context.operation, request_source)

    context =
      context
      |> Map.put(:request_started?, true)
      |> Map.put(:started_at, now)
      |> Map.put(:request_measurement, measurement)
      |> Map.put(:effective_reasoning, effective_reasoning)

    :telemetry.execute(
      @request_start_event,
      measurement,
      request_metadata(context, %{
        http_status: nil,
        finish_reason: nil,
        usage: nil,
        response_summary: response_summary(context.response_summary_state, context.operation),
        response_payload: nil
      })
    )

    if reasoning_enabled?(context) do
      reasoning_measurement = %{system_time: System.system_time()}

      :telemetry.execute(
        @reasoning_start_event,
        reasoning_measurement,
        reasoning_metadata(context, %{milestone: :request_started})
      )

      context
      |> Map.put(:reasoning_started?, true)
      |> Map.put(:reasoning_started_at, now)
    else
      context
    end
  end

  @doc """
  Observes a streaming chunk and emits milestone-based reasoning updates.
  """
  @spec observe_stream_chunk(context(), ReqLLM.StreamChunk.t()) :: context()
  def observe_stream_chunk(context, %ReqLLM.StreamChunk{} = chunk) do
    context =
      context
      |> update_response_summary_state(chunk)
      |> observe_stream_chunk_reasoning(chunk)

    context
  end

  @doc """
  Observes a terminal response and updates response and reasoning state.
  """
  def observe_response(context, %Req.Response{body: body} = response) do
    usage = usage_from_response(response)
    response_summary = summarize_response(context.operation, body)

    context
    |> Map.put(
      :response_summary_state,
      merge_response_summary(context.response_summary_state, response_summary)
    )
    |> observe_reasoning_usage(usage || usage_from_response(body))
    |> observe_reasoning_from_response(body)
  end

  @spec observe_response(context(), any()) :: context()
  def observe_response(context, response) do
    usage = usage_from_response(response)
    response_summary = summarize_response(context.operation, response)

    context
    |> Map.put(
      :response_summary_state,
      merge_response_summary(context.response_summary_state, response_summary)
    )
    |> observe_reasoning_usage(usage)
    |> observe_reasoning_from_response(response)
  end

  @doc """
  Emits request stop telemetry and returns the updated context.
  """
  @spec stop_request(context(), any(), keyword()) :: context()
  def stop_request(context, response, opts \\ [])

  def stop_request(%{request_stopped?: true} = context, _response, _opts), do: context

  def stop_request(context, response, opts) do
    context = ensure_started(context, context.original_opts)
    context = observe_response(context, response)

    finish_reason =
      Keyword.get(opts, :finish_reason) ||
        finish_reason_from_response(response) ||
        finish_reason_from_state(context.response_summary_state) ||
        :unknown

    http_status = Keyword.get(opts, :http_status) || http_status_from_response(response)
    usage = Keyword.get(opts, :usage) || usage_from_response(response)
    response_summary = response_summary(context.response_summary_state, context.operation)
    response_payload = response_payload(context.operation, response, context.payload_mode)

    :telemetry.execute(
      @request_stop_event,
      stop_measurements(context),
      request_metadata(context, %{
        http_status: http_status,
        finish_reason: finish_reason,
        usage: usage,
        response_summary: response_summary,
        response_payload: response_payload
      })
    )

    maybe_emit_reasoning_stop(context, finish_reason)

    if Keyword.get(opts, :emit_token_usage?, false) do
      emit_token_usage(context.model, usage,
        request_id: context.request_id,
        operation: context.operation,
        mode: context.mode,
        provider: context.model.provider,
        transport: context.transport
      )
    end

    %{context | request_stopped?: true}
  end

  @doc """
  Emits request exception telemetry and returns the updated context.
  """
  @spec exception_request(context(), Exception.t() | term(), keyword()) :: context()
  def exception_request(context, error, opts \\ [])

  def exception_request(%{request_stopped?: true} = context, _error, _opts), do: context

  def exception_request(context, error, _opts) do
    context = ensure_started(context, context.original_opts)
    context = observe_error_reasoning(context, error)

    :telemetry.execute(
      @request_exception_event,
      stop_measurements(context),
      request_metadata(context, %{
        http_status: http_status_from_error(error),
        finish_reason: :error,
        usage: nil,
        response_summary: response_summary(context.response_summary_state, context.operation),
        response_payload: nil,
        error: error
      })
    )

    maybe_emit_reasoning_stop(context, :error)
    %{context | request_stopped?: true}
  end

  @doc """
  Emits the compatibility token usage event.
  """
  @spec emit_token_usage(LLMDB.Model.t(), map() | nil, keyword()) :: :ok
  def emit_token_usage(model, usage, metadata \\ [])

  def emit_token_usage(_model, nil, _metadata), do: :ok

  def emit_token_usage(%LLMDB.Model{} = model, usage, metadata) when is_list(metadata) do
    measurements = token_usage_measurements(usage)

    :telemetry.execute(
      @token_usage_event,
      measurements,
      %{
        model: model,
        request_id: metadata[:request_id],
        operation: metadata[:operation],
        mode: metadata[:mode],
        provider: metadata[:provider] || model.provider,
        transport: metadata[:transport]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    )
  end

  @doc """
  Reads telemetry context from a Req request.
  """
  @spec request_context(Req.Request.t()) :: context() | nil
  def request_context(%Req.Request{private: private}) do
    private[@request_context_key]
  end

  @doc """
  Stores telemetry context in a Req request.
  """
  @spec put_request_context(Req.Request.t(), context()) :: Req.Request.t()
  def put_request_context(%Req.Request{} = request, context) do
    request
    |> Req.Request.put_private(@request_context_key, context)
    |> Req.Request.put_private(:req_llm_request_id, context.request_id)
  end

  @doc """
  Stores telemetry context in a Req response private map.
  """
  @spec put_response_context(Req.Response.t(), context()) :: Req.Response.t()
  def put_response_context(%Req.Response{} = response, context) do
    req_llm_private =
      response.private
      |> Map.get(:req_llm, %{})
      |> Map.put(:request_id, context.request_id)
      |> Map.put(:telemetry, context)

    %{response | private: Map.put(response.private, :req_llm, req_llm_private)}
  end

  @doc """
  Extracts token usage metadata from a Req response private map.
  """
  @spec usage_from_response(any()) :: map() | nil
  def usage_from_response(%Req.Response{private: private}) do
    get_in(private, [:req_llm, :usage])
  end

  def usage_from_response(%Response{usage: usage}) when is_map(usage), do: usage
  def usage_from_response(%{usage: usage}) when is_map(usage), do: usage
  def usage_from_response(_), do: nil

  @doc """
  Returns the normalized request metadata map for request lifecycle events.
  """
  @spec request_metadata(context(), map()) :: map()
  def request_metadata(context, extra) do
    base = %{
      request_id: context.request_id,
      operation: context.operation,
      mode: context.mode,
      provider: context.model.provider,
      model: context.model,
      transport: context.transport,
      reasoning: reasoning_snapshot(context),
      request_summary: context.request_summary,
      response_summary: extra[:response_summary],
      http_status: extra[:http_status],
      finish_reason: extra[:finish_reason],
      usage: extra[:usage]
    }

    base
    |> maybe_put(:request_payload, context.request_payload, include_payloads?(context))
    |> maybe_put(:response_payload, extra[:response_payload], include_payloads?(context))
    |> maybe_put(:error, extra[:error], not is_nil(extra[:error]))
  end

  @doc """
  Returns the normalized metadata map for reasoning lifecycle events.
  """
  @spec reasoning_metadata(context(), map()) :: map()
  def reasoning_metadata(context, extra \\ %{}) do
    %{
      request_id: context.request_id,
      operation: context.operation,
      mode: context.mode,
      provider: context.model.provider,
      model: context.model,
      transport: context.transport,
      reasoning: reasoning_snapshot(context)
    }
    |> maybe_put(:milestone, extra[:milestone], not is_nil(extra[:milestone]))
  end

  defp request_id do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string()
  end

  defp payload_mode(opts) do
    global_payload_mode =
      Application.get_env(:req_llm, :telemetry, [])
      |> normalize_telemetry_opts()
      |> Map.get(:payloads, :none)

    opts
    |> Keyword.get(:telemetry, [])
    |> normalize_telemetry_opts()
    |> Map.get(:payloads, global_payload_mode)
  end

  defp normalize_telemetry_opts(opts) when is_list(opts) do
    opts
    |> Enum.into(%{})
    |> normalize_telemetry_opts()
  end

  defp normalize_telemetry_opts(opts) when is_map(opts) do
    payloads =
      case Map.get(opts, :payloads, Map.get(opts, "payloads", :none)) do
        :raw -> :raw
        "raw" -> :raw
        _ -> :none
      end

    %{payloads: payloads}
  end

  defp normalize_telemetry_opts(_), do: %{payloads: :none}

  defp request_input(:embedding, opts) do
    opts[:text]
  end

  defp request_input(:speech, opts) do
    %{
      text: opts[:text],
      voice: opts[:voice],
      output_format: opts[:output_format],
      language: opts[:language]
    }
  end

  defp request_input(:transcription, opts) do
    %{
      audio_bytes: opts[:audio_bytes],
      media_type: opts[:media_type],
      language: opts[:language]
    }
  end

  defp request_input(_operation, opts) do
    opts[:context] || opts[:messages] || opts[:text]
  end

  defp summarize_request(operation, %Context{} = context)
       when operation in [:chat, :object, :image] do
    context_summary(context)
  end

  defp summarize_request(:embedding, text) do
    texts = List.wrap(text)

    %{
      input_count: length(texts),
      input_bytes: Enum.reduce(texts, 0, &(&2 + byte_size(to_string(&1))))
    }
  end

  defp summarize_request(:speech, input) when is_map(input) do
    %{
      text_bytes: byte_size(to_string(Map.get(input, :text, ""))),
      voice: Map.get(input, :voice),
      output_format: Map.get(input, :output_format),
      language: Map.get(input, :language)
    }
  end

  defp summarize_request(:transcription, input) when is_map(input) do
    %{
      audio_bytes: Map.get(input, :audio_bytes),
      media_type: Map.get(input, :media_type),
      language: Map.get(input, :language)
    }
  end

  defp summarize_request(_operation, input) when is_binary(input) do
    %{text_bytes: byte_size(input)}
  end

  defp summarize_request(_operation, _input), do: %{}

  defp context_summary(%Context{messages: messages}) do
    Enum.reduce(
      messages,
      %{message_count: length(messages), text_bytes: 0, image_part_count: 0, tool_call_count: 0},
      fn
        %Message{} = message, acc ->
          content_acc =
            Enum.reduce(message.content, acc, fn part, inner_acc ->
              case part.type do
                :text ->
                  Map.update!(
                    inner_acc,
                    :text_bytes,
                    &(&1 + byte_size(to_string(part.text || "")))
                  )

                :image ->
                  Map.update!(inner_acc, :image_part_count, &(&1 + 1))

                :image_url ->
                  Map.update!(inner_acc, :image_part_count, &(&1 + 1))

                _ ->
                  inner_acc
              end
            end)

          tool_count = length(message.tool_calls || [])
          Map.update!(content_acc, :tool_call_count, &(&1 + tool_count))

        _, acc ->
          acc
      end
    )
  end

  defp request_payload(_operation, _request_input, :none), do: nil

  defp request_payload(operation, %Context{} = context, :raw)
       when operation in [:chat, :object, :image] do
    sanitize_context(context)
  end

  defp request_payload(:embedding, text, :raw) do
    %{input: List.wrap(text)}
  end

  defp request_payload(:speech, input, :raw) when is_map(input) do
    input
    |> Map.take([:text, :voice, :output_format, :language])
  end

  defp request_payload(:transcription, input, :raw) when is_map(input) do
    input
    |> Map.take([:audio_bytes, :media_type, :language])
  end

  defp request_payload(_operation, input, :raw), do: input

  defp response_payload(_operation, _response, :none), do: nil

  defp response_payload(operation, %Req.Response{body: body}, :raw) do
    response_payload(operation, body, :raw)
  end

  defp response_payload(_operation, %Response{} = response, :raw) do
    sanitize_response(response)
  end

  defp response_payload(:transcription, %ReqLLM.Transcription.Result{} = result, :raw) do
    %{
      text: result.text,
      segments: result.segments,
      language: result.language,
      duration_in_seconds: result.duration_in_seconds
    }
  end

  defp response_payload(:speech, %ReqLLM.Speech.Result{} = result, :raw) do
    %{
      audio_bytes: byte_size(result.audio),
      media_type: result.media_type,
      format: result.format,
      duration_in_seconds: result.duration_in_seconds
    }
  end

  defp response_payload(:speech, audio, :raw) when is_binary(audio) do
    %{audio_bytes: byte_size(audio)}
  end

  defp response_payload(:embedding, body, :raw) when is_map(body) do
    %{
      vector_count: embedding_vector_count(body),
      dimensions: embedding_dimensions(body)
    }
  end

  defp response_payload(:transcription, body, :raw) when is_map(body) do
    summarize_transcription_map(body)
  end

  defp response_payload(_operation, body, :raw), do: body

  defp sanitize_context(%Context{messages: messages, tools: tools}) do
    %{
      messages: Enum.map(messages, &sanitize_message/1),
      tools: tools
    }
  end

  defp sanitize_context(nil), do: nil

  defp sanitize_response(%Response{} = response) do
    %{
      id: response.id,
      model: response.model,
      context: sanitize_context(response.context),
      message: sanitize_message(response.message),
      object: response.object,
      stream?: response.stream?,
      usage: response.usage,
      finish_reason: response.finish_reason,
      provider_meta: response.provider_meta,
      error: response.error
    }
  end

  defp sanitize_message(nil), do: nil

  defp sanitize_message(%Message{} = message) do
    %{
      role: message.role,
      content: Enum.map(message.content, &sanitize_content_part/1),
      name: message.name,
      tool_call_id: message.tool_call_id,
      tool_calls: message.tool_calls,
      metadata: message.metadata,
      reasoning_details: sanitize_reasoning_details(message.reasoning_details)
    }
  end

  defp sanitize_message(other), do: other

  defp sanitize_content_part(%{type: :thinking, text: text} = part) do
    part
    |> Map.from_struct()
    |> Map.put(:text, nil)
    |> Map.put(:redacted?, true)
    |> Map.put(:text_bytes, byte_size(to_string(text || "")))
  end

  defp sanitize_content_part(part) when is_struct(part) do
    Map.from_struct(part)
  end

  defp sanitize_content_part(part), do: part

  defp sanitize_reasoning_details(nil), do: nil

  defp sanitize_reasoning_details(details) when is_list(details) do
    Enum.map(details, fn
      %{text: text} = detail when is_struct(detail) ->
        detail
        |> Map.from_struct()
        |> Map.put(:text, nil)
        |> Map.put(:redacted?, true)
        |> Map.put(:text_bytes, byte_size(to_string(text || "")))

      %{text: text} = detail ->
        detail
        |> Map.put(:text, nil)
        |> Map.put(:redacted?, true)
        |> Map.put(:text_bytes, byte_size(to_string(text || "")))

      detail ->
        detail
    end)
  end

  defp sanitize_reasoning_details(details), do: details

  defp summarize_response(_operation, %Response{} = response) do
    %{
      text_bytes: byte_size(Response.text(response) || ""),
      thinking_bytes: byte_size(Response.thinking(response) || ""),
      tool_call_count: length(Response.tool_calls(response)),
      image_count: length(Response.images(response)),
      object?: is_map(response.object)
    }
  end

  defp summarize_response(:embedding, body) when is_map(body) do
    %{
      vector_count: embedding_vector_count(body),
      dimensions: embedding_dimensions(body)
    }
  end

  defp summarize_response(:transcription, %ReqLLM.Transcription.Result{} = result) do
    %{
      text_bytes: byte_size(result.text || ""),
      segment_count: length(result.segments || []),
      duration_in_seconds: result.duration_in_seconds
    }
  end

  defp summarize_response(:transcription, body) when is_map(body) do
    summarize_transcription_map(body)
  end

  defp summarize_response(:speech, %ReqLLM.Speech.Result{} = result) do
    %{
      audio_bytes: byte_size(result.audio || <<>>),
      media_type: result.media_type,
      format: result.format,
      duration_in_seconds: result.duration_in_seconds
    }
  end

  defp summarize_response(:speech, audio) when is_binary(audio) do
    %{audio_bytes: byte_size(audio)}
  end

  defp summarize_response(_operation, _response), do: %{}

  defp summarize_transcription_map(body) do
    %{
      text_bytes: byte_size(to_string(fetch_value(body, :text) || "")),
      segment_count: length(fetch_value(body, :segments) || []),
      duration_in_seconds:
        fetch_value(body, :duration_in_seconds) || fetch_value(body, :duration) ||
          fetch_value(body, :audio_duration)
    }
  end

  defp embedding_vector_count(%{"data" => data}) when is_list(data), do: length(data)
  defp embedding_vector_count(%{data: data}) when is_list(data), do: length(data)
  defp embedding_vector_count(_), do: nil

  defp embedding_dimensions(%{"data" => [%{"embedding" => embedding} | _]})
       when is_list(embedding) do
    length(embedding)
  end

  defp embedding_dimensions(%{data: [%{embedding: embedding} | _]}) when is_list(embedding) do
    length(embedding)
  end

  defp embedding_dimensions(_), do: nil

  defp requested_reasoning(%LLMDB.Model{} = model, operation, opts) do
    supported? = operation in [:chat, :object] and ModelHelpers.reasoning_enabled?(model)
    mode = requested_reasoning_mode(opts)
    effort = requested_reasoning_effort(opts)
    budget_tokens = requested_reasoning_budget(opts)

    %{
      supported?: supported?,
      requested?: mode == :enabled,
      effective?: false,
      requested_mode: mode,
      requested_effort: effort,
      requested_budget_tokens: budget_tokens,
      effective_mode: :disabled,
      effective_effort: nil,
      effective_budget_tokens: nil
    }
  end

  defp disable_effective_reasoning(requested_reasoning) do
    requested_reasoning
    |> Map.put(:effective?, false)
    |> Map.put(:effective_mode, :disabled)
    |> Map.put(:effective_effort, nil)
    |> Map.put(:effective_budget_tokens, nil)
  end

  defp effective_reasoning(model, operation, request_source) do
    supported? = operation in [:chat, :object] and ModelHelpers.reasoning_enabled?(model)
    source = request_body_source(request_source)
    mode = effective_reasoning_mode(source)
    effort = effective_reasoning_effort(source)
    budget_tokens = effective_reasoning_budget(source)

    %{
      supported?: supported?,
      requested?: false,
      effective?: supported? and mode == :enabled,
      requested_mode: :disabled,
      requested_effort: nil,
      requested_budget_tokens: nil,
      effective_mode: if(supported?, do: mode, else: :disabled),
      effective_effort: effort,
      effective_budget_tokens: budget_tokens
    }
  end

  defp request_body_source(%Req.Request{body: body}), do: decode_json_body(body)
  defp request_body_source(body), do: decode_json_body(body)

  defp decode_json_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode_json_body(body), do: body

  defp requested_reasoning_mode(opts) do
    cond do
      explicit_disabled_reasoning?(opts) -> :disabled
      explicit_enabled_reasoning?(opts) -> :enabled
      true -> :disabled
    end
  end

  defp requested_reasoning_effort(opts) do
    opts[:reasoning_effort] ||
      fetch_value(opts[:provider_options], :reasoning_effort) ||
      nil
  end

  defp requested_reasoning_budget(opts) do
    opts[:reasoning_token_budget] ||
      fetch_value(opts[:thinking], :budget_tokens) ||
      fetch_value(opts[:provider_options], :google_thinking_budget) ||
      fetch_value(opts[:provider_options], :thinking_budget) ||
      fetch_value(opts[:provider_options], :reasoning_token_budget) ||
      fetch_value(opts[:provider_options], :thinking, :budget_tokens) ||
      fetch_value(
        opts[:provider_options],
        :additional_model_request_fields,
        :thinking,
        :budget_tokens
      )
  end

  defp explicit_enabled_reasoning?(opts) do
    reasoning_effort = requested_reasoning_effort(opts)

    cond do
      reasoning_effort in [
        :minimal,
        :low,
        :medium,
        :high,
        :xhigh,
        "minimal",
        "low",
        "medium",
        "high",
        "xhigh"
      ] ->
        true

      reasoning_effort not in [nil, :none, "none"] ->
        true

      fetch_value(opts[:thinking], :type) == "enabled" ->
        true

      fetch_value(opts[:provider_options], :thinking, :type) == "enabled" ->
        true

      is_integer(requested_reasoning_budget(opts)) and requested_reasoning_budget(opts) > 0 ->
        true

      fetch_value(opts[:provider_options], :enable_thinking) == true ->
        true

      true ->
        false
    end
  end

  defp explicit_disabled_reasoning?(opts) do
    requested_reasoning_effort(opts) in [:none, "none"] or
      fetch_value(opts[:thinking], :type) == "disabled" or
      fetch_value(opts[:provider_options], :thinking, :type) == "disabled" or
      fetch_value(opts[:provider_options], :enable_thinking) == false or
      requested_reasoning_budget(opts) == 0
  end

  defp effective_reasoning_mode(body) when is_map(body) do
    cond do
      fetch_value(body, :reasoning, :effort) not in [nil, :none, "none"] ->
        :enabled

      fetch_value(body, :reasoning_effort) not in [nil, :none, "none"] ->
        :enabled

      fetch_value(body, :thinking, :type) == "enabled" ->
        :enabled

      fetch_value(body, :generationConfig, :thinkingConfig, :thinkingBudget)
      |> enabled_budget?() ->
        :enabled

      fetch_value(body, :additionalModelRequestFields, :thinking, :type) == "enabled" ->
        :enabled

      fetch_value(body, :additional_model_request_fields, :thinking, :type) == "enabled" ->
        :enabled

      fetch_value(body, :enable_thinking) == true ->
        :enabled

      effective_disabled_reasoning?(body) ->
        :disabled

      true ->
        :disabled
    end
  end

  defp effective_reasoning_mode(_), do: :disabled

  defp effective_reasoning_effort(body) when is_map(body) do
    fetch_value(body, :reasoning, :effort) ||
      fetch_value(body, :reasoning_effort)
  end

  defp effective_reasoning_effort(_), do: nil

  defp effective_reasoning_budget(body) when is_map(body) do
    fetch_value(body, :thinking, :budget_tokens) ||
      fetch_value(body, :generationConfig, :thinkingConfig, :thinkingBudget) ||
      fetch_value(body, :additionalModelRequestFields, :thinking, :budget_tokens) ||
      fetch_value(body, :additional_model_request_fields, :thinking, :budget_tokens) ||
      fetch_value(body, :thinking_budget)
  end

  defp effective_reasoning_budget(_), do: nil

  defp effective_disabled_reasoning?(body) do
    fetch_value(body, :reasoning, :effort) in [:none, "none"] or
      fetch_value(body, :reasoning_effort) in [:none, "none"] or
      fetch_value(body, :thinking, :type) == "disabled" or
      fetch_value(body, :generationConfig, :thinkingConfig, :thinkingBudget) == 0 or
      fetch_value(body, :enable_thinking) == false
  end

  defp enabled_budget?(budget) when is_integer(budget), do: budget > 0
  defp enabled_budget?(_), do: false

  defp new_reasoning_observation do
    %{
      returned_content?: false,
      content_bytes: 0,
      reasoning_tokens: 0,
      details_available?: false,
      content_update_emitted?: false,
      details_update_emitted?: false,
      last_reasoning_tokens: nil
    }
  end

  defp new_response_summary_state(:chat) do
    %{text_bytes: 0, thinking_bytes: 0, tool_call_count: 0, image_count: 0, object?: false}
  end

  defp new_response_summary_state(:object) do
    %{text_bytes: 0, thinking_bytes: 0, tool_call_count: 0, image_count: 0, object?: false}
  end

  defp new_response_summary_state(:image) do
    %{text_bytes: 0, thinking_bytes: 0, tool_call_count: 0, image_count: 0, object?: false}
  end

  defp new_response_summary_state(:embedding), do: %{}
  defp new_response_summary_state(:transcription), do: %{}
  defp new_response_summary_state(:speech), do: %{}
  defp new_response_summary_state(_), do: %{}

  defp reasoning_enabled?(context) do
    context.effective_reasoning[:supported?] and context.effective_reasoning[:effective?]
  end

  defp reasoning_snapshot(context) do
    requested = context.requested_reasoning
    effective = context.effective_reasoning
    observation = context.reasoning_observation

    %{
      supported?: requested[:supported?],
      requested?: requested[:requested?],
      effective?: effective[:effective?],
      requested_mode: requested[:requested_mode],
      requested_effort: requested[:requested_effort],
      requested_budget_tokens: requested[:requested_budget_tokens],
      effective_mode: effective[:effective_mode],
      effective_effort: effective[:effective_effort],
      effective_budget_tokens: effective[:effective_budget_tokens],
      returned_content?: observation[:returned_content?],
      reasoning_tokens: observation[:reasoning_tokens],
      content_bytes: observation[:content_bytes],
      channel: reasoning_channel(observation)
    }
  end

  defp reasoning_channel(%{returned_content?: true, reasoning_tokens: tokens}) when tokens > 0,
    do: :content_and_usage

  defp reasoning_channel(%{returned_content?: true}), do: :content_only
  defp reasoning_channel(%{reasoning_tokens: tokens}) when tokens > 0, do: :usage_only
  defp reasoning_channel(_), do: :none

  defp ensure_started(%{request_started?: true} = context, _request_source), do: context
  defp ensure_started(context, request_source), do: start_request(context, request_source)

  defp stop_measurements(%{started_at: nil}) do
    %{duration: 0, system_time: System.system_time()}
  end

  defp stop_measurements(context) do
    %{duration: System.monotonic_time() - context.started_at, system_time: System.system_time()}
  end

  defp maybe_emit_reasoning_stop(%{reasoning_started?: false}, _finish_reason), do: :ok

  defp maybe_emit_reasoning_stop(context, finish_reason) do
    duration =
      case context.reasoning_started_at do
        nil -> 0
        started_at -> System.monotonic_time() - started_at
      end

    :telemetry.execute(
      @reasoning_stop_event,
      %{duration: duration, system_time: System.system_time()},
      reasoning_metadata(context, %{milestone: finish_reason})
    )
  end

  defp observe_stream_chunk_reasoning(context, %ReqLLM.StreamChunk{
         type: :thinking,
         text: text,
         metadata: metadata
       }) do
    context
    |> observe_reasoning_content(text)
    |> observe_reasoning_details(metadata)
  end

  defp observe_stream_chunk_reasoning(context, %ReqLLM.StreamChunk{
         type: :meta,
         metadata: metadata
       }) do
    context
    |> observe_reasoning_usage(fetch_value(metadata, :usage))
    |> observe_reasoning_details(fetch_value(metadata, :reasoning_details))
  end

  defp observe_stream_chunk_reasoning(context, %ReqLLM.StreamChunk{metadata: metadata}) do
    observe_reasoning_details(context, metadata)
  end

  defp observe_reasoning_from_response(context, %Response{} = response) do
    context
    |> observe_reasoning_content(Response.thinking(response))
    |> observe_reasoning_usage(response.usage)
    |> observe_reasoning_details(response.message && response.message.reasoning_details)
  end

  defp observe_reasoning_from_response(context, %{reasoning_details: details})
       when not is_nil(details) do
    observe_reasoning_details(context, details)
  end

  defp observe_reasoning_from_response(context, _response), do: context

  defp observe_error_reasoning(context, %{response_body: response_body}) do
    observe_reasoning_from_response(context, response_body)
  end

  defp observe_error_reasoning(context, _error), do: context

  defp observe_reasoning_content(context, nil), do: context

  defp observe_reasoning_content(context, text) do
    bytes = byte_size(to_string(text))

    observation =
      context.reasoning_observation
      |> Map.update!(:content_bytes, &(&1 + bytes))
      |> Map.put(
        :returned_content?,
        bytes > 0 or context.reasoning_observation[:returned_content?]
      )

    context = %{context | reasoning_observation: observation}

    if reasoning_enabled?(context) and bytes > 0 and not observation[:content_update_emitted?] do
      :telemetry.execute(
        @reasoning_update_event,
        %{system_time: System.system_time()},
        reasoning_metadata(context, %{milestone: :content_started})
      )

      %{
        context
        | reasoning_observation:
            Map.put(context.reasoning_observation, :content_update_emitted?, true)
      }
    else
      context
    end
  end

  defp observe_reasoning_usage(context, nil), do: context

  defp observe_reasoning_usage(context, usage) do
    reasoning_tokens = extract_reasoning_tokens(usage)
    previous = context.reasoning_observation.last_reasoning_tokens

    observation =
      context.reasoning_observation
      |> Map.put(
        :reasoning_tokens,
        max(reasoning_tokens, context.reasoning_observation.reasoning_tokens)
      )
      |> Map.put(:last_reasoning_tokens, reasoning_tokens)

    context = %{context | reasoning_observation: observation}

    if reasoning_enabled?(context) and reasoning_tokens > 0 and reasoning_tokens != previous do
      :telemetry.execute(
        @reasoning_update_event,
        %{system_time: System.system_time()},
        reasoning_metadata(context, %{milestone: :usage_updated})
      )

      context
    else
      context
    end
  end

  defp observe_reasoning_details(context, nil), do: context

  defp observe_reasoning_details(context, details) do
    available? =
      case details do
        [] -> false
        %{} -> map_size(details) > 0
        _ -> true
      end

    observation =
      context.reasoning_observation
      |> Map.put(
        :details_available?,
        context.reasoning_observation[:details_available?] or available?
      )

    context = %{context | reasoning_observation: observation}

    if reasoning_enabled?(context) and available? and not observation[:details_update_emitted?] do
      :telemetry.execute(
        @reasoning_update_event,
        %{system_time: System.system_time()},
        reasoning_metadata(context, %{milestone: :details_available})
      )

      %{
        context
        | reasoning_observation:
            Map.put(context.reasoning_observation, :details_update_emitted?, true)
      }
    else
      context
    end
  end

  defp update_response_summary_state(context, %ReqLLM.StreamChunk{type: :content, text: text}) do
    update_in(
      context.response_summary_state.text_bytes,
      &((&1 || 0) + byte_size(to_string(text || "")))
    )
  end

  defp update_response_summary_state(context, %ReqLLM.StreamChunk{type: :thinking, text: text}) do
    update_in(
      context.response_summary_state.thinking_bytes,
      &((&1 || 0) + byte_size(to_string(text || "")))
    )
  end

  defp update_response_summary_state(context, %ReqLLM.StreamChunk{type: :tool_call}) do
    update_in(context.response_summary_state.tool_call_count, &((&1 || 0) + 1))
  end

  defp update_response_summary_state(context, %ReqLLM.StreamChunk{type: :meta, metadata: metadata}) do
    finish_reason = finish_reason_from_response(metadata)

    context
    |> maybe_mark_stream_object(metadata)
    |> maybe_put_response_summary(:finish_reason, finish_reason)
  end

  defp update_response_summary_state(context, _chunk), do: context

  defp maybe_mark_stream_object(context, metadata) do
    if fetch_value(metadata, :structured_output) || fetch_value(metadata, :object) do
      maybe_put_response_summary(context, :object?, true)
    else
      context
    end
  end

  defp maybe_put_response_summary(context, _key, nil), do: context

  defp maybe_put_response_summary(context, key, value) do
    %{context | response_summary_state: Map.put(context.response_summary_state, key, value)}
  end

  defp response_summary(summary_state, _operation), do: summary_state || %{}

  defp merge_response_summary(existing, incoming) when map_size(incoming) == 0, do: existing
  defp merge_response_summary(existing, incoming), do: Map.merge(existing, incoming)

  defp finish_reason_from_state(summary_state) when is_map(summary_state) do
    summary_state[:finish_reason]
  end

  defp finish_reason_from_state(_), do: nil

  defp finish_reason_from_response(%Req.Response{body: body}),
    do: finish_reason_from_response(body)

  defp finish_reason_from_response(%Response{} = response),
    do: normalize_finish_reason(response.finish_reason)

  defp finish_reason_from_response(body) when is_map(body) do
    fetch_value(body, :finish_reason)
    |> normalize_finish_reason()
  end

  defp finish_reason_from_response(_), do: nil

  defp http_status_from_response(%Req.Response{status: status}), do: status
  defp http_status_from_response(%{status: status}) when is_integer(status), do: status
  defp http_status_from_response(_), do: nil

  defp http_status_from_error(%{status: status}) when is_integer(status), do: status
  defp http_status_from_error(_), do: nil

  defp normalize_finish_reason(reason)
       when reason in [
              :stop,
              :length,
              :tool_calls,
              :content_filter,
              :error,
              :cancelled,
              :incomplete,
              :unknown
            ],
       do: reason

  defp normalize_finish_reason("stop"), do: :stop
  defp normalize_finish_reason("length"), do: :length
  defp normalize_finish_reason("tool_calls"), do: :tool_calls
  defp normalize_finish_reason("tool_use"), do: :tool_calls
  defp normalize_finish_reason("content_filter"), do: :content_filter
  defp normalize_finish_reason("cancelled"), do: :cancelled
  defp normalize_finish_reason("incomplete"), do: :incomplete
  defp normalize_finish_reason("error"), do: :error
  defp normalize_finish_reason(_), do: nil

  defp extract_reasoning_tokens(nil), do: nil

  defp extract_reasoning_tokens(%{tokens: tokens}) when is_map(tokens) do
    extract_reasoning_tokens(tokens)
  end

  defp extract_reasoning_tokens(usage) when is_map(usage) do
    usage[:reasoning] ||
      usage["reasoning"] ||
      usage[:reasoning_tokens] ||
      usage["reasoning_tokens"] ||
      fetch_value(usage, :completion_tokens_details, :reasoning_tokens) ||
      fetch_value(usage, :output_tokens_details, :reasoning_tokens) ||
      0
  end

  defp token_usage_measurements(%{tokens: _tokens} = usage) do
    usage
  end

  defp token_usage_measurements(usage) when is_map(usage) do
    %{
      tokens: usage,
      cost: usage[:total_cost] || usage["total_cost"]
    }
    |> maybe_put(:input_cost, usage[:input_cost] || usage["input_cost"])
    |> maybe_put(:output_cost, usage[:output_cost] || usage["output_cost"])
    |> maybe_put(:reasoning_cost, usage[:reasoning_cost] || usage["reasoning_cost"])
    |> maybe_put(:total_cost, usage[:total_cost] || usage["total_cost"])
  end

  defp token_usage_measurements(_), do: %{tokens: %{}, cost: nil}

  defp fetch_value(data, key) do
    cond do
      is_map(data) ->
        Map.get(data, key) || Map.get(data, Atom.to_string(key))

      Keyword.keyword?(data) ->
        Keyword.get(data, key)

      true ->
        nil
    end
  end

  defp fetch_value(data, key1, key2) do
    data
    |> fetch_value(key1)
    |> fetch_value(key2)
  end

  defp fetch_value(data, key1, key2, key3) do
    data
    |> fetch_value(key1)
    |> fetch_value(key2)
    |> fetch_value(key3)
  end

  defp maybe_put(map, _key, _value, false), do: map

  defp maybe_put(map, key, value, true) do
    Map.put(map, key, value)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp include_payloads?(context), do: context.payload_mode == :raw
end

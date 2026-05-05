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

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ModelHelpers
  alias ReqLLM.RerankResponse
  alias ReqLLM.Response
  alias ReqLLM.Tool

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
  @type reasoning_contract ::
          :openai_effort
          | :openai_or_thinking
          | :anthropic_thinking
          | :platform_anthropic
          | :google_budget
          | :alibaba_thinking
          | :thinking_toggle
          | :zenmux_reasoning
          | :unsupported

  @reasoning_operations [:chat, :object]
  @canonical_reasoning_efforts [:minimal, :low, :medium, :high, :xhigh, :default]
  @openai_reasoning_providers [:openai, :groq, :openrouter, :xai]
  @thinking_toggle_providers [:zai, :zai_coder]
  @alibaba_providers [:alibaba, :alibaba_cn]

  @type context :: %{
          request_id: String.t(),
          model: LLMDB.Model.t(),
          operation: atom(),
          mode: lifecycle_mode(),
          transport: transport(),
          payload_mode: payload_mode(),
          reasoning_contract: reasoning_contract(),
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

    reasoning_contract =
      Keyword.get(extra, :reasoning_contract, reasoning_contract_for(model, opts))

    payload_mode = payload_mode(opts)
    request_input = request_input(operation, opts)
    requested_reasoning = requested_reasoning(model, operation, opts, reasoning_contract)

    %{
      request_id: request_id(),
      model: model,
      operation: operation,
      mode: mode,
      transport: transport,
      payload_mode: payload_mode,
      reasoning_contract: reasoning_contract,
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

  @doc false
  @spec reasoning_contract_for(LLMDB.Model.t(), keyword(), any()) :: reasoning_contract()
  def reasoning_contract_for(%LLMDB.Model{} = model, opts \\ [], request_source \\ nil) do
    Keyword.get(opts, :telemetry_reasoning_contract) ||
      request_reasoning_contract(request_source, model) ||
      reasoning_contract(model)
  end

  @doc """
  Emits request start telemetry and returns the updated context.
  """
  @spec start_request(context(), any()) :: context()
  def start_request(%{request_started?: true} = context, _request_source), do: context

  def start_request(context, request_source) do
    now = System.monotonic_time()
    measurement = %{system_time: System.system_time()}

    reasoning_contract =
      reasoning_contract_for(context.model, context.original_opts, request_source)

    requested_reasoning =
      requested_reasoning(
        context.model,
        context.operation,
        context.original_opts,
        reasoning_contract
      )

    effective_reasoning =
      effective_reasoning(
        context.model,
        context.operation,
        request_source,
        reasoning_contract
      )

    context =
      context
      |> Map.put(:request_started?, true)
      |> Map.put(:started_at, now)
      |> Map.put(:request_measurement, measurement)
      |> Map.put(:reasoning_contract, reasoning_contract)
      |> Map.put(:requested_reasoning, requested_reasoning)
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

    case Keyword.fetch(opts, :telemetry) do
      {:ok, telemetry_opts} ->
        telemetry_opts
        |> normalize_telemetry_opts()
        |> Map.get(:payloads, :none)

      :error ->
        global_payload_mode
    end
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

  defp request_input(:rerank, opts) do
    %{
      query: opts[:query],
      documents: opts[:documents]
    }
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

  defp summarize_request(:rerank, input) when is_map(input) do
    documents = List.wrap(Map.get(input, :documents))
    query = to_string(Map.get(input, :query, ""))

    %{
      document_count: length(documents),
      query_bytes: byte_size(query),
      document_bytes: Enum.reduce(documents, 0, &(&2 + byte_size(&1)))
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

  defp request_payload(:rerank, input, :raw) when is_map(input) do
    %{
      query: Map.get(input, :query),
      documents: List.wrap(Map.get(input, :documents))
    }
  end

  defp request_payload(:speech, input, :raw) when is_map(input) do
    input
    |> Map.take([:text, :voice, :output_format, :language])
  end

  defp request_payload(:transcription, input, :raw) when is_map(input) do
    input
    |> Map.take([:audio_bytes, :media_type, :language])
  end

  defp request_payload(_operation, input, :raw), do: sanitize_generic_payload(input)

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

  defp response_payload(_operation, body, :raw), do: sanitize_generic_payload(body)

  defp sanitize_context(%Context{messages: messages, tools: tools}) do
    %{
      messages: Enum.map(messages, &sanitize_message/1),
      tools: Enum.map(List.wrap(tools), &sanitize_tool/1)
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

  defp sanitize_tool(%Tool{} = tool) do
    %{
      name: tool.name,
      description: tool.description,
      strict: tool.strict,
      parameter_schema: sanitize_tool_schema(tool.parameter_schema)
    }
  end

  defp sanitize_tool(%{name: name, description: description} = tool) do
    %{
      name: name,
      description: description,
      strict: Map.get(tool, :strict, false),
      parameter_schema:
        sanitize_tool_schema(Map.get(tool, :parameter_schema) || Map.get(tool, :input_schema))
    }
  end

  defp sanitize_tool(tool), do: tool

  defp sanitize_tool_schema(schema) when is_struct(schema) do
    schema
    |> Map.from_struct()
    |> sanitize_tool_schema()
  end

  defp sanitize_tool_schema(schema) when is_list(schema) do
    if Keyword.keyword?(schema) do
      Map.new(schema, fn {key, value} -> {key, sanitize_tool_schema(value)} end)
    else
      Enum.map(schema, &sanitize_tool_schema/1)
    end
  end

  defp sanitize_tool_schema(schema) when is_map(schema) do
    Map.new(schema, fn {key, value} -> {key, sanitize_tool_schema(value)} end)
  end

  defp sanitize_tool_schema(schema), do: schema

  defp sanitize_generic_payload(%Response{} = response), do: sanitize_response(response)
  defp sanitize_generic_payload(%Context{} = context), do: sanitize_context(context)
  defp sanitize_generic_payload(%Message{} = message), do: sanitize_message(message)
  defp sanitize_generic_payload(%Tool{} = tool), do: sanitize_tool(tool)
  defp sanitize_generic_payload(%ContentPart{} = part), do: sanitize_content_part(part)

  defp sanitize_generic_payload(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> sanitize_generic_payload()
  end

  defp sanitize_generic_payload(value) when is_map(value) do
    Map.new(value, fn {key, entry} -> {key, sanitize_generic_payload(entry)} end)
  end

  defp sanitize_generic_payload(value) when is_list(value) do
    Enum.map(value, &sanitize_generic_payload/1)
  end

  defp sanitize_generic_payload(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      %{bytes: byte_size(value)}
    end
  end

  defp sanitize_generic_payload(value), do: value

  defp sanitize_content_part(%ContentPart{type: :thinking, text: text} = part) do
    part
    |> Map.from_struct()
    |> Map.put(:text, nil)
    |> Map.put(:redacted?, true)
    |> Map.put(:text_bytes, byte_size(to_string(text || "")))
  end

  defp sanitize_content_part(%{type: :thinking, text: text} = part) when is_map(part) do
    part
    |> Map.put(:text, nil)
    |> Map.put(:redacted?, true)
    |> Map.put(:text_bytes, byte_size(to_string(text || "")))
  end

  defp sanitize_content_part(%ContentPart{type: :image} = part) do
    %{
      type: :image,
      media_type: part.media_type,
      bytes: binary_size_or_nil(part.data),
      metadata: part.metadata
    }
  end

  defp sanitize_content_part(%ContentPart{type: :file} = part) do
    %{
      type: :file,
      file_id: part.file_id,
      filename: part.filename,
      media_type: part.media_type,
      bytes: binary_size_or_nil(part.data),
      metadata: part.metadata
    }
  end

  defp sanitize_content_part(%{type: :image} = part) when is_map(part) do
    %{
      type: part.type,
      media_type: part[:media_type],
      bytes: binary_size_or_nil(part[:data]),
      metadata: Map.get(part, :metadata, %{})
    }
  end

  defp sanitize_content_part(%{type: :file} = part) when is_map(part) do
    %{
      type: Map.get(part, :type) || Map.get(part, "type"),
      file_id: Map.get(part, :file_id) || Map.get(part, "file_id"),
      filename: Map.get(part, :filename) || Map.get(part, "filename"),
      media_type: Map.get(part, :media_type) || Map.get(part, "media_type"),
      bytes: binary_size_or_nil(Map.get(part, :data) || Map.get(part, "data")),
      metadata: Map.get(part, :metadata) || Map.get(part, "metadata", %{})
    }
  end

  defp sanitize_content_part(part) when is_struct(part) do
    Map.from_struct(part)
  end

  defp sanitize_content_part(part), do: part

  defp binary_size_or_nil(nil), do: nil
  defp binary_size_or_nil(data) when is_binary(data), do: byte_size(data)
  defp binary_size_or_nil(data) when is_list(data), do: IO.iodata_length(data)
  defp binary_size_or_nil(_data), do: nil

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

  defp summarize_response(:rerank, %RerankResponse{results: results}) do
    %{
      result_count: length(results),
      top_score: results |> List.first() |> then(&if &1, do: &1.relevance_score, else: nil)
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

  defp requested_reasoning(%LLMDB.Model{} = model, operation, opts, contract) do
    supported? = reasoning_supported?(model, operation)

    %{mode: mode, effort: effort, budget_tokens: budget_tokens} =
      normalize_requested_reasoning(contract, opts)

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

  defp effective_reasoning(model, operation, request_source, contract) do
    supported? = reasoning_supported?(model, operation)
    source = request_body_source(request_source)

    %{mode: mode, effort: effort, budget_tokens: budget_tokens} =
      normalize_effective_reasoning(contract, source)

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

  defp normalize_requested_reasoning(contract, opts) do
    case contract do
      :openai_effort ->
        normalize_effort_requested(opts)

      :openai_or_thinking ->
        normalize_openai_or_thinking_requested(opts)

      :anthropic_thinking ->
        normalize_thinking_requested(opts)

      :platform_anthropic ->
        normalize_platform_anthropic_requested(opts)

      :google_budget ->
        normalize_google_requested(opts)

      :alibaba_thinking ->
        normalize_alibaba_requested(opts)

      :thinking_toggle ->
        normalize_thinking_toggle_requested(opts)

      :zenmux_reasoning ->
        normalize_zenmux_requested(opts)

      :unsupported ->
        disabled_reasoning_shape()
    end
  end

  defp normalize_effective_reasoning(contract, body) do
    case contract do
      :openai_effort ->
        normalize_effort_effective(body)

      :openai_or_thinking ->
        normalize_openai_or_thinking_effective(body)

      :anthropic_thinking ->
        normalize_thinking_effective(body)

      :platform_anthropic ->
        normalize_platform_anthropic_effective(body)

      :google_budget ->
        normalize_google_effective(body)

      :alibaba_thinking ->
        normalize_alibaba_effective(body)

      :thinking_toggle ->
        normalize_thinking_toggle_effective(body)

      :zenmux_reasoning ->
        normalize_zenmux_effective(body)

      :unsupported ->
        disabled_reasoning_shape()
    end
  end

  defp normalize_effort_requested(opts) do
    effort =
      normalize_reasoning_effort(
        opts[:reasoning_effort] ||
          fetch_value(opts[:provider_options], :reasoning_effort)
      )

    disable? = effort == :none
    enable? = effort in @canonical_reasoning_efforts

    reasoning_shape(mode_from_signals(enable?, disable?), effort, nil, enable? or disable?)
  end

  defp normalize_openai_or_thinking_requested(opts) do
    shape = normalize_effort_requested(opts)

    if shape.mode == :enabled do
      shape
    else
      merge_reasoning_shapes(shape, normalize_platform_anthropic_requested(opts))
    end
  end

  defp normalize_thinking_requested(opts) do
    thinking =
      opts[:thinking] ||
        fetch_value(opts[:provider_options], :thinking)

    effort =
      normalize_reasoning_effort(
        opts[:reasoning_effort] ||
          fetch_value(opts[:provider_options], :reasoning_effort)
      )

    budget_tokens =
      opts[:reasoning_token_budget] ||
        fetch_value(thinking, :budget_tokens) ||
        fetch_value(opts[:provider_options], :reasoning_token_budget)

    disable? =
      effort == :none or
        fetch_value(thinking, :type) == "disabled" or
        budget_tokens == 0

    enable? =
      effort in @canonical_reasoning_efforts or
        fetch_value(thinking, :type) == "enabled" or
        enabled_budget?(budget_tokens)

    reasoning_shape(
      mode_from_signals(enable?, disable?),
      effort,
      normalize_budget(budget_tokens),
      enable? or disable?
    )
  end

  defp normalize_platform_anthropic_requested(opts) do
    shape = normalize_thinking_requested(opts)

    if shape.mode == :enabled do
      shape
    else
      additional_thinking =
        fetch_value(opts[:provider_options], :additional_model_request_fields, :thinking)

      budget_tokens = fetch_value(additional_thinking, :budget_tokens)

      disable? =
        fetch_value(additional_thinking, :type) == "disabled" or
          budget_tokens == 0

      enable? =
        fetch_value(additional_thinking, :type) == "enabled" or
          enabled_budget?(budget_tokens)

      merge_reasoning_shapes(
        shape,
        reasoning_shape(
          mode_from_signals(enable?, disable?),
          nil,
          normalize_budget(budget_tokens),
          enable? or disable?
        )
      )
    end
  end

  defp normalize_google_requested(opts) do
    budget_tokens =
      opts[:google_thinking_budget] ||
        fetch_value(opts[:provider_options], :google_thinking_budget) ||
        fetch_value(opts[:provider_options], :thinking_budget)

    google_thinking_level =
      opts[:google_thinking_level] ||
        fetch_value(opts[:provider_options], :google_thinking_level)

    effort =
      case google_thinking_level do
        nil ->
          normalize_reasoning_effort(
            opts[:reasoning_effort] ||
              fetch_value(opts[:provider_options], :reasoning_effort)
          )

        level ->
          thinking_level_to_effort(level)
      end

    disable? = budget_tokens == 0 or effort == :none
    enable? = enabled_budget?(budget_tokens) or effort in @canonical_reasoning_efforts

    reasoning_shape(
      mode_from_signals(enable?, disable?),
      effort,
      normalize_budget(budget_tokens),
      enable? or disable?
    )
  end

  defp normalize_alibaba_requested(opts) do
    provider_opts = opts[:provider_options] || []
    budget_tokens = first_present(opts, :thinking_budget, provider_opts, :thinking_budget)
    enabled? = first_present(opts, :enable_thinking, provider_opts, :enable_thinking)
    disable? = enabled? == false or budget_tokens == 0
    enable? = enabled? == true or enabled_budget?(budget_tokens)

    reasoning_shape(
      mode_from_signals(enable?, disable?),
      nil,
      normalize_budget(budget_tokens),
      enable? or disable?
    )
  end

  defp normalize_thinking_toggle_requested(opts) do
    thinking =
      opts[:thinking] ||
        fetch_value(opts[:provider_options], :thinking)

    disable? = fetch_value(thinking, :type) == "disabled"
    enable? = fetch_value(thinking, :type) == "enabled"

    reasoning_shape(mode_from_signals(enable?, disable?), nil, nil, enable? or disable?)
  end

  defp normalize_zenmux_requested(opts) do
    provider_opts = opts[:provider_options] || []
    reasoning = opts[:reasoning] || fetch_value(provider_opts, :reasoning)

    effort =
      normalize_reasoning_effort(
        opts[:reasoning_effort] || fetch_value(provider_opts, :reasoning_effort)
      )

    depth_effort =
      normalize_reasoning_effort(fetch_value(reasoning, :depth))

    disable? =
      fetch_value(reasoning, :enable) == false or
        effort == :none

    enable? =
      fetch_value(reasoning, :enable) == true or
        depth_effort in @canonical_reasoning_efforts or
        effort in @canonical_reasoning_efforts

    effective_effort =
      depth_effort ||
        effort

    reasoning_shape(
      mode_from_signals(enable?, disable?),
      effective_effort,
      nil,
      enable? or disable?
    )
  end

  defp normalize_effort_effective(body) when is_map(body) do
    effort =
      normalize_reasoning_effort(
        fetch_value(body, :reasoning, :effort) ||
          fetch_value(body, :reasoning_effort)
      )

    disable? = effort == :none
    enable? = effort in @canonical_reasoning_efforts

    reasoning_shape(mode_from_signals(enable?, disable?), effort, nil, enable? or disable?)
  end

  defp normalize_effort_effective(_body), do: disabled_reasoning_shape()

  defp normalize_openai_or_thinking_effective(body) do
    shape = normalize_effort_effective(body)

    if shape.mode == :enabled do
      shape
    else
      merge_reasoning_shapes(shape, normalize_platform_anthropic_effective(body))
    end
  end

  defp normalize_thinking_effective(body) when is_map(body) do
    thinking = fetch_value(body, :thinking)
    budget_tokens = fetch_value(thinking, :budget_tokens)

    disable? =
      fetch_value(thinking, :type) == "disabled" or
        budget_tokens == 0

    enable? =
      fetch_value(thinking, :type) == "enabled" or
        enabled_budget?(budget_tokens)

    reasoning_shape(
      mode_from_signals(enable?, disable?),
      nil,
      normalize_budget(budget_tokens),
      enable? or disable?
    )
  end

  defp normalize_thinking_effective(_body), do: disabled_reasoning_shape()

  defp normalize_platform_anthropic_effective(body) do
    shape = normalize_thinking_effective(body)

    if shape.mode == :enabled do
      shape
    else
      thinking =
        fetch_value(body, :additionalModelRequestFields, :thinking) ||
          fetch_value(body, :additional_model_request_fields, :thinking)

      budget_tokens = fetch_value(thinking, :budget_tokens)

      disable? =
        fetch_value(thinking, :type) == "disabled" or
          budget_tokens == 0

      enable? =
        fetch_value(thinking, :type) == "enabled" or
          enabled_budget?(budget_tokens)

      merge_reasoning_shapes(
        shape,
        reasoning_shape(
          mode_from_signals(enable?, disable?),
          nil,
          normalize_budget(budget_tokens),
          enable? or disable?
        )
      )
    end
  end

  defp normalize_google_effective(body) when is_map(body) do
    thinking_level =
      fetch_value(body, :generationConfig, :thinkingConfig, :thinkingLevel) ||
        fetch_value(body, :thinkingConfig, :thinkingLevel)

    budget_tokens =
      fetch_value(body, :generationConfig, :thinkingConfig, :thinkingBudget) ||
        fetch_value(body, :thinkingConfig, :thinkingBudget)

    if thinking_level do
      effort = thinking_level_to_effort(thinking_level)
      reasoning_shape(:enabled, effort, nil, true)
    else
      disable? = budget_tokens == 0
      enable? = enabled_budget?(budget_tokens)

      reasoning_shape(
        mode_from_signals(enable?, disable?),
        nil,
        normalize_budget(budget_tokens),
        enable? or disable?
      )
    end
  end

  defp normalize_google_effective(_body), do: disabled_reasoning_shape()

  defp thinking_level_to_effort("minimal"), do: :minimal
  defp thinking_level_to_effort("low"), do: :low
  defp thinking_level_to_effort("medium"), do: :medium
  defp thinking_level_to_effort("high"), do: :high
  defp thinking_level_to_effort(:minimal), do: :minimal
  defp thinking_level_to_effort(:low), do: :low
  defp thinking_level_to_effort(:medium), do: :medium
  defp thinking_level_to_effort(:high), do: :high
  defp thinking_level_to_effort(_), do: nil

  defp normalize_alibaba_effective(body) when is_map(body) do
    enabled? = fetch_value(body, :enable_thinking)
    budget_tokens = fetch_value(body, :thinking_budget)
    disable? = enabled? == false or budget_tokens == 0
    enable? = enabled? == true or enabled_budget?(budget_tokens)

    reasoning_shape(
      mode_from_signals(enable?, disable?),
      nil,
      normalize_budget(budget_tokens),
      enable? or disable?
    )
  end

  defp normalize_alibaba_effective(_body), do: disabled_reasoning_shape()

  defp normalize_thinking_toggle_effective(body) when is_map(body) do
    thinking = fetch_value(body, :thinking)

    disable? = fetch_value(thinking, :type) == "disabled"
    enable? = fetch_value(thinking, :type) == "enabled"

    reasoning_shape(mode_from_signals(enable?, disable?), nil, nil, enable? or disable?)
  end

  defp normalize_thinking_toggle_effective(_body), do: disabled_reasoning_shape()

  defp normalize_zenmux_effective(body) when is_map(body) do
    reasoning = fetch_value(body, :reasoning)

    direct_effort =
      fetch_value(body, :reasoning_effort)
      |> normalize_reasoning_effort()

    depth_effort =
      fetch_value(reasoning, :depth)
      |> normalize_reasoning_effort()

    disable? =
      fetch_value(reasoning, :enable) == false or
        direct_effort == :none

    enable? =
      fetch_value(reasoning, :enable) == true or
        depth_effort in @canonical_reasoning_efforts or
        direct_effort in @canonical_reasoning_efforts

    reasoning_shape(
      mode_from_signals(enable?, disable?),
      depth_effort || direct_effort,
      nil,
      enable? or disable?
    )
  end

  defp normalize_zenmux_effective(_body), do: disabled_reasoning_shape()

  defp reasoning_shape(mode, effort, budget_tokens, explicit?) do
    %{
      mode: mode,
      effort: effort,
      budget_tokens: budget_tokens,
      explicit?: explicit?
    }
  end

  defp disabled_reasoning_shape do
    %{mode: :disabled, effort: nil, budget_tokens: nil, explicit?: false}
  end

  defp merge_reasoning_shapes(primary, secondary) do
    cond do
      primary.explicit? and primary.mode == :disabled -> primary
      secondary.explicit? and secondary.mode == :disabled -> secondary
      primary.explicit? and primary.mode == :enabled -> primary
      secondary.explicit? and secondary.mode == :enabled -> secondary
      primary.explicit? -> primary
      secondary.explicit? -> secondary
      true -> primary
    end
  end

  defp mode_from_signals(enable?, disable?) do
    cond do
      disable? -> :disabled
      enable? -> :enabled
      true -> :disabled
    end
  end

  defp normalize_reasoning_effort(nil), do: nil
  defp normalize_reasoning_effort(:none), do: :none
  defp normalize_reasoning_effort("none"), do: :none

  defp normalize_reasoning_effort(effort) when effort in @canonical_reasoning_efforts do
    effort
  end

  defp normalize_reasoning_effort(effort) when is_binary(effort) do
    trimmed = String.trim(effort)

    case trimmed do
      "" ->
        nil

      value ->
        try do
          value
          |> String.to_existing_atom()
          |> normalize_reasoning_effort()
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp normalize_reasoning_effort(_effort), do: nil

  defp normalize_budget(budget_tokens) when is_integer(budget_tokens) and budget_tokens > 0,
    do: budget_tokens

  defp normalize_budget(_budget_tokens), do: nil

  defp enabled_budget?(budget) when is_integer(budget), do: budget > 0
  defp enabled_budget?(_budget), do: false

  defp reasoning_supported?(model, operation) do
    operation in @reasoning_operations and ModelHelpers.reasoning_enabled?(model)
  end

  defp request_reasoning_contract(%Req.Request{} = request, model) do
    request_contract_from_formatter(Req.Request.get_private(request, :formatter)) ||
      request_contract_from_model_family(model.provider, request.options[:model_family]) ||
      request_reasoning_contract(request_body_source(request), model)
  end

  defp request_reasoning_contract(body, %LLMDB.Model{provider: provider}) when is_map(body) do
    cond do
      provider in @openai_reasoning_providers and openai_reasoning_body?(body) ->
        :openai_effort

      provider == :azure and openai_reasoning_body?(body) ->
        :openai_or_thinking

      provider == :azure and anthropic_thinking_body?(body) ->
        :platform_anthropic

      provider == :anthropic and anthropic_thinking_body?(body) ->
        :anthropic_thinking

      provider == :google and google_reasoning_body?(body) ->
        :google_budget

      provider == :google_vertex and google_reasoning_body?(body) ->
        :google_budget

      provider == :google_vertex and anthropic_thinking_body?(body) ->
        :platform_anthropic

      provider == :amazon_bedrock and anthropic_thinking_body?(body) ->
        :platform_anthropic

      provider in @alibaba_providers and alibaba_reasoning_body?(body) ->
        :alibaba_thinking

      provider in @thinking_toggle_providers and thinking_toggle_body?(body) ->
        :thinking_toggle

      provider == :zenmux and zenmux_reasoning_body?(body) ->
        :zenmux_reasoning

      true ->
        nil
    end
  end

  defp request_reasoning_contract(_request_source, _model), do: nil

  defp request_contract_from_formatter(ReqLLM.Providers.Azure.OpenAI), do: :openai_or_thinking
  defp request_contract_from_formatter(ReqLLM.Providers.Azure.Anthropic), do: :platform_anthropic
  defp request_contract_from_formatter(ReqLLM.Providers.GoogleVertex.Gemini), do: :google_budget

  defp request_contract_from_formatter(ReqLLM.Providers.GoogleVertex.Anthropic),
    do: :platform_anthropic

  defp request_contract_from_formatter(ReqLLM.Providers.AmazonBedrock.Anthropic),
    do: :platform_anthropic

  defp request_contract_from_formatter(_formatter), do: nil

  defp request_contract_from_model_family(:azure, family)
       when family in ["gpt", "text-embedding", "o1", "o3", "o4", "deepseek", "mai-ds"] do
    :openai_or_thinking
  end

  defp request_contract_from_model_family(:azure, "claude"), do: :platform_anthropic
  defp request_contract_from_model_family(:google_vertex, "gemini"), do: :google_budget
  defp request_contract_from_model_family(:google_vertex, "claude"), do: :platform_anthropic
  defp request_contract_from_model_family(:amazon_bedrock, "anthropic"), do: :platform_anthropic
  defp request_contract_from_model_family(:amazon_bedrock, :converse), do: nil
  defp request_contract_from_model_family(_provider, _family), do: nil

  defp openai_reasoning_body?(body) do
    not is_nil(fetch_value(body, :reasoning, :effort)) or
      not is_nil(fetch_value(body, :reasoning_effort))
  end

  defp anthropic_thinking_body?(body) do
    not is_nil(fetch_value(body, :thinking, :type)) or
      not is_nil(fetch_value(body, :thinking, :budget_tokens)) or
      not is_nil(fetch_value(body, :additionalModelRequestFields, :thinking, :type)) or
      not is_nil(fetch_value(body, :additionalModelRequestFields, :thinking, :budget_tokens)) or
      not is_nil(fetch_value(body, :additional_model_request_fields, :thinking, :type)) or
      not is_nil(fetch_value(body, :additional_model_request_fields, :thinking, :budget_tokens))
  end

  defp google_reasoning_body?(body) do
    not is_nil(fetch_value(body, :generationConfig, :thinkingConfig, :thinkingBudget)) or
      not is_nil(fetch_value(body, :thinkingConfig, :thinkingBudget)) or
      not is_nil(fetch_value(body, :generationConfig, :thinkingConfig, :thinkingLevel)) or
      not is_nil(fetch_value(body, :thinkingConfig, :thinkingLevel))
  end

  defp alibaba_reasoning_body?(body) do
    not is_nil(fetch_value(body, :enable_thinking)) or
      not is_nil(fetch_value(body, :thinking_budget))
  end

  defp thinking_toggle_body?(body) do
    not is_nil(fetch_value(body, :thinking, :type))
  end

  defp zenmux_reasoning_body?(body) do
    not is_nil(fetch_value(body, :reasoning, :enable)) or
      not is_nil(fetch_value(body, :reasoning, :depth)) or
      not is_nil(fetch_value(body, :reasoning_effort))
  end

  defp reasoning_contract(%LLMDB.Model{provider: provider})
       when provider in @openai_reasoning_providers do
    :openai_effort
  end

  defp reasoning_contract(%LLMDB.Model{provider: provider})
       when provider in @thinking_toggle_providers do
    :thinking_toggle
  end

  defp reasoning_contract(%LLMDB.Model{provider: provider}) when provider in @alibaba_providers do
    :alibaba_thinking
  end

  defp reasoning_contract(%LLMDB.Model{provider: :anthropic}), do: :anthropic_thinking
  defp reasoning_contract(%LLMDB.Model{provider: :google}), do: :google_budget
  defp reasoning_contract(%LLMDB.Model{provider: :zenmux}), do: :zenmux_reasoning
  defp reasoning_contract(%LLMDB.Model{provider: :zai_coding_plan}), do: :thinking_toggle

  defp reasoning_contract(%LLMDB.Model{provider: :azure} = model) do
    case hosted_model_family(model) do
      :claude -> :platform_anthropic
      :openai -> :openai_or_thinking
      _ -> :unsupported
    end
  end

  defp reasoning_contract(%LLMDB.Model{provider: :google_vertex} = model) do
    case hosted_model_family(model) do
      :claude -> :platform_anthropic
      :gemini -> :google_budget
      _ -> :unsupported
    end
  end

  defp reasoning_contract(%LLMDB.Model{provider: :amazon_bedrock} = model) do
    case hosted_model_family(model) do
      :claude -> :platform_anthropic
      _ -> :unsupported
    end
  end

  defp reasoning_contract(_model), do: :unsupported

  defp hosted_model_family(%LLMDB.Model{} = model) do
    extra_family = hosted_extra_family(model)
    model_id = model.provider_model_id || model.id || ""

    cond do
      extra_family == :claude -> :claude
      extra_family == :gemini -> :gemini
      extra_family == :openai -> :openai
      String.starts_with?(model_id, "claude-") -> :claude
      String.starts_with?(model_id, "anthropic.claude") -> :claude
      String.starts_with?(model_id, "gemini-") -> :gemini
      String.starts_with?(model_id, "o1") -> :openai
      String.starts_with?(model_id, "o3") -> :openai
      String.starts_with?(model_id, "o4") -> :openai
      String.starts_with?(model_id, "gpt-") -> :openai
      String.starts_with?(model_id, "text-embedding") -> :openai
      String.starts_with?(model_id, "deepseek") -> :openai
      String.starts_with?(model_id, "mai-ds") -> :openai
      true -> :unknown
    end
  end

  defp hosted_extra_family(%LLMDB.Model{} = model) do
    extra_family =
      get_in(model, [Access.key(:extra, %{}), :family]) ||
        get_in(model, [Access.key(:extra, %{}), "family"])

    cond do
      is_binary(extra_family) and String.starts_with?(extra_family, "claude") ->
        :claude

      is_binary(extra_family) and String.starts_with?(extra_family, "gemini") ->
        :gemini

      is_binary(extra_family) and
          (String.starts_with?(extra_family, "gpt") or
             String.starts_with?(extra_family, "o1") or
             String.starts_with?(extra_family, "o3") or
             String.starts_with?(extra_family, "o4") or
             String.starts_with?(extra_family, "deepseek") or
             String.starts_with?(extra_family, "mai-ds")) ->
        :openai

      true ->
        :unknown
    end
  end

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
  defp new_response_summary_state(:rerank), do: %{}
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
      usage[:reasoning_tokens] ||
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
      cost: usage[:total_cost]
    }
    |> maybe_put(:input_cost, usage[:input_cost])
    |> maybe_put(:output_cost, usage[:output_cost])
    |> maybe_put(:reasoning_cost, usage[:reasoning_cost])
    |> maybe_put(:total_cost, usage[:total_cost])
  end

  defp token_usage_measurements(_), do: %{tokens: %{}, cost: nil}

  defp first_present(primary, primary_key, secondary, secondary_key) do
    cond do
      keyword_has_key?(primary, primary_key) -> Keyword.get(primary, primary_key)
      has_value_key?(secondary, secondary_key) -> fetch_value(secondary, secondary_key)
      true -> nil
    end
  end

  defp keyword_has_key?(data, key) when is_list(data), do: Keyword.has_key?(data, key)
  defp keyword_has_key?(_data, _key), do: false

  defp has_value_key?(data, key) when is_map(data) do
    Map.has_key?(data, key) or Map.has_key?(data, Atom.to_string(key))
  end

  defp has_value_key?(data, key) when is_list(data) do
    Keyword.has_key?(data, key)
  end

  defp has_value_key?(_data, _key), do: false

  defp fetch_value(data, key) do
    cond do
      is_map(data) ->
        cond do
          Map.has_key?(data, key) -> Map.get(data, key)
          Map.has_key?(data, Atom.to_string(key)) -> Map.get(data, Atom.to_string(key))
          true -> nil
        end

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

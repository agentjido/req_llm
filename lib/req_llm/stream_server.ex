defmodule ReqLLM.StreamServer do
  @moduledoc """
  GenServer that manages streaming LLM sessions with backpressure and SSE parsing.

  StreamServer acts as a bridge between HTTP streaming clients (like FinchClient)
  and consumers, providing:

  - SSE event parsing across HTTP chunk boundaries
  - Token queuing with configurable backpressure
  - Provider-agnostic event decoding via provider callbacks
  - Completion detection and metadata extraction
  - Clean error handling and resource cleanup

  ## Architecture

  The StreamServer receives HTTP events via synchronous GenServer.call/2, which
  enables natural backpressure - if the consumer queue is full, HTTP events are
  delayed until the queue drains. This prevents memory issues from fast producers
  overwhelming slow consumers.

  ## Usage

      # Start a streaming session
      {:ok, server} = StreamServer.start_link(
        provider_mod: ReqLLM.Providers.OpenAI,
        model: %LLMDB.Model{...}
      )

      # Attach HTTP task for monitoring
      StreamServer.attach_http_task(server, http_task_pid)

      # Consumer loop
      case StreamServer.next(server) do
        {:ok, chunk} -> handle_chunk(chunk)
        :halt -> handle_completion()
        {:error, reason} -> handle_error(reason)
      end

  ## State Management

  The server maintains state for:

  - `provider_mod`: Provider module for event decoding
  - `model`: ReqLLM.Model struct for provider context
  - `provider_state`: Optional provider-specific state for stateful transformations
  - `protocol_state`: Opaque parser state across chunks
  - `queue`: Token chunks awaiting consumer retrieval
  - `status`: Current session status (`:init`, `:streaming`, `:done`, `{:error, reason}`)
  - `http_task`: HTTP task reference for monitoring
  - `consumer_refs`: Set of consumer process references
  - `fixture_path`: Optional path for fixture capture
  - `metadata`: Final metadata when streaming completes
  - `high_watermark`: Queue size limit for backpressure (default 500)

  ## Backpressure

  When the internal queue exceeds `high_watermark`, the server delays replying to
  `{:http_event, {:data, _}}` messages until consumers drain the queue via `next/2`.
  This provides natural backpressure without dropping events.
  """

  use GenServer

  alias ReqLLM.StreamChunk
  alias ReqLLM.Streaming.SSE

  require Logger
  require ReqLLM.Debug, as: Debug

  @type server :: GenServer.server()
  @type status :: :init | :streaming | :done | {:error, any()}

  defstruct [
    :provider_mod,
    :model,
    :http_task,
    :fixture_path,
    :http_context,
    :canonical_json,
    :protocol_parser,
    :protocol_state,
    :provider_state,
    :telemetry,
    queue: :queue.new(),
    status: :init,
    consumer_refs: MapSet.new(),
    metadata: %{},
    stream_requested?: false,
    metadata_delivered?: false,
    halt_delivered?: false,
    completion_cleanup_after: 30_000,
    completion_cleanup_timer: nil,
    completion_cleanup_token: nil,
    high_watermark: 500,
    headers: [],
    http_status: nil,
    waiting_callers: [],
    object_json_mode?: false,
    object_acc: [],
    fixture_saved?: false,
    raw_iodata: [],
    raw_bytes: 0,
    terminated?: false
  ]

  @doc """
  Start a StreamServer with the given options.

  ## Options

    * `:provider_mod` - Provider module implementing ReqLLM.Provider behavior (required)
    * `:model` - ReqLLM.Model struct (required)
    * `:fixture_path` - Optional path for fixture capture
    * `:high_watermark` - Queue size limit for backpressure (default: 500)

  ## Examples

      {:ok, server} = ReqLLM.StreamServer.start_link(
        provider_mod: ReqLLM.Providers.OpenAI,
        model: %LLMDB.Model{provider: :openai, name: "gpt-4o"}
      )

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    provider_mod = Keyword.fetch!(opts, :provider_mod)
    model = Keyword.fetch!(opts, :model)

    provider_state =
      if function_exported?(provider_mod, :init_stream_state, 1) do
        provider_mod.init_stream_state(model)
      end

    state = %__MODULE__{
      provider_mod: provider_mod,
      model: model,
      protocol_parser: Keyword.get(opts, :protocol_parser),
      provider_state: provider_state,
      fixture_path: Keyword.get(opts, :fixture_path),
      completion_cleanup_after:
        Keyword.get(
          opts,
          :completion_cleanup_after,
          Application.get_env(:req_llm, :stream_completion_cleanup_after, 30_000)
        ),
      high_watermark: Keyword.get(opts, :high_watermark, 500)
    }

    GenServer.start_link(__MODULE__, state, opts)
  end

  @doc """
  Get the next chunk from the stream with optional timeout.

  Blocks until a chunk is available or the stream completes/errors.
  Returns `:halt` when the stream is complete.

  ## Parameters

    * `server` - StreamServer process
    * `timeout` - Maximum time to wait in milliseconds (default: 30_000)

  ## Returns

    * `{:ok, chunk}` - Next StreamChunk
    * `:halt` - Stream is complete
    * `{:error, reason}` - Error occurred

  ## Examples

      case ReqLLM.StreamServer.next(server) do
        {:ok, %ReqLLM.StreamChunk{type: :content, text: text}} ->
          IO.write(text)
          next(server)

        :halt ->
          :ok

        {:error, reason} ->
          Logger.error("Stream error: " <> inspect(reason))
      end

  """
  @spec next(server(), non_neg_integer()) :: {:ok, StreamChunk.t()} | :halt | {:error, any()}
  def next(server, timeout \\ 30_000) do
    GenServer.call(server, {:next, timeout}, :infinity)
  end

  @doc """
  Cancel the streaming session and cleanup resources.

  Stops the HTTP task if running and terminates the server.

  ## Parameters

    * `server` - StreamServer process

  ## Examples

      ReqLLM.StreamServer.cancel(server)

  """
  @spec cancel(server()) :: :ok
  def cancel(server) do
    GenServer.call(server, :cancel)
  end

  @doc """
  Start HTTP streaming from within the StreamServer.

  This method ensures proper lifecycle coupling by having the StreamServer
  own and link to the HTTP streaming task. When the server exits, the task
  automatically terminates, preventing orphaned callbacks.

  ## Parameters

    * `server` - StreamServer process
    * `provider_mod` - Provider module (e.g., ReqLLM.Providers.OpenAI)
    * `model` - ReqLLM.Model struct
    * `context` - ReqLLM.Context with messages to stream
    * `opts` - Additional options for the request
    * `finch_name` - Finch process name (default: ReqLLM.Finch)

  ## Returns

    * `{:ok, task_pid, http_context, canonical_json}` - Successfully started
    * `{:error, reason}` - Failed to start

  ## Examples

      {:ok, _task_pid, _http_context, _canonical_json} =
        StreamServer.start_http(
          server,
          ReqLLM.Providers.OpenAI,
          model,
          context,
          opts
        )

  """
  @spec start_http(server(), module(), LLMDB.Model.t(), ReqLLM.Context.t(), keyword(), atom()) ::
          {:ok, pid(), any(), any()} | {:error, term()}
  def start_http(server, provider_mod, model, context, opts, finch_name \\ ReqLLM.Finch) do
    GenServer.call(
      server,
      {:start_http, provider_mod, model, context, opts, finch_name},
      :infinity
    )
  end

  @doc """
  Attach an HTTP task to the server for monitoring.

  The server will monitor the task and handle cleanup if it crashes.

  ## Parameters

    * `server` - StreamServer process
    * `task_pid` - HTTP task process ID

  ## Examples

      task = Task.async(fn -> Finch.stream(...) end)
      ReqLLM.StreamServer.attach_http_task(server, task.pid)

  """
  @spec attach_http_task(server(), pid()) :: :ok
  def attach_http_task(server, task_pid) do
    GenServer.call(server, {:attach_http_task, task_pid})
  end

  @doc """
  Forward an HTTP event to the server for processing.

  This is the primary interface for HTTP clients to deliver streaming events.
  Provides backpressure through synchronous GenServer.call.

  ## Parameters

    * `server` - StreamServer process
    * `event` - HTTP event tuple: `{:status, integer()}`, `{:headers, list()}`,
                `{:data, binary()}`, `:done`, or `{:error, term()}`

  ## Examples

      ReqLLM.StreamServer.http_event(server, {:status, 200})
      ReqLLM.StreamServer.http_event(server, {:headers, [{"content-type", "text/event-stream"}]})
      ReqLLM.StreamServer.http_event(server, {:data, "data: {...}\\n\\n"})
      ReqLLM.StreamServer.http_event(server, :done)

  """
  @spec http_event(server(), term()) :: :ok
  def http_event(server, event) do
    GenServer.call(server, {:http_event, event})
  end

  @doc """
  Set HTTP context and canonical JSON for fixture capture.

  This is called by the streaming pipeline to provide the HTTP metadata
  and request data needed for fixture capture.

  ## Parameters

    * `server` - StreamServer process
    * `http_context` - HTTPContext struct with request/response metadata
    * `canonical_json` - The request body as JSON for fixture saving

  ## Examples

      ReqLLM.StreamServer.set_fixture_context(server, http_context, request_json)

  """
  @spec set_fixture_context(server(), ReqLLM.Streaming.Fixtures.HTTPContext.t(), any()) :: :ok
  def set_fixture_context(server, http_context, canonical_json) do
    GenServer.call(server, {:set_fixture_context, http_context, canonical_json})
  end

  @doc """
  Sets streaming telemetry context for the current stream.
  """
  @spec set_telemetry_context(server(), map()) :: :ok
  def set_telemetry_context(server, telemetry_context) do
    GenServer.call(server, {:set_telemetry_context, telemetry_context})
  end

  @doc """
  Block until metadata is available from the completed stream.

  ## Parameters

    * `server` - StreamServer process
    * `timeout` - Maximum time to wait in milliseconds (default: 30_000)

  ## Returns

    * `{:ok, metadata}` - Final stream metadata
    * `{:error, reason}` - Error occurred or timeout

  ## Examples

      case ReqLLM.StreamServer.await_metadata(server, 10_000) do
        {:ok, metadata} ->
          IO.puts("Tokens used: " <> inspect(metadata[:usage][:total_tokens]))
        {:error, :timeout} ->
          IO.puts("Metadata not available yet")
      end

  """
  @spec await_metadata(server(), non_neg_integer()) :: {:ok, map()} | {:error, any()}
  def await_metadata(server, timeout \\ 30_000) do
    GenServer.call(server, {:await_metadata, timeout}, :infinity)
  end

  ## GenServer Callbacks

  @impl GenServer
  def init(state) do
    Process.flag(:trap_exit, true)

    protocol_parser =
      cond do
        is_function(state.protocol_parser, 2) ->
          state.protocol_parser

        function_exported?(state.provider_mod, :parse_stream_protocol, 2) ->
          fn chunk, buffer -> state.provider_mod.parse_stream_protocol(chunk, buffer) end

        true ->
          &ReqLLM.Provider.parse_stream_protocol/2
      end

    {:ok, %{state | protocol_parser: protocol_parser}}
  end

  @impl GenServer
  def handle_call({:http_event, event}, _from, state) do
    {:reply, reply, new_state} = process_http_event(event, state)

    case finalize_lifecycle(new_state) do
      {:stop, final_state} -> {:stop, :normal, reply, final_state}
      {:continue, final_state} -> {:reply, reply, final_state}
    end
  end

  @impl GenServer
  def handle_call({:next, timeout}, from, state) do
    state = cancel_completion_cleanup(%{state | stream_requested?: true})

    case dequeue_chunk(state) do
      {:ok, chunk, new_state} ->
        {:reply, {:ok, chunk}, new_state}

      {:empty, new_state} ->
        case state.status do
          :done ->
            halted_state = %{new_state | halt_delivered?: true}

            case finalize_lifecycle(halted_state) do
              {:stop, final_state} -> {:stop, :normal, :halt, final_state}
              {:continue, final_state} -> {:reply, :halt, final_state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, new_state}

          _ ->
            {:noreply, register_waiting_caller(new_state, from, :next, timeout)}
        end
    end
  end

  @impl GenServer
  def handle_call(:cancel, _from, state) do
    new_state =
      state
      |> maybe_emit_stream_stop(:cancelled)
      |> cleanup_resources()

    {:stop, :normal, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:start_http, provider_mod, model, context, opts, finch_name}, _from, state) do
    streamer_mod =
      case Keyword.get(opts, :stream_transport) do
        :websocket -> ReqLLM.Streaming.WebSocketClient
        _ -> ReqLLM.Streaming.FinchClient
      end

    case streamer_mod.start_stream(provider_mod, model, context, opts, self(), finch_name) do
      {:ok, task_pid, http_context, canonical_json} ->
        Process.monitor(task_pid)

        is_google = model.provider == :google

        json_mode? =
          is_google and
            get_in(canonical_json, ["generationConfig", "responseMimeType"]) ==
              "application/json"

        new_state = %{
          state
          | http_task: task_pid,
            status: :streaming,
            http_context: http_context,
            canonical_json: canonical_json,
            object_json_mode?: json_mode?,
            object_acc: []
        }

        {:reply, {:ok, task_pid, http_context, canonical_json}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:attach_http_task, task_pid}, _from, state) do
    Process.monitor(task_pid)
    new_state = %{state | http_task: task_pid, status: :streaming}
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:set_fixture_context, http_context, canonical_json}, _from, state) do
    is_google = state.model.provider == :google

    json_mode? =
      is_google and
        get_in(canonical_json, ["generationConfig", "responseMimeType"]) == "application/json"

    new_state = %{
      state
      | http_context: http_context,
        canonical_json: canonical_json,
        object_json_mode?: json_mode?,
        object_acc: []
    }

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:set_telemetry_context, telemetry_context}, _from, state) do
    {:reply, :ok, %{state | telemetry: telemetry_context}}
  end

  @impl GenServer
  def handle_call({:await_metadata, _timeout}, _from, %{status: :done} = state) do
    new_state = %{state | metadata_delivered?: true}

    case finalize_lifecycle(new_state) do
      {:stop, final_state} -> {:stop, :normal, {:ok, final_state.metadata}, final_state}
      {:continue, final_state} -> {:reply, {:ok, final_state.metadata}, final_state}
    end
  end

  def handle_call({:await_metadata, _timeout}, _from, %{status: {:error, reason}} = state) do
    {:reply, {:error, reason}, state}
  end

  def handle_call({:await_metadata, timeout}, from, state) do
    {:noreply, register_waiting_caller(state, from, :metadata, timeout)}
  end

  @impl GenServer
  def handle_info({ref, _result}, state) when is_reference(ref) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:caller_timeout, token}, state) do
    case pop_waiting_caller(state, token) do
      {nil, new_state} ->
        {:noreply, new_state}

      {%{from: from, type: _type}, new_state} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_info({:EXIT, pid, reason}, %{http_task: pid} = state) do
    new_state =
      case reason do
        :normal ->
          finalize_stream_with_fixture(state)

        :shutdown ->
          finalize_stream_with_fixture(state)

        {:shutdown, _} ->
          finalize_stream_with_fixture(state)

        _ ->
          state
          |> Map.put(:status, {:error, {:http_task_failed, reason}})
          |> maybe_emit_stream_exception({:http_task_failed, reason})
      end

    new_state = reply_to_waiting_callers(new_state)

    case finalize_lifecycle(new_state) do
      {:stop, final_state} -> {:stop, :normal, final_state}
      {:continue, final_state} -> {:noreply, final_state}
    end
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{http_task: pid} = state) do
    new_state =
      case reason do
        :normal ->
          finalize_stream_with_fixture(state)

        _ ->
          state
          |> Map.put(:status, {:error, {:http_task_failed, reason}})
          |> maybe_emit_stream_exception({:http_task_failed, reason})
      end

    new_state = reply_to_waiting_callers(new_state)

    case finalize_lifecycle(new_state) do
      {:stop, final_state} -> {:stop, :normal, final_state}
      {:continue, final_state} -> {:noreply, final_state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        {:completion_cleanup, token},
        %{completion_cleanup_token: token} = state
      ) do
    new_state = %{state | completion_cleanup_timer: nil, completion_cleanup_token: nil}

    case should_schedule_completion_cleanup?(new_state) do
      true -> {:stop, :normal, new_state}
      false -> {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_info({:completion_cleanup, _ref}, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    cleanup_resources(state)
    :ok
  end

  ## Private Functions

  defp process_http_event({:status, status}, state) do
    new_state = %{state | http_status: status}
    {:reply, :ok, new_state}
  end

  defp process_http_event({:headers, headers}, state) do
    alias ReqLLM.Streaming.Fixtures.HTTPContext

    updated_http_context =
      if state.http_context do
        status = state.http_status || 200
        HTTPContext.update_response(state.http_context, status, Map.new(headers))
      else
        state.http_context
      end

    new_state = %{state | headers: headers, http_context: updated_http_context}
    {:reply, :ok, new_state}
  end

  defp process_http_event({:data, chunk}, state) do
    if state.http_status && state.http_status >= 400 do
      error = build_http_error(state.http_status, chunk, state.headers)

      new_state =
        state
        |> Map.put(:status, {:error, error})
        |> maybe_emit_stream_exception(error)
        |> reply_to_waiting_callers()

      {:reply, :ok, new_state}
    else
      process_data_chunk(chunk, state)
    end
  end

  defp process_http_event(:done, state) do
    new_state = finalize_stream_with_fixture(state) |> reply_to_waiting_callers()
    {:reply, :ok, new_state}
  end

  defp process_http_event({:error, reason}, state) do
    new_state =
      state
      |> Map.put(:status, {:error, reason})
      |> maybe_emit_stream_exception(reason)
      |> reply_to_waiting_callers()

    {:reply, :ok, new_state}
  end

  defp parse_protocol_events(chunk, state) do
    case state.protocol_parser.(chunk, state.protocol_state) do
      {:ok, events, new_protocol_state} ->
        {events, new_protocol_state}

      {:incomplete, new_protocol_state} ->
        {[], new_protocol_state}

      {:error, reason} ->
        Logger.warning("Protocol parse error: #{inspect(reason)}")
        {[], state.protocol_state}
    end
  end

  defp process_data_chunk(chunk, state) do
    state =
      if state.fixture_path && is_binary(chunk) do
        new_bytes = state.raw_bytes + byte_size(chunk)

        if new_bytes > 100_000_000 and state.raw_bytes <= 100_000_000 do
          Logger.warning(
            "Streaming fixture exceeded 100MB at #{state.fixture_path} - consider reviewing test data size"
          )
        end

        %{state | raw_iodata: [chunk | state.raw_iodata], raw_bytes: new_bytes}
      else
        state
      end

    {events, new_protocol_state} = parse_protocol_events(chunk, state)

    {stream_chunks, new_provider_state} = decode_protocol_events(events, state)

    new_state =
      enqueue_chunks(stream_chunks, %{
        state
        | protocol_state: new_protocol_state,
          provider_state: new_provider_state
      })

    terminated? =
      Enum.any?(events, &termination_event?/1) or
        Enum.any?(stream_chunks, &terminal_chunk?/1)

    new_state =
      if terminated? do
        finalize_stream_with_fixture(%{new_state | terminated?: true})
      else
        new_state
      end

    new_state = reply_to_waiting_callers(new_state)
    {:reply, :ok, new_state}
  end

  defp decode_protocol_events(events, state) do
    {stream_chunks, provider_state} =
      Enum.reduce(events, {[], state.provider_state}, fn event, {chunks_acc, prov_state} ->
        case SSE.process_sse_event(event) do
          nil ->
            {chunks_acc, prov_state}

          processed_event ->
            {new_chunks, updated_prov_state} =
              decode_provider_event(processed_event, state.provider_mod, state.model, prov_state)

            {prepend_chunks(new_chunks, chunks_acc), updated_prov_state}
        end
      end)

    {Enum.reverse(stream_chunks), provider_state}
  end

  defp prepend_chunks(chunks, acc) do
    Enum.reduce(chunks, acc, fn chunk, chunk_acc -> [chunk | chunk_acc] end)
  end

  defp decode_provider_event(event, provider_mod, model, provider_state) do
    cond do
      function_exported?(provider_mod, :decode_stream_event, 3) ->
        provider_mod.decode_stream_event(event, model, provider_state)

      function_exported?(provider_mod, :decode_stream_event, 2) ->
        chunks = provider_mod.decode_stream_event(event, model)
        {chunks, provider_state}

      true ->
        chunks = ReqLLM.Provider.Defaults.default_decode_stream_event(event, model)
        {chunks, provider_state}
    end
  end

  defp termination_event?(%{data: "[DONE]"}), do: true
  defp termination_event?(%{data: %{"done" => true}}), do: true
  defp termination_event?(%{data: %{"type" => "message_stop"}}), do: true
  defp termination_event?(%{data: %{"type" => "response.completed"}}), do: true
  defp termination_event?(_), do: false

  defp terminal_chunk?(%ReqLLM.StreamChunk{type: :meta, metadata: metadata})
       when is_map(metadata) do
    Map.get(metadata, :terminal?) == true or Map.get(metadata, "terminal?") == true
  end

  defp terminal_chunk?(_chunk), do: false

  defp enqueue_chunks(chunks, state) do
    {new_queue, updated_metadata, new_obj_acc, telemetry} =
      Enum.reduce(
        chunks,
        {state.queue, state.metadata, state.object_acc, state.telemetry},
        fn chunk, {queue, metadata, obj_acc, telemetry} ->
          new_queue = :queue.in(chunk, queue)

          updated_metadata =
            case chunk.type do
              :meta ->
                chunk_meta = chunk.metadata || %{}

                # Extract usage for normalization
                usage = Map.get(chunk_meta, :usage)

                meta_with_usage =
                  if usage do
                    normalized_usage = normalize_streaming_usage(usage, state.model)

                    Map.update(metadata, :usage, normalized_usage, fn existing ->
                      ReqLLM.Usage.merge(existing, normalized_usage)
                    end)
                  else
                    metadata
                  end

                # Merge remaining metadata (like finish_reason)
                Map.merge(meta_with_usage, Map.drop(chunk_meta, [:usage, "usage"]))

              _ ->
                metadata
            end

          obj_acc =
            if state.object_json_mode? and chunk.type == :content and is_binary(chunk.text) do
              [obj_acc, chunk.text]
            else
              obj_acc
            end

          telemetry =
            case telemetry do
              nil -> nil
              context -> ReqLLM.Telemetry.observe_stream_chunk(context, chunk)
            end

          {new_queue, updated_metadata, obj_acc, telemetry}
        end
      )

    %{
      state
      | queue: new_queue,
        metadata: updated_metadata,
        object_acc: new_obj_acc,
        telemetry: telemetry
    }
  end

  defp dequeue_chunk(state) do
    case :queue.out(state.queue) do
      {{:value, chunk}, new_queue} ->
        new_state = %{state | queue: new_queue}
        {:ok, chunk, new_state}

      {:empty, _} ->
        {:empty, state}
    end
  end

  defp finalize_stream(state) do
    state = flush_protocol_state(state)

    {flush_chunks, new_provider_state} =
      if function_exported?(state.provider_mod, :flush_stream_state, 2) do
        state.provider_mod.flush_stream_state(state.model, state.provider_state)
      else
        {[], state.provider_state}
      end

    extra_flush_chunks =
      if state.object_json_mode? do
        full = state.object_acc |> IO.iodata_to_binary() |> String.trim()

        Debug.dbug(fn -> "JSON mode finalize: accumulated=#{inspect(full)}" end,
          component: :stream_server
        )

        case Jason.decode(full) do
          {:ok, obj} ->
            Debug.dbug(fn -> "Parsed object: #{inspect(obj)}" end, component: :stream_server)

            [ReqLLM.StreamChunk.tool_call("structured_output", obj)]

          {:error, reason} ->
            Debug.dbug(fn -> "Failed to parse JSON: #{inspect(reason)}" end,
              component: :stream_server
            )

            []
        end
      else
        []
      end

    state =
      state
      |> Map.put(:provider_state, new_provider_state)
      |> then(&enqueue_chunks(flush_chunks ++ extra_flush_chunks, &1))

    metadata = extract_final_metadata(state)

    state
    |> Map.put(:status, :done)
    |> Map.put(:metadata, metadata)
    |> maybe_emit_stream_stop(metadata[:finish_reason] || :unknown)
  end

  defp flush_protocol_state(state) do
    {events, new_protocol_state} = SSE.flush(state.protocol_state)
    terminated? = Enum.any?(events, &termination_event?/1)

    if events != [] do
      {stream_chunks, new_provider_state} = decode_protocol_events(events, state)

      state
      |> Map.put(:provider_state, new_provider_state)
      |> Map.put(:protocol_state, new_protocol_state)
      |> Map.put(:terminated?, state.terminated? or terminated?)
      |> then(&enqueue_chunks(stream_chunks, &1))
    else
      %{state | protocol_state: new_protocol_state}
    end
  end

  defp finalize_stream_with_fixture(state) do
    Debug.dbug(
      fn ->
        "finalize_stream_with_fixture: fixture_path=#{inspect(state.fixture_path)}, has_http_context=#{inspect(state.http_context != nil)}, has_canonical_json=#{inspect(state.canonical_json != nil)}, already_saved=#{state.fixture_saved?}"
      end,
      component: :stream_server
    )

    # Only save once - guard against multiple finalization calls
    if state.fixture_path && state.http_context && state.canonical_json && !state.fixture_saved? do
      Debug.dbug(
        fn ->
          "Attempting to save streaming fixture to #{Path.relative_to_cwd(state.fixture_path)}"
        end,
        component: :stream_server
      )

      try do
        case Code.ensure_loaded(ReqLLM.Step.Fixture.Backend) do
          {:module, ReqLLM.Step.Fixture.Backend} ->
            Debug.dbug(
              fn -> "Calling save_streaming_fixture with #{state.raw_bytes} bytes..." end,
              component: :stream_server
            )

            # Pass iodata directly - reversed because we prepended
            iodata = Enum.reverse(state.raw_iodata)

            # credo:disable-for-next-line Credo.Check.Refactor.Apply
            apply(ReqLLM.Step.Fixture.Backend, :save_streaming_fixture, [
              state.http_context,
              state.fixture_path,
              state.canonical_json,
              state.model,
              iodata
            ])

            Debug.dbug("save_streaming_fixture completed", component: :stream_server)

          {:error, _} ->
            Debug.dbug("Could not load ReqLLM.Step.Fixture.Backend", component: :stream_server)
            :ok
        end
      rescue
        error ->
          Debug.dbug(fn -> "Error saving fixture: #{inspect(error)}" end,
            component: :stream_server
          )

          Logger.warning("Failed to save streaming fixture: #{inspect(error)}")
      end

      # Mark as saved to prevent duplicate saves
      state = %{state | fixture_saved?: true}
      Debug.dbug("Fixture marked as saved", component: :stream_server)
      # Continue with normal finalization
      finalize_stream(state)
    else
      Debug.dbug("Skipping fixture save - missing requirements or already saved",
        component: :stream_server
      )

      # Continue with normal finalization
      finalize_stream(state)
    end
  end

  defp extract_final_metadata(state) do
    meta =
      state.metadata
      |> Map.put(:status, state.http_status)
      |> Map.put(:headers, state.headers)
      |> maybe_put_request_id(state.telemetry)
      |> normalize_public_stream_finish_reason()

    cleanly_terminated? =
      state.terminated? or Map.get(state.metadata, :terminal?) == true

    meta =
      if cleanly_terminated? do
        Map.put_new(meta, :finish_reason, :stop)
      else
        Map.put_new(meta, :finish_reason, :incomplete)
      end

    Map.delete(meta, :terminal?)
  end

  defp reply_to_waiting_callers(state) do
    {replied_callers, remaining_callers} =
      Enum.split_with(state.waiting_callers, fn caller ->
        can_reply_to_caller?(caller, state)
      end)

    # Thread the state through each reply to preserve queue updates
    updated_state =
      Enum.reduce(replied_callers, state, fn caller, acc_state ->
        reply_to_caller(caller, acc_state)
      end)

    %{updated_state | waiting_callers: remaining_callers}
  end

  defp can_reply_to_caller?(%{type: :next}, state) do
    not :queue.is_empty(state.queue) or state.status == :done or match?({:error, _}, state.status)
  end

  defp can_reply_to_caller?(%{type: :metadata}, state) do
    state.status == :done or match?({:error, _}, state.status)
  end

  defp reply_to_caller(%{from: from, type: :next} = caller, state) do
    cancel_waiting_caller_timer(caller)

    case {dequeue_chunk(state), state.status} do
      {{:ok, chunk, new_state}, _} ->
        GenServer.reply(from, {:ok, chunk})
        new_state

      {{:empty, _}, :done} ->
        GenServer.reply(from, :halt)
        %{state | halt_delivered?: true}

      {{:empty, _}, {:error, reason}} ->
        GenServer.reply(from, {:error, reason})
        state

      {{:empty, _}, _} ->
        GenServer.reply(from, {:error, :unexpected_empty_queue})
        state
    end
  end

  defp reply_to_caller(%{from: from, type: :metadata} = caller, %{status: :done} = state) do
    cancel_waiting_caller_timer(caller)
    GenServer.reply(from, {:ok, state.metadata})
    %{state | metadata_delivered?: true}
  end

  defp reply_to_caller(
         %{from: from, type: :metadata} = caller,
         %{status: {:error, reason}} = state
       ) do
    cancel_waiting_caller_timer(caller)
    GenServer.reply(from, {:error, reason})
    state
  end

  defp reply_to_caller(%{from: from, type: :metadata} = caller, state) do
    cancel_waiting_caller_timer(caller)
    GenServer.reply(from, {:error, :not_ready})
    state
  end

  defp register_waiting_caller(state, from, type, timeout) do
    token = make_ref()
    timer = Process.send_after(self(), {:caller_timeout, token}, timeout)

    caller = %{from: from, type: type, token: token, timer: timer}
    %{state | waiting_callers: state.waiting_callers ++ [caller]}
  end

  defp pop_waiting_caller(state, token) do
    {matched, remaining} =
      Enum.split_with(state.waiting_callers, fn caller -> caller.token == token end)

    {List.first(matched), %{state | waiting_callers: remaining}}
  end

  defp cancel_waiting_caller_timer(%{timer: timer}) do
    Process.cancel_timer(timer, async: true, info: false)
  end

  defp cleanup_resources(state) do
    # Kill HTTP task if running
    if state.http_task && Process.alive?(state.http_task) do
      Process.exit(state.http_task, :cancelled)
    end

    cancel_completion_cleanup(state)
  end

  defp ready_to_stop?(state) do
    state.status == :done and state.metadata_delivered? and state.halt_delivered? and
      :queue.is_empty(state.queue)
  end

  defp finalize_lifecycle(state) do
    cond do
      ready_to_stop?(state) ->
        {:stop, cancel_completion_cleanup(state)}

      should_schedule_completion_cleanup?(state) ->
        {:continue, ensure_completion_cleanup_timer(state)}

      true ->
        {:continue, cancel_completion_cleanup(state)}
    end
  end

  defp should_schedule_completion_cleanup?(state) do
    state.status == :done and state.metadata_delivered? and not state.stream_requested? and
      not state.halt_delivered? and is_integer(state.completion_cleanup_after) and
      state.completion_cleanup_after >= 0
  end

  defp ensure_completion_cleanup_timer(%{completion_cleanup_timer: nil} = state) do
    token = make_ref()

    timer =
      Process.send_after(self(), {:completion_cleanup, token}, state.completion_cleanup_after)

    %{state | completion_cleanup_timer: timer, completion_cleanup_token: token}
  end

  defp ensure_completion_cleanup_timer(state), do: state

  defp cancel_completion_cleanup(%{completion_cleanup_timer: nil} = state), do: state

  defp cancel_completion_cleanup(%{completion_cleanup_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | completion_cleanup_timer: nil, completion_cleanup_token: nil}
  end

  defp build_http_error(status, chunk, headers) do
    case Jason.decode(chunk) do
      {:ok, %{"error" => error_data}} when is_map(error_data) ->
        message = Map.get(error_data, "message", "HTTP #{status}")

        ReqLLM.Error.API.Request.exception(
          reason: message,
          status: status,
          response_body: error_data,
          headers: headers
        )

      {:ok, decoded} ->
        ReqLLM.Error.API.Request.exception(
          reason: "HTTP #{status}",
          status: status,
          response_body: decoded,
          headers: headers
        )

      {:error, _} ->
        ReqLLM.Error.API.Request.exception(
          reason: "HTTP #{status}",
          status: status,
          response_body: chunk,
          headers: headers
        )
    end
  end

  # Normalize streaming usage data from provider format to ReqLLM format
  # This mirrors the logic in ReqLLM.Step.Usage.fallback_extract_usage/1
  defp normalize_streaming_usage(usage, model) when is_map(usage) do
    usage
    |> ReqLLM.Usage.normalize()
    |> ReqLLM.Usage.Cost.apply(model, original_usage: usage, preserve_total_cost: true)
  end

  defp normalize_streaming_usage(usage, _model), do: usage

  defp maybe_emit_stream_stop(%{telemetry: nil} = state, _finish_reason), do: state

  defp maybe_emit_stream_stop(%{telemetry: telemetry} = state, finish_reason) do
    usage = state.metadata[:usage]

    telemetry =
      ReqLLM.Telemetry.stop_request(
        telemetry,
        state.metadata,
        finish_reason: normalize_telemetry_stream_finish_reason(finish_reason),
        http_status: state.http_status,
        usage: usage,
        emit_token_usage?: is_map(usage)
      )

    %{state | telemetry: telemetry}
  end

  defp maybe_emit_stream_exception(%{telemetry: nil} = state, _reason), do: state

  defp maybe_emit_stream_exception(%{telemetry: telemetry} = state, reason) do
    %{state | telemetry: ReqLLM.Telemetry.exception_request(telemetry, reason)}
  end

  defp maybe_put_request_id(meta, nil), do: meta
  defp maybe_put_request_id(meta, telemetry), do: Map.put(meta, :request_id, telemetry.request_id)

  defp normalize_public_stream_finish_reason(%{finish_reason: "stop"} = meta),
    do: %{meta | finish_reason: :stop}

  defp normalize_public_stream_finish_reason(%{finish_reason: "length"} = meta),
    do: %{meta | finish_reason: :length}

  defp normalize_public_stream_finish_reason(%{finish_reason: "cancelled"} = meta),
    do: %{meta | finish_reason: :cancelled}

  defp normalize_public_stream_finish_reason(%{finish_reason: "incomplete"} = meta),
    do: %{meta | finish_reason: :incomplete}

  defp normalize_public_stream_finish_reason(meta), do: meta

  defp normalize_telemetry_stream_finish_reason("stop"), do: :stop
  defp normalize_telemetry_stream_finish_reason("length"), do: :length
  defp normalize_telemetry_stream_finish_reason("tool_use"), do: :tool_calls
  defp normalize_telemetry_stream_finish_reason("tool_calls"), do: :tool_calls
  defp normalize_telemetry_stream_finish_reason("cancelled"), do: :cancelled
  defp normalize_telemetry_stream_finish_reason("incomplete"), do: :incomplete
  defp normalize_telemetry_stream_finish_reason(finish_reason), do: finish_reason
end

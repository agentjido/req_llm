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
  - `sse_buffer`: Binary buffer for SSE parsing across chunks
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
    :provider_state,
    sse_buffer: "",
    queue: :queue.new(),
    status: :init,
    consumer_refs: MapSet.new(),
    metadata: %{},
    high_watermark: 500,
    headers: [],
    http_status: nil,
    waiting_callers: [],
    object_json_mode?: false,
    object_acc: [],
    fixture_saved?: false,
    raw_iodata: [],
    raw_bytes: 0
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
      provider_state: provider_state,
      fixture_path: Keyword.get(opts, :fixture_path),
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
    GenServer.call(server, {:next, timeout}, timeout + 1000)
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
    GenServer.call(server, :await_metadata, timeout + 1000)
  end

  ## GenServer Callbacks

  @impl GenServer
  def init(state) do
    Process.flag(:trap_exit, true)

    protocol_parser =
      if function_exported?(state.provider_mod, :parse_stream_protocol, 2) do
        fn chunk, buffer -> state.provider_mod.parse_stream_protocol(chunk, buffer) end
      else
        &ReqLLM.Provider.parse_stream_protocol/2
      end

    {:ok, %{state | protocol_parser: protocol_parser}}
  end

  @impl GenServer
  def handle_call({:http_event, event}, _from, state) do
    {:reply, reply, new_state} = process_http_event(event, state)
    {:reply, reply, new_state}
  end

  @impl GenServer
  def handle_call({:next, _timeout}, from, state) do
    case dequeue_chunk(state) do
      {:ok, chunk, new_state} ->
        {:reply, {:ok, chunk}, new_state}

      {:empty, new_state} ->
        case state.status do
          :done ->
            {:reply, :halt, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, new_state}

          _ ->
            # Queue is empty but stream is still active - wait for more data
            new_state = %{
              new_state
              | waiting_callers: new_state.waiting_callers ++ [{from, :next}]
            }

            {:noreply, new_state}
        end
    end
  end

  @impl GenServer
  def handle_call(:cancel, _from, state) do
    new_state = cleanup_resources(state)
    {:stop, :normal, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:start_http, provider_mod, model, context, opts, finch_name}, _from, state) do
    case ReqLLM.Streaming.FinchClient.start_stream(
           provider_mod,
           model,
           context,
           opts,
           self(),
           finch_name
         ) do
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
  def handle_call(:await_metadata, from, state) do
    case state.status do
      :done ->
        {:reply, {:ok, state.metadata}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}

      _ ->
        # Not done yet, add caller to waiting list
        new_state = %{state | waiting_callers: state.waiting_callers ++ [{from, :metadata}]}
        {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_info({ref, result}, state) when is_reference(ref) do
    Logger.debug("HTTP task completed with result: #{inspect(result)}")
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:EXIT, pid, reason}, %{http_task: pid} = state) do
    Logger.debug("HTTP task #{inspect(pid)} exited: #{inspect(reason)}")

    new_state =
      case reason do
        :normal -> finalize_stream_with_fixture(state)
        :shutdown -> finalize_stream_with_fixture(state)
        {:shutdown, _} -> finalize_stream_with_fixture(state)
        _ -> %{state | status: {:error, {:http_task_failed, reason}}}
      end

    new_state = reply_to_waiting_callers(new_state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{http_task: pid} = state) do
    Logger.debug("HTTP task #{inspect(pid)} terminated: #{inspect(reason)}")

    new_state =
      case reason do
        :normal -> finalize_stream_with_fixture(state)
        _ -> %{state | status: {:error, {:http_task_failed, reason}}}
      end

    new_state = reply_to_waiting_callers(new_state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
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
      error = build_http_error(state.http_status, chunk)
      new_state = %{state | status: {:error, error}} |> reply_to_waiting_callers()
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
    new_state = %{state | status: {:error, reason}} |> reply_to_waiting_callers()
    {:reply, :ok, new_state}
  end

  defp parse_protocol_events(chunk, state) do
    # Call the injected protocol parser
    case state.protocol_parser.(chunk, state.sse_buffer) do
      {:ok, events, new_buffer} ->
        {events, new_buffer}

      {:incomplete, new_buffer} ->
        {[], new_buffer}

      {:error, reason} ->
        Logger.warning("Protocol parse error: #{inspect(reason)}")
        {[], state.sse_buffer}
    end
  end

  defp process_data_chunk(chunk, state) do
    # Capture raw chunk for fixture - accumulate in state
    state =
      if state.fixture_path && is_binary(chunk) do
        new_bytes = state.raw_bytes + byte_size(chunk)

        # Warn if fixture is growing unexpectedly large (>100MB)
        if new_bytes > 100_000_000 and state.raw_bytes <= 100_000_000 do
          Logger.warning(
            "Streaming fixture exceeded 100MB at #{state.fixture_path} - consider reviewing test data size"
          )
        end

        %{state | raw_iodata: [chunk | state.raw_iodata], raw_bytes: new_bytes}
      else
        state
      end

    # Use provider's protocol parser (defaults to SSE if not overridden)
    {events, new_buffer} = parse_protocol_events(chunk, state)

    # Decode events using provider (with optional state threading)
    {stream_chunks, new_provider_state} =
      events
      |> Enum.map(&SSE.process_sse_event/1)
      |> Enum.reduce({[], state.provider_state}, fn event, {chunks_acc, prov_state} ->
        {new_chunks, updated_prov_state} =
          decode_provider_event(event, state.provider_mod, state.model, prov_state)

        {chunks_acc ++ new_chunks, updated_prov_state}
      end)

    # Enqueue chunks and check for completion
    new_state =
      enqueue_chunks(stream_chunks, %{
        state
        | sse_buffer: new_buffer,
          provider_state: new_provider_state
      })

    # Check if any events signaled completion
    new_state =
      if Enum.any?(events, &termination_event?/1) do
        finalize_stream_with_fixture(new_state)
      else
        new_state
      end

    # Reply to waiting callers if queue has data
    new_state = reply_to_waiting_callers(new_state)
    {:reply, :ok, new_state}
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

  defp enqueue_chunks(chunks, state) do
    {new_queue, updated_metadata, new_obj_acc} =
      Enum.reduce(chunks, {state.queue, state.metadata, state.object_acc}, fn chunk,
                                                                              {queue, metadata,
                                                                               obj_acc} ->
        new_queue = :queue.in(chunk, queue)

        updated_metadata =
          case chunk.type do
            :meta ->
              chunk_meta = chunk.metadata || %{}

              # Extract usage for normalization
              usage = Map.get(chunk_meta, :usage) || Map.get(chunk_meta, "usage")

              meta_with_usage =
                if usage do
                  normalized_usage = normalize_streaming_usage(usage, state.model)
                  Map.update(metadata, :usage, normalized_usage, &Map.merge(&1, normalized_usage))
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

        {new_queue, updated_metadata, obj_acc}
      end)

    %{state | queue: new_queue, metadata: updated_metadata, object_acc: new_obj_acc}
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
    %{state | status: :done, metadata: metadata}
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
    # Return accumulated metadata with HTTP status and headers
    state.metadata
    |> Map.put(:status, state.http_status)
    |> Map.put(:headers, state.headers)
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

  defp can_reply_to_caller?({_from, :next}, state) do
    not :queue.is_empty(state.queue) or state.status == :done or match?({:error, _}, state.status)
  end

  defp can_reply_to_caller?({_from, :metadata}, state) do
    state.status == :done or match?({:error, _}, state.status)
  end

  defp reply_to_caller({from, :next}, state) do
    case {dequeue_chunk(state), state.status} do
      {{:ok, chunk, new_state}, _} ->
        GenServer.reply(from, {:ok, chunk})
        new_state

      {{:empty, _}, :done} ->
        GenServer.reply(from, :halt)
        state

      {{:empty, _}, {:error, reason}} ->
        GenServer.reply(from, {:error, reason})
        state

      {{:empty, _}, _} ->
        GenServer.reply(from, {:error, :unexpected_empty_queue})
        state
    end
  end

  defp reply_to_caller({from, :metadata}, state) do
    case state.status do
      :done -> GenServer.reply(from, {:ok, state.metadata})
      {:error, reason} -> GenServer.reply(from, {:error, reason})
      _ -> GenServer.reply(from, {:error, :not_ready})
    end

    state
  end

  defp cleanup_resources(state) do
    # Kill HTTP task if running
    if state.http_task && Process.alive?(state.http_task) do
      Process.exit(state.http_task, :cancelled)
    end

    state
  end

  defp build_http_error(status, chunk) do
    case Jason.decode(chunk) do
      {:ok, %{"error" => error_data}} when is_map(error_data) ->
        message = Map.get(error_data, "message", "HTTP #{status}")

        ReqLLM.Error.API.Request.exception(
          reason: message,
          status: status,
          response_body: error_data
        )

      {:ok, decoded} ->
        ReqLLM.Error.API.Request.exception(
          reason: "HTTP #{status}",
          status: status,
          response_body: decoded
        )

      {:error, _} ->
        ReqLLM.Error.API.Request.exception(
          reason: "HTTP #{status}",
          status: status,
          response_body: chunk
        )
    end
  end

  # Normalize streaming usage data from provider format to ReqLLM format
  # This mirrors the logic in ReqLLM.Step.Usage.fallback_extract_usage/1
  defp normalize_streaming_usage(usage, model) when is_map(usage) do
    case usage do
      %{"prompt_tokens" => input, "completion_tokens" => output} ->
        reasoning = reasoning_from_usage(usage)
        cached_input = cached_from_usage(usage)

        %{input: input, output: output, reasoning: reasoning, cached_input: cached_input}
        |> add_token_aliases()
        |> add_cost_calculation_if_available(usage)
        |> calculate_cost_if_model_available(model)

      %{"input_tokens" => input, "output_tokens" => output} ->
        reasoning = reasoning_from_usage(usage)
        cached_input = cached_from_usage(usage)

        %{input: input, output: output, reasoning: reasoning, cached_input: cached_input}
        |> add_token_aliases()
        |> add_cost_calculation_if_available(usage)
        |> calculate_cost_if_model_available(model)

      %{input_tokens: input, output_tokens: output} ->
        cached_input = Map.get(usage, :cached_tokens, 0)
        reasoning = Map.get(usage, :reasoning_tokens, 0)
        cache_read = Map.get(usage, :cache_read_input_tokens, 0)
        cache_creation = Map.get(usage, :cache_creation_input_tokens, 0)

        %{input: input, output: output, reasoning: reasoning, cached_input: cached_input}
        |> Map.put(:cache_read_input_tokens, cache_read)
        |> Map.put(:cache_creation_input_tokens, cache_creation)
        |> add_token_aliases()
        |> add_cost_calculation_if_available(usage)
        |> calculate_cost_if_model_available(model)

      _ ->
        usage
    end
  end

  defp normalize_streaming_usage(usage, _model), do: usage

  defp reasoning_from_usage(usage) do
    get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) ||
      get_in(usage, ["output_tokens_details", "reasoning_tokens"]) ||
      Map.get(usage, "reasoning_tokens", 0) ||
      Map.get(usage, "reasoning_output_tokens", 0)
  end

  defp cached_from_usage(usage) do
    get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
      get_in(usage, ["input_tokens_details", "cached_tokens"]) ||
      Map.get(usage, "cache_read_input_tokens", 0) ||
      Map.get(usage, "cached_tokens", 0)
  end

  defp add_token_aliases(usage) do
    usage
    |> Map.put(:input_tokens, usage.input)
    |> Map.put(:output_tokens, usage.output)
    |> Map.put(:total_tokens, usage.input + usage.output)
  end

  defp add_cost_calculation_if_available(normalized_usage, original_usage) do
    # If the original usage had cost information, preserve it
    # This might come from providers that calculate costs themselves
    case original_usage do
      %{total_cost: cost} when is_number(cost) ->
        Map.put(normalized_usage, :total_cost, cost)

      %{"total_cost" => cost} when is_number(cost) ->
        Map.put(normalized_usage, :total_cost, cost)

      _ ->
        normalized_usage
    end
  end

  defp calculate_cost_if_model_available(usage, %LLMDB.Model{cost: cost_map})
       when is_map(cost_map) do
    # Calculate cost using the model's cost rates (mirrors ReqLLM.Step.Usage logic)
    input_rate = cost_map[:input] || cost_map["input"]
    output_rate = cost_map[:output] || cost_map["output"]

    cached_rate =
      cost_map[:cached_input] || cost_map["cached_input"] ||
        cost_map[:cache_read] || cost_map["cache_read"] ||
        input_rate

    case usage do
      %{input: input_tokens, output: output_tokens}
      when is_number(input_tokens) and is_number(output_tokens) and not is_nil(input_rate) and
             not is_nil(output_rate) ->
        cached_tokens = max(0, Map.get(usage, :cached_input, 0))
        uncached_tokens = max(input_tokens - cached_tokens, 0)

        # Calculate costs (rates are per million tokens)
        input_cost =
          Float.round(
            uncached_tokens / 1_000_000 * input_rate + cached_tokens / 1_000_000 * cached_rate,
            6
          )

        output_cost = Float.round(output_tokens / 1_000_000 * output_rate, 6)
        total_cost = Float.round(input_cost + output_cost, 6)

        usage
        |> Map.put(:input_cost, input_cost)
        |> Map.put(:output_cost, output_cost)
        |> Map.put(:total_cost, total_cost)

      _ ->
        usage
    end
  end

  defp calculate_cost_if_model_available(usage, _), do: usage
end

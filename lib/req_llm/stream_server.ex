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
        model: %ReqLLM.Model{...}
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

  @type server :: GenServer.server()
  @type status :: :init | :streaming | :done | {:error, any()}

  defstruct [
    :provider_mod,
    :model,
    :http_task,
    :fixture_path,
    :http_context,
    :canonical_json,
    sse_buffer: "",
    queue: :queue.new(),
    status: :init,
    consumer_refs: MapSet.new(),
    metadata: %{},
    high_watermark: 500,
    headers: [],
    http_status: nil,
    waiting_callers: []
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
        model: %ReqLLM.Model{provider: :openai, name: "gpt-4o"}
      )

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    provider_mod = Keyword.fetch!(opts, :provider_mod)
    model = Keyword.fetch!(opts, :model)

    state = %__MODULE__{
      provider_mod: provider_mod,
      model: model,
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
  @spec set_fixture_context(server(), ReqLLM.Streaming.FinchClient.HTTPContext.t(), any()) :: :ok
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
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:http_event, event}, from, state) do
    {:reply, reply, new_state} = process_http_event(event, state)
    GenServer.reply(from, reply)
    {:noreply, new_state}
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
              | waiting_callers: [{from, :next} | new_state.waiting_callers]
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
  def handle_call({:attach_http_task, task_pid}, _from, state) do
    Process.monitor(task_pid)
    new_state = %{state | http_task: task_pid, status: :streaming}
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:set_fixture_context, http_context, canonical_json}, _from, state) do
    new_state = %{
      state
      | http_context: http_context,
        canonical_json: canonical_json
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
        new_state = %{state | waiting_callers: [{from, :metadata} | state.waiting_callers]}
        {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{http_task: pid} = state) do
    Logger.debug("HTTP task #{inspect(pid)} terminated: #{inspect(reason)}")

    new_state =
      case reason do
        :normal -> finalize_stream(state)
        _ -> %{state | status: {:error, {:http_task_failed, reason}}}
      end

    new_state = reply_to_waiting_callers(new_state)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Other monitored process died, ignore
    {:noreply, state}
  end

  ## Private Functions

  defp process_http_event({:status, status}, state) do
    new_state = %{state | http_status: status}
    {:reply, :ok, new_state}
  end

  defp process_http_event({:headers, headers}, state) do
    new_state = %{state | headers: headers}
    {:reply, :ok, new_state}
  end

  defp process_http_event({:data, chunk}, state) do
    # Always process data chunks immediately - backpressure handled by GenServer mailbox
    process_data_chunk(chunk, state)
  end

  defp process_http_event(:done, state) do
    new_state = finalize_stream_with_fixture(state) |> reply_to_waiting_callers()
    {:reply, :ok, new_state}
  end

  defp process_http_event({:error, reason}, state) do
    new_state = %{state | status: {:error, reason}} |> reply_to_waiting_callers()
    {:reply, :ok, new_state}
  end

  defp process_data_chunk(chunk, state) do
    # Capture raw chunk for fixture system BEFORE processing
    if state.fixture_path && is_binary(chunk) do
      try do
        case Code.ensure_loaded(ReqLLM.Step.Fixture.Backend) do
          {:module, ReqLLM.Step.Fixture.Backend} ->
            apply(ReqLLM.Step.Fixture.Backend, :capture_raw_chunk, [state.fixture_path, chunk])

          {:error, _} ->
            :ok
        end
      rescue
        # Ignore fixture errors to avoid breaking streaming
        error ->
          Logger.debug("Fixture capture error (ignored): #{inspect(error)}")
      end
    end

    # Accumulate and parse SSE events
    {events, new_buffer} = SSE.accumulate_and_parse(chunk, state.sse_buffer)

    # Decode events using provider
    stream_chunks =
      events
      |> Enum.map(&SSE.process_sse_event/1)
      |> Enum.flat_map(fn event ->
        if termination_event?(event) do
          # Handle completion signal  
          []
        else
          # Let provider decode the event
          decode_provider_event(event, state.provider_mod, state.model)
        end
      end)

    # Enqueue chunks and check for completion
    new_state = enqueue_chunks(stream_chunks, %{state | sse_buffer: new_buffer})

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

  defp decode_provider_event(event, provider_mod, model) do
    if function_exported?(provider_mod, :decode_sse_event, 2) do
      provider_mod.decode_sse_event(event, model)
    else
      # Fall back to default decoding
      ReqLLM.Provider.Defaults.default_decode_sse_event(event, model)
    end
  end

  defp termination_event?(%{data: "[DONE]"}), do: true
  defp termination_event?(%{data: %{"done" => true}}), do: true
  defp termination_event?(%{data: %{"type" => "message_stop"}}), do: true
  defp termination_event?(_), do: false

  defp enqueue_chunks(chunks, state) do
    {new_queue, updated_metadata} =
      Enum.reduce(chunks, {state.queue, state.metadata}, fn chunk, {queue, metadata} ->
        # Enqueue the chunk
        new_queue = :queue.in(chunk, queue)

        # Accumulate metadata from meta chunks
        updated_metadata =
          case chunk.type do
            :meta ->
              # Extract usage data from the chunk's metadata
              usage =
                Map.get(chunk.metadata || %{}, :usage) || Map.get(chunk.metadata || %{}, "usage")

              if usage do
                # Normalize usage data from provider format to ReqLLM format
                normalized_usage = normalize_streaming_usage(usage, state.model)
                Map.update(metadata, :usage, normalized_usage, &Map.merge(&1, normalized_usage))
              else
                metadata
              end

            _ ->
              metadata
          end

        {new_queue, updated_metadata}
      end)

    %{state | queue: new_queue, metadata: updated_metadata}
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
    # Extract any final metadata from the last chunks
    metadata = extract_final_metadata(state)
    %{state | status: :done, metadata: metadata}
  end

  defp finalize_stream_with_fixture(state) do
    # Save fixture if needed
    if state.fixture_path && state.http_context && state.canonical_json do
      try do
        case Code.ensure_loaded(ReqLLM.Step.Fixture.Backend) do
          {:module, ReqLLM.Step.Fixture.Backend} ->
            apply(ReqLLM.Step.Fixture.Backend, :save_streaming_fixture, [
              state.http_context,
              state.fixture_path,
              state.canonical_json
            ])

          {:error, _} ->
            :ok
        end
      rescue
        # Log fixture errors but don't break streaming
        error ->
          Logger.warning("Failed to save streaming fixture: #{inspect(error)}")
      end
    end

    # Continue with normal finalization
    finalize_stream(state)
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

  # Normalize streaming usage data from provider format to ReqLLM format
  # This mirrors the logic in ReqLLM.Step.Usage.fallback_extract_usage/1
  defp normalize_streaming_usage(usage, model) when is_map(usage) do
    case usage do
      %{"prompt_tokens" => input, "completion_tokens" => output} ->
        # OpenAI format
        %{input: input, output: output, reasoning: 0, cached_input: 0}
        |> add_cost_calculation_if_available(usage)
        |> calculate_cost_if_model_available(model)

      %{"input_tokens" => input, "output_tokens" => output} ->
        # Anthropic format (string keys)
        cached_input = Map.get(usage, "cache_read_input_tokens", 0)

        %{input: input, output: output, reasoning: 0, cached_input: cached_input}
        |> add_cost_calculation_if_available(usage)
        |> calculate_cost_if_model_available(model)

      %{input_tokens: input, output_tokens: output} ->
        # Already normalized format  
        %{input: input, output: output, reasoning: 0, cached_input: 0}
        |> add_cost_calculation_if_available(usage)
        |> calculate_cost_if_model_available(model)

      _ ->
        # Unknown format, pass through
        usage
    end
  end

  defp normalize_streaming_usage(usage, _model), do: usage

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

  defp calculate_cost_if_model_available(usage, %ReqLLM.Model{cost: cost_map})
       when is_map(cost_map) do
    # Calculate cost using the model's cost rates (mirrors ReqLLM.Step.Usage logic)
    input_rate = cost_map[:input] || cost_map["input"]
    output_rate = cost_map[:output] || cost_map["output"]

    cached_rate =
      cost_map[:cached_input] || cost_map["cached_input"] ||
        cost_map[:cache_read] || cost_map["cache_read"] ||
        input_rate

    with %{input: input_tokens, output: output_tokens} <- usage,
         true <- is_number(input_tokens) and is_number(output_tokens),
         true <- input_rate != nil and output_rate != nil do
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
      |> Map.put(:input_tokens, input_tokens)
      |> Map.put(:output_tokens, output_tokens)
      |> Map.put(:total_tokens, input_tokens + output_tokens)
    else
      _ -> usage
    end
  end

  defp calculate_cost_if_model_available(usage, _), do: usage
end

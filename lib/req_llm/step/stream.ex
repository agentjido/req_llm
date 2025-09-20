defmodule ReqLLM.Step.Stream do
  @moduledoc """
  Req step for handling Server-Sent Events (SSE) in provider-agnostic streaming responses.

  This step processes "text/event-stream" responses and converts them into
  enumerable chunks of standardized SSE events. The parsed events are then
  processed by provider-specific `ReqLLM.Response.Codec.decode_sse_event/1`
  protocol implementations to convert them into `ReqLLM.StreamChunk` structures.

  ## Purpose

  This step serves as the first stage in a two-phase streaming pipeline:

  1. **SSE Parsing (this step)**: Converts raw SSE stream into structured events
  2. **Provider Decoding**: Provider protocols convert events into StreamChunks

  Non-streaming responses are passed through unchanged.

  ## Usage

      request
      |> ReqLLM.Step.Stream.attach()

  The step automatically detects SSE responses by content type and processes
  them into structured chunks. Each parsed SSE event contains:

  - `event` - The event type (e.g., "delta", "done")
  - `data` - The event data (JSON parsed if valid)
  - `id` - Event ID (if present)
  - `retry` - Retry interval (if present)

  ## Processing Pipeline

      Raw SSE Stream
           ↓
      ReqLLM.Step.Stream (this module)
           ↓
      Structured SSE Events
           ↓
      Provider's decode_sse_event/1
           ↓
      ReqLLM.StreamChunk structures

  ## Examples

      # Streaming response - produces Stream of parsed SSE events
      response = Req.get!(req, url: "https://api.example.com/stream", stream: true)
      response.body
      #=> %Stream{} containing parsed SSE events like %{event: "completion", data: %{...}}

      # Provider then processes these events:
      response.body
      |> Stream.flat_map(&ReqLLM.Response.Codec.decode_sse_event/1)
      #=> Stream of %ReqLLM.StreamChunk{} structs

      # Non-streaming response
      response = Req.get!(req, url: "https://api.example.com/chat")
      response.body
      #=> "Regular JSON response"

  """

  require Logger

  @doc """
  Attaches the SSE streaming step to a Req request struct.

  ## Parameters
    - `req` - The Req request struct

  ## Returns
    - Updated Req request struct with the step attached

  """
  @spec attach(Req.Request.t()) :: Req.Request.t()
  def attach(req) do
    Req.Request.append_response_steps(req, stream_sse: &__MODULE__.handle/1)
  end

  @doc """
  Conditionally attaches basic SSE streaming to a Req request struct.

  This is a simple helper for cases where only basic SSE parsing is needed
  without real-time streaming or model-specific decoding.

  ## Parameters
    - `req` - The Req request struct
    - `stream_enabled` - Whether streaming is enabled (falsy values: false, nil, 0, "", [])

  ## Returns
    - Updated Req request struct with SSE streaming attached or unchanged

  ## Examples

      # Streaming enabled - attaches basic SSE parsing
      request |> ReqLLM.Step.Stream.maybe_attach(true)

      # Streaming disabled - request unchanged (falsy values)
      request |> ReqLLM.Step.Stream.maybe_attach(false)
      request |> ReqLLM.Step.Stream.maybe_attach(nil)
      request |> ReqLLM.Step.Stream.maybe_attach(0)

  """
  @spec maybe_attach(Req.Request.t(), any()) :: Req.Request.t()
  def maybe_attach(req, stream_enabled) do
    case stream_enabled do
      false -> req
      nil -> req
      0 -> req
      "" -> req
      [] -> req
      _ -> attach(req)
    end
  end

  @doc """
  Conditionally attaches real-time streaming to a Req request struct with model support.

  This method processes chunks as they arrive and stores the stream in request 
  private data for provider access. This is the primary streaming method.

  ## Parameters
    - `req` - The Req request struct
    - `stream_enabled` - Whether streaming is enabled
    - `model` - The ReqLLM.Model for provider-specific decoding

  ## Returns
    - Updated Req request struct with real-time streaming attached and stream stored

  ## Examples

      # Real-time streaming enabled - attaches streaming and stores stream
      request |> ReqLLM.Step.Stream.maybe_attach(true, model)

      # Streaming disabled - request unchanged
      request |> ReqLLM.Step.Stream.maybe_attach(false, model)

  """
  @spec maybe_attach(Req.Request.t(), boolean(), ReqLLM.Model.t()) :: Req.Request.t()
  def maybe_attach(req, false, _model), do: req

  def maybe_attach(req, true, model) do
    {req_with_stream, stream} = attach_real_time(req, true, model)

    # Store the stream in the request so decode_response can use it
    Req.Request.put_private(req_with_stream, :real_time_stream, stream)
  end

  @doc """
  Attaches real-time streaming to a Req request using :into callback.

  This method processes SSE chunks as they arrive from the network instead of
  waiting for the complete response. It returns a Stream that yields chunks
  in real-time.

  ## Parameters
    - `req` - The Req request struct
    - `stream_enabled` - Whether streaming is enabled
    - `model` - The ReqLLM.Model for provider-specific decoding

  ## Returns
    - `{updated_request, stream}` where stream yields ReqLLM.StreamChunk structs

  ## Examples

      {request, stream} = ReqLLM.Step.Stream.attach_real_time(request, true, model)
      Task.async(fn -> Req.request(request) end)
      stream |> Enum.each(&IO.inspect/1)

  """
  @spec attach_real_time(Req.Request.t(), boolean(), ReqLLM.Model.t()) ::
          {Req.Request.t(), Enumerable.t()}
  def attach_real_time(req, false, _model), do: {req, []}

  def attach_real_time(req, true, model) do
    owner_pid = self()

    # Create the :into callback that processes chunks as they arrive
    into_callback = fn
      {:data, chunk}, {req, resp} ->
        # Capture raw chunk for fixture system BEFORE processing
        if path = Req.Request.get_private(req, :llm_fixture_path) do
          # Call fixture backend to capture the raw chunk
          case Code.ensure_loaded(ReqLLM.Step.Fixture.Backend) do
            {:module, ReqLLM.Step.Fixture.Backend} ->
              apply(ReqLLM.Step.Fixture.Backend, :capture_raw_chunk, [path, chunk])

            {:error, _} ->
              # No fixture backend available
              :ok
          end
        end

        buffer = Req.Request.get_private(req, :sse_buffer, "")
        {events, remaining_buffer} = ServerSentEvents.parse(buffer <> chunk)
        req_with_buffer = Req.Request.put_private(req, :sse_buffer, remaining_buffer)

        # Process events and send to owner process
        parsed_events = Enum.map(events, &process_sse_event/1)

        # Check for DONE events to terminate stream
        has_done_event =
          Enum.any?(parsed_events, fn event ->
            case event do
              %{data: "[DONE]"} -> true
              %{data: %{"choices" => [%{"finish_reason" => reason}]}} when reason != nil -> true
              _ -> false
            end
          end)

        if has_done_event do
          send(owner_pid, :stream_done)
        end

        decoded_chunks =
          parsed_events
          |> Enum.flat_map(&ReqLLM.Response.Codec.decode_sse_event(&1, model))
          |> Enum.reject(&is_nil/1)

        if decoded_chunks != [] do
          send(owner_pid, {:stream_chunks, decoded_chunks})
        end

        {:cont, {req_with_buffer, resp}}

      {:status, _status}, acc ->
        {:cont, acc}

      {:headers, _headers}, acc ->
        {:cont, acc}

      :done, acc ->
        # Save fixture when streaming is complete
        {req, resp} = acc

        if _path = Req.Request.get_private(req, :llm_fixture_path) do
          case Code.ensure_loaded(ReqLLM.Step.Fixture.Backend) do
            {:module, ReqLLM.Step.Fixture.Backend} ->
              apply(ReqLLM.Step.Fixture.Backend, :save_streaming_fixture, [req, resp])

            {:error, _} ->
              # No fixture backend available
              :ok
          end
        end

        send(owner_pid, :stream_done)
        {:cont, acc}

      _other, acc ->
        {:cont, acc}
    end

    # Build the real-time stream using Stream.resource
    stream =
      Stream.resource(
        fn -> :receiving end,
        fn
          :receiving ->
            receive do
              {:stream_chunks, chunks} -> {chunks, :receiving}
              :stream_done -> {:halt, :done}
            after
              30_000 -> {:halt, :timeout}
            end

          state ->
            {:halt, state}
        end,
        fn _ -> :ok end
      )

    # Store the :into callback in request private data for use during execution
    updated_req = Req.Request.put_private(req, :streaming_into_callback, into_callback)

    {updated_req, stream}
  end

  @doc false
  @spec handle({Req.Request.t(), Req.Response.t()}) ::
          {Req.Request.t(), Req.Response.t()}
  def handle({req, resp} = pair) do
    content_type =
      case Req.Response.get_header(resp, "content-type") do
        [ct | _] when is_binary(ct) -> ct
        [] -> nil
      end

    if content_type && String.contains?(content_type, "text/event-stream") do
      stream = parse_sse_stream(resp.body)
      {req, %{resp | body: stream}}
    else
      pair
    end
  end

  @spec parse_sse_stream(binary() | Enumerable.t()) :: Enumerable.t()
  defp parse_sse_stream(body) when is_binary(body) do
    {events, _remaining} = ServerSentEvents.parse(body)
    to_event_stream(events)
  end

  defp parse_sse_stream(stream) when is_struct(stream, Stream) do
    stream
    |> Stream.transform("", &accumulate_and_parse/2)
    |> Stream.flat_map(& &1)
    |> to_event_stream()
  end

  defp to_event_stream(events) do
    events
    |> Stream.map(&process_sse_event/1)
    |> Stream.reject(&is_nil/1)
  end

  @spec accumulate_and_parse(binary(), binary()) :: {[map()], binary()}
  defp accumulate_and_parse(chunk, buffer) do
    combined = buffer <> chunk
    {events, remaining} = ServerSentEvents.parse(combined)
    {events, remaining}
  end

  @spec process_sse_event(map()) :: map() | nil
  defp process_sse_event(%{data: data} = event) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, parsed} when is_map(parsed) -> %{event | data: parsed}
      {:error, _} -> event
    end
  end

  defp process_sse_event(event), do: event
end

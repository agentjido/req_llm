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
  Conditionally attaches the SSE streaming step to a Req request struct.

  ## Parameters
    - `req` - The Req request struct
    - `stream_enabled` - Whether streaming is enabled

  ## Returns
    - Updated Req request struct with the step attached if streaming is enabled

  ## Examples

      # Streaming enabled - step attached
      request |> ReqLLM.Step.Stream.maybe_attach(true)

      # Streaming disabled - request unchanged
      request |> ReqLLM.Step.Stream.maybe_attach(false)

  """
  @spec maybe_attach(Req.Request.t(), boolean()) :: Req.Request.t()
  def maybe_attach(req, true), do: attach(req)
  def maybe_attach(req, _), do: req

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

defmodule ReqLLM.Bedrock.BidiStream do
  @moduledoc """
  Low-level client for AWS Bedrock `InvokeModelWithBidirectionalStream`
  (e.g. Amazon Nova Sonic speech-to-speech).

  Bidirectional streaming is HTTP/2 full-duplex: the client opens one request,
  streams SigV4 event-signed messages over time, and concurrently reads response
  event-stream messages back. This mirrors the shape of `ReqLLM.OpenAI.Realtime`
  (`connect`, `send_event`, `next_event`, `close`) but the transport is
  `ReqLLM.Streaming.HTTP2DuplexSession` (Mint HTTP/2), since the WebSockex-based
  `WebSocketSession` cannot do HTTP/2.

  Each outbound event is framed as an AWS event-stream message whose payload is
  `{"bytes": "<base64 of the event JSON>"}` (the `BidirectionalInputPayloadPart`
  blob), wrapped in an outer signed message carrying `:date` and
  `:chunk-signature`, chained from the initial request's seed signature. Signing
  uses `AWSAuth.EventStream`. Inbound messages are decoded with the existing
  `ReqLLM.Providers.AmazonBedrock.AWSEventStream` parser.

  Reads and writes are independent: `next_event/2` parks asynchronously without
  blocking the session, so one process can stream audio via `send_event/2` while
  another consumes responses.
  """

  use GenServer

  alias ReqLLM.Providers.AmazonBedrock.AWSAuthAdapter
  alias ReqLLM.Providers.AmazonBedrock.AWSEventStream
  alias ReqLLM.Streaming.HTTP2DuplexSession, as: Session

  defstruct [
    :session,
    :secret_key,
    :region,
    :service,
    :prior_signature,
    buffer: <<>>,
    queue: :queue.new(),
    waiting: [],
    status: :open
  ]

  defmodule Conn do
    @moduledoc "Handle to a running bidirectional Bedrock session."
    @enforce_keys [:pid, :model_id]
    defstruct [:pid, :model_id]
    @type t :: %__MODULE__{pid: pid(), model_id: String.t()}
  end

  @doc """
  Opens a bidirectional stream to `model_id` (e.g. `"amazon.nova-sonic-v1:0"`).

  Options:
    * `:credentials` - an `%AWSAuth.Credentials{}` (defaults to `AWSAuth.Credentials.from_env/0`)
    * `:region` - overrides the region from the credentials
    * `:connect_timeout` - ms to wait for the HTTP/2 request to open (default 15s)
  """
  @spec connect(String.t(), keyword()) :: {:ok, Conn.t()} | {:error, term()}
  def connect(model_id, opts \\ []) when is_binary(model_id) do
    AWSAuthAdapter.ensure_available!()

    with {:ok, pid} <- GenServer.start_link(__MODULE__, {model_id, opts}),
         :ok <- GenServer.call(pid, :await_connected, Keyword.get(opts, :connect_timeout, 15_000)) do
      {:ok, %Conn{pid: pid, model_id: model_id}}
    end
  end

  @doc "Encode, sign, and send one model input event (a JSON-serializable map)."
  @spec send_event(Conn.t(), map()) :: :ok | {:error, term()}
  def send_event(%Conn{pid: pid}, event) when is_map(event),
    do: GenServer.call(pid, {:send_event, event})

  @doc "Pull the next decoded inbound event. `:halt` once the stream ends."
  @spec next_event(Conn.t(), timeout()) :: {:ok, map()} | :halt | {:error, term()}
  def next_event(%Conn{pid: pid}, timeout \\ 30_000),
    do: GenServer.call(pid, {:next_event, timeout}, timeout + 1000)

  @doc "Signal end of the outbound stream (half-close the request body)."
  @spec done_sending(Conn.t()) :: :ok | {:error, term()}
  def done_sending(%Conn{pid: pid}), do: GenServer.call(pid, :done_sending)

  @doc "Transport status + HTTP response status (for diagnostics)."
  @spec info(Conn.t()) :: map()
  def info(%Conn{pid: pid}), do: GenServer.call(pid, :info)

  @spec close(Conn.t()) :: :ok
  def close(%Conn{pid: pid}), do: GenServer.call(pid, :close)

  # --- GenServer ---

  @impl GenServer
  def init({model_id, opts}) do
    creds = Keyword.get(opts, :credentials) || AWSAuthAdapter.from_env()
    region = (opts[:region] || Map.get(creds, :region) || "us-east-1") |> String.downcase()
    service = "bedrock"
    host = "bedrock-runtime.#{region}.amazonaws.com"
    path = "/model/#{model_id}/invoke-with-bidirectional-stream"
    url = "https://#{host}#{path}"

    {headers, seed_sig} = sign_seed(creds, region, service, host, url)

    case Session.start_link("POST", url, headers, self()) do
      {:ok, session} ->
        {:ok,
         %__MODULE__{
           session: session,
           secret_key: Map.get(creds, :secret_access_key),
           region: region,
           service: service,
           prior_signature: seed_sig
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:await_connected, _from, state),
    do: {:reply, Session.await_connected(state.session), state}

  def handle_call({:send_event, event}, _from, state) do
    {frame, sig} = build_signed_frame(state, event)

    case Session.send_data(state.session, frame) do
      :ok -> {:reply, :ok, %{state | prior_signature: sig}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:next_event, _timeout}, from, state) do
    case :queue.out(state.queue) do
      {{:value, event}, queue} ->
        {:reply, {:ok, event}, %{state | queue: queue}}

      {:empty, _} ->
        case state.status do
          :closed -> {:reply, :halt, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
          :open -> {:noreply, %{state | waiting: state.waiting ++ [from]}}
        end
    end
  end

  def handle_call(:done_sending, _from, state),
    do: {:reply, Session.done_sending(state.session), state}

  def handle_call(:info, _from, state), do: {:reply, Session.info(state.session), state}

  def handle_call(:close, _from, state) do
    Session.close(state.session)
    {:stop, :normal, :ok, state}
  end

  # Inbound data pushed from the transport — decode and dispatch (never blocks sends).
  @impl GenServer
  def handle_info({:http2_duplex, _pid, {:data, chunk}}, state) do
    {events, rest} = decode_inbound(state.buffer <> chunk)
    {:noreply, Enum.reduce(events, %{state | buffer: rest}, &dispatch(&2, &1))}
  end

  def handle_info({:http2_duplex, _pid, {:done, _status, _headers}}, state),
    do: {:noreply, finish(state, :closed)}

  def handle_info({:http2_duplex, _pid, {:error, reason}}, state),
    do: {:noreply, finish(state, {:error, reason})}

  def handle_info(_msg, state), do: {:noreply, state}

  # Hand a decoded event to a parked next_event caller, else queue it.
  defp dispatch(%{waiting: [from | rest]} = state, event) do
    GenServer.reply(from, {:ok, event})
    %{state | waiting: rest}
  end

  defp dispatch(state, event), do: %{state | queue: :queue.in(event, state.queue)}

  defp finish(state, status) do
    reply = if status == :closed, do: :halt, else: status
    Enum.each(state.waiting, &GenServer.reply(&1, reply))
    %{state | waiting: [], status: status}
  end

  # --- AWS event-stream encoding (request side) ---

  # Two-layer signing: the inner application message (chunk headers + payload) is
  # wrapped in an outer signed message (:date + :chunk-signature), chained from
  # the prior signature. Returns {outer_frame, hex_signature}.
  defp build_signed_frame(state, event) do
    creds =
      AWSAuthAdapter.credentials_struct(secret_access_key: state.secret_key, region: state.region)

    AWSAuthAdapter.event_stream_sign_message(
      creds,
      state.service,
      state.prior_signature,
      build_inner(event),
      DateTime.utc_now()
    )
  end

  @doc false
  # Decode any complete inbound event-stream messages from `buffer`, returning
  # {decoded_events, remaining_buffer}. Exposed for testing.
  def decode_inbound(buffer) do
    case AWSEventStream.parse_binary(buffer) do
      {:ok, events, tail} -> {events, tail}
      {:incomplete, data} -> {[], data}
      {:error, _reason} -> {[], buffer}
    end
  end

  @doc false
  # Inner application message: the Bedrock input chunk (union member "chunk").
  # The event JSON is the `bytes` blob of BidirectionalInputPayloadPart; under the
  # application/json payload codec that serializes as {"bytes": "<base64>"}.
  # Exposed for testing.
  def build_inner(event) do
    headers =
      AWSAuthAdapter.event_stream_encode_string_header(":content-type", "application/json") <>
        AWSAuthAdapter.event_stream_encode_string_header(":event-type", "chunk") <>
        AWSAuthAdapter.event_stream_encode_string_header(":message-type", "event")

    payload = Jason.encode!(%{"bytes" => Base.encode64(Jason.encode!(event))})
    AWSAuthAdapter.event_stream_encode_message(headers, payload)
  end

  @doc false
  # Seed signature: sign the initial request with the streaming-events content
  # hash; the resulting Authorization signature seeds the per-event chain. The
  # region is passed explicitly so the seed scope matches the host and the
  # per-event signatures even when it overrides the credential's region.
  # Returns {request_headers, seed_signature_hex}. Exposed for testing.
  def sign_seed(creds, region, service, host, url) do
    signed =
      AWSAuthAdapter.sign_authorization_header(
        creds,
        "POST",
        url,
        service,
        headers: %{"host" => host},
        payload: :streaming_events,
        region: region,
        return_format: :map
      )

    [_, sig] = Regex.run(~r/Signature=([0-9a-f]+)/, signed["authorization"])

    headers =
      signed
      |> Map.merge(%{
        "content-type" => "application/vnd.amazon.eventstream",
        "x-amzn-bedrock-accept" => "application/vnd.amazon.eventstream"
      })
      |> Enum.to_list()

    {headers, sig}
  end
end

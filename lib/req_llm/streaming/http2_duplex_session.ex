defmodule ReqLLM.Streaming.HTTP2DuplexSession do
  @moduledoc false

  # Generic full-duplex HTTP/2 session built on Mint.
  #
  # Opens a single HTTP/2 request with a streaming body, lets the caller push
  # request DATA frames over time (`send_data/2`) while concurrently delivering
  # response DATA frames back to the owning process as messages — i.e. true
  # bidirectional streaming on one stream. This is the transport AWS Bedrock
  # `InvokeModelWithBidirectionalStream` (e.g. Nova Sonic) needs, which the
  # WebSockex-based `ReqLLM.Streaming.WebSocketSession` cannot provide (that is
  # RFC6455 websockets, not HTTP/2).
  #
  # It is provider-agnostic: it sends and receives opaque binaries. Framing,
  # signing, and decoding live in the caller (see `ReqLLM.Bedrock.BidiStream`).
  #
  # Inbound data is delivered to the `owner` process as messages, mirroring
  # `WebSocketSession`:
  #
  #     {:http2_duplex, pid, {:data, binary}}
  #     {:http2_duplex, pid, {:done, http_status, headers}}
  #     {:http2_duplex, pid, {:error, reason}}
  #
  # so the owner can both send and receive without either blocking the other.

  use GenServer

  @type t :: pid()

  defstruct [
    :conn,
    :ref,
    :owner,
    status: :connecting,
    http_status: nil,
    resp_headers: [],
    eof_sent: false,
    out_buffer: :queue.new()
  ]

  @doc """
  Opens an HTTP/2 request with a streaming request body. Inbound data is sent to
  `owner` as `{:http2_duplex, pid, ...}` messages.

  `headers` is a list of `{name, value}` tuples (e.g. already SigV4-signed). The
  `host` header is dropped if present — HTTP/2 carries it as the `:authority`
  pseudo-header, which Mint derives from the connection.
  """
  @spec start_link(String.t(), String.t(), [{String.t(), String.t()}], pid(), keyword()) ::
          GenServer.on_start()
  def start_link(method, url, headers, owner, opts \\ []) do
    GenServer.start_link(__MODULE__, {method, url, headers, owner, opts})
  end

  @spec await_connected(t()) :: :ok | {:error, term()}
  def await_connected(server), do: GenServer.call(server, :await_connected)

  @doc "Push a request body chunk (an HTTP/2 DATA frame), respecting flow control."
  @spec send_data(t(), iodata()) :: :ok | {:error, term()}
  def send_data(server, data), do: GenServer.call(server, {:send_data, data})

  @doc "Half-close the request body (send end-of-stream)."
  @spec done_sending(t()) :: :ok | {:error, term()}
  def done_sending(server), do: GenServer.call(server, :done_sending)

  @doc "Transport status + HTTP response status seen so far."
  @spec info(t()) :: %{status: term(), http_status: non_neg_integer() | nil, resp_headers: list()}
  def info(server), do: GenServer.call(server, :info)

  @spec close(t()) :: :ok
  def close(server), do: GenServer.call(server, :close)

  @impl GenServer
  def init({method, url, headers, owner, _opts}) do
    uri = URI.parse(url)
    port = uri.port || 443
    path = path_with_query(uri)
    req_headers = Enum.reject(headers, fn {k, _} -> String.downcase(k) == "host" end)

    with {:ok, conn} <-
           Mint.HTTP2.connect(:https, uri.host, port, mode: :active),
         {:ok, conn, ref} <-
           Mint.HTTP2.request(conn, String.upcase(method), path, req_headers, :stream) do
      {:ok, %__MODULE__{conn: conn, ref: ref, owner: owner, status: :open}}
    else
      {:error, reason} -> {:stop, reason}
      {:error, _conn, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:await_connected, _from, %{status: :open} = state), do: {:reply, :ok, state}
  def handle_call(:await_connected, _from, %{status: s} = state), do: {:reply, {:error, s}, state}

  def handle_call({:send_data, _data}, _from, %{status: status} = state) when status != :open,
    do: {:reply, send_error(status), state}

  def handle_call({:send_data, data}, _from, state),
    do: {:reply, :ok, flush(%{state | out_buffer: :queue.in(data, state.out_buffer)})}

  def handle_call(:done_sending, _from, %{eof_sent: true} = state), do: {:reply, :ok, state}

  def handle_call(:done_sending, _from, %{status: :open} = state),
    do: {:reply, :ok, flush(%{state | out_buffer: :queue.in(:eof, state.out_buffer)})}

  def handle_call(:done_sending, _from, %{status: status} = state),
    do: {:reply, send_error(status), state}

  def handle_call(:info, _from, state) do
    {:reply,
     %{status: state.status, http_status: state.http_status, resp_headers: state.resp_headers},
     state}
  end

  def handle_call(:close, _from, state) do
    if state.conn, do: Mint.HTTP2.close(state.conn)
    {:stop, :normal, :ok, %{state | status: :closed, conn: nil}}
  end

  @impl GenServer
  def handle_info(message, %{conn: conn} = state) when not is_nil(conn) do
    case Mint.HTTP2.stream(conn, message) do
      {:ok, conn, responses} ->
        # Incoming frames may include WINDOW_UPDATEs — try to drain the outbound buffer.
        {:noreply, flush(apply_responses(%{state | conn: conn}, responses))}

      {:error, conn, reason, responses} ->
        state = apply_responses(%{state | conn: conn}, responses)
        # A reset after the response already completed (`:done`) is benign.
        state = if open?(state.status), do: notify_error(state, reason), else: state
        {:noreply, state}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp apply_responses(state, responses) do
    Enum.reduce(responses, state, fn
      {:status, ref, code}, %{ref: ref} = st ->
        %{st | http_status: code}

      {:headers, ref, hdrs}, %{ref: ref} = st ->
        %{st | resp_headers: st.resp_headers ++ hdrs}

      {:data, ref, data}, %{ref: ref} = st ->
        notify(st, {:data, data})
        st

      {:done, ref}, %{ref: ref} = st ->
        if open?(st.status) do
          notify(st, {:done, st.http_status, st.resp_headers})
          %{st | status: :closed}
        else
          st
        end

      {:error, ref, reason}, %{ref: ref} = st ->
        notify_error(st, reason)

      _other, st ->
        st
    end)
  end

  defp notify(%{owner: owner}, payload), do: send(owner, {:http2_duplex, self(), payload})

  defp notify_error(state, reason) do
    notify(state, {:error, reason})
    %{state | status: {:error, reason}}
  end

  # Drain the outbound buffer within the HTTP/2 send window (connection + stream),
  # splitting a chunk when only part fits; stops when the window is empty (a later
  # WINDOW_UPDATE re-triggers this via handle_info).
  defp flush(%{conn: nil} = state), do: state

  defp flush(state) do
    case :queue.peek(state.out_buffer) do
      :empty ->
        state

      {:value, :eof} ->
        case Mint.HTTP2.stream_request_body(state.conn, state.ref, :eof) do
          {:ok, conn} ->
            %{state | conn: conn, eof_sent: true, out_buffer: :queue.drop(state.out_buffer)}

          {:error, conn, _reason} ->
            %{state | conn: conn}
        end

      {:value, data} ->
        window =
          min(
            Mint.HTTP2.get_window_size(state.conn, :connection),
            Mint.HTTP2.get_window_size(state.conn, {:request, state.ref})
          )

        cond do
          window <= 0 ->
            state

          byte_size(data) <= window ->
            send_chunk(state, data, :queue.drop(state.out_buffer))

          true ->
            head = binary_part(data, 0, window)
            tail = binary_part(data, window, byte_size(data) - window)
            send_chunk(state, head, :queue.in_r(tail, :queue.drop(state.out_buffer)))
        end
    end
  end

  defp send_chunk(state, chunk, rest_buffer) do
    case Mint.HTTP2.stream_request_body(state.conn, state.ref, chunk) do
      {:ok, conn} -> flush(%{state | conn: conn, out_buffer: rest_buffer})
      {:error, conn, _reason} -> %{state | conn: conn}
    end
  end

  defp open?(status), do: status in [:connecting, :open]

  defp send_error(:closed), do: {:error, :closed}
  defp send_error({:error, reason}), do: {:error, reason}
  defp send_error(_), do: {:error, :not_connected}

  defp path_with_query(%URI{path: path, query: nil}), do: path || "/"
  defp path_with_query(%URI{path: path, query: q}), do: "#{path || "/"}?#{q}"
end

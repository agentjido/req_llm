defmodule ReqLLM.Test.Google.InteractionsAPIHelpers do
  @moduledoc """
  Shared HTTP plug, SSE framing, and process-link helpers for Google Interactions API tests.
  """

  defmodule SSEPlug do
    @moduledoc false

    def init(opts), do: opts

    def call(conn, opts) do
      owner = Keyword.fetch!(opts, :owner)
      events = Keyword.get(opts, :events, [])
      resume_events = Keyword.get(opts, :resume_events, [])
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.request_path} do
        {"POST", "/v1/interactions"} ->
          {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
          send(owner, {:post_stream, conn.req_headers, Jason.decode!(raw_body)})
          send_sse(conn, events)

        {"GET", "/v1/interactions/" <> id} ->
          send(owner, {:get_resume, id, conn.query_params, conn.req_headers})

          if Keyword.get(opts, :v1_not_found, false) do
            Plug.Conn.send_resp(
              conn,
              404,
              Jason.encode!(%{"error" => %{"message" => "Not found"}})
            )
          else
            send_sse(conn, resume_events)
          end

        {"GET", "/v1beta/interactions/" <> id} ->
          send(owner, {:get_resume_v1beta, id, conn.query_params, conn.req_headers})
          send_sse(conn, Keyword.get(opts, :v1beta_resume_events, resume_events))
      end
    end

    defp send_sse(conn, frames) do
      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      Enum.reduce_while(frames, conn, fn frame, acc ->
        case Plug.Conn.chunk(acc, frame) do
          {:ok, next_conn} -> {:cont, next_conn}
          {:error, _} -> {:halt, acc}
        end
      end)
    end
  end

  def inline_json_plug(responder) when is_function(responder, 1) do
    fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)

      decoded_body =
        case raw_body do
          "" -> nil
          json -> Jason.decode!(json)
        end

      conn = Plug.Conn.fetch_query_params(conn)
      {status, resp_body} = responder.(%{conn: conn, body: decoded_body})
      Req.Test.json(%{conn | status: status}, resp_body)
    end
  end

  def sse_frame(payload, event_id) when is_map(payload) do
    id_line = if(event_id, do: "id: #{event_id}\n", else: "")
    "event: #{payload["event_type"]}\n#{id_line}data: #{Jason.encode!(payload)}\n\n"
  end

  def await_extra_links(links_before, expected, attempts \\ 30) do
    {:links, links_now} = Process.info(self(), :links)
    extra = Enum.sort(links_now -- links_before)
    expected_sorted = Enum.sort(expected)

    if extra == expected_sorted or attempts <= 0 do
      extra
    else
      Process.sleep(10)
      await_extra_links(links_before, expected, attempts - 1)
    end
  end
end

defmodule ReqLLM.StreamingCleanupTest do
  use ExUnit.Case, async: false

  alias ReqLLM.{Context, StreamChunk, Streaming, StreamResponse}

  defmodule FailingHTTP do
    def attach_stream(_, _, _, _), do: {:error, :probe_setup_failed}
  end

  defmodule FailingWS do
    def stream_transport(_, _), do: :websocket
    def attach_websocket_stream(_, _, _), do: {:error, :probe_setup_failed}
  end

  defmodule LocalHTTP do
    def attach_stream(_, _, opts, _) do
      body = Jason.encode!(%{thinking: %{type: "enabled"}})
      {:ok, Finch.build(:post, opts[:base_url], [{"content-type", "application/json"}], body)}
    end

    def decode_stream_event(event, model),
      do: ReqLLM.Provider.Defaults.default_decode_stream_event(event, model)
  end

  defmodule FailingInProcess do
    def stream_transport(_, _), do: :in_process
    def attach_in_process_stream(_, _, _), do: {:error, :probe_setup_failed}
  end

  defmodule InProcess do
    def stream_transport(_, _), do: :in_process

    def attach_in_process_stream(_, _, opts) do
      owner = opts[:test_pid]

      stream =
        Stream.map([:first, :last], fn
          :first ->
            send(owner, {:producer, self()})
            StreamChunk.text("first")

          :last ->
            receive do
              :continue -> StreamChunk.text("last")
            end
        end)

      cancel = fn ->
        send(owner, :provider_cleanup)
        raise "cleanup callback failed"
      end

      {:ok, %ReqLLM.Provider.InProcessStream{stream: stream, cancel: cancel}}
    end
  end

  @tag :capture_log
  test "failed setup closes HTTP, WebSocket, and in-process servers" do
    for {provider, name} <- [
          {FailingHTTP, :cleanup_failed_http},
          {FailingWS, :cleanup_failed_ws},
          {FailingInProcess, :cleanup_failed_inprocess}
        ] do
      model = %LLMDB.Model{provider: :test, id: "probe"}

      assert {:error, _} =
               Streaming.start_stream(provider, model, Context.new([]),
                 name: name,
                 total_timeout: 1,
                 completion_cleanup_after: 1
               )

      assert Process.whereis(name) == nil
    end
  end

  test "conversion failures cancel and retain the original error even if cleanup raises" do
    owner = self()

    for convert <- [&StreamResponse.to_response/1, &StreamResponse.process_stream/1] do
      {:ok, handle} = StreamResponse.MetadataHandle.start_link(fn -> %{} end)
      error = ReqLLM.Error.API.Stream.exception(reason: "probe timeout", cause: :timeout)
      stream = Stream.map([:probe], fn _ -> raise error end)

      response = %StreamResponse{
        stream: stream,
        metadata_handle: handle,
        cancel: fn ->
          send(owner, :conversion_cancelled)
          raise "cleanup failed"
        end,
        model: %LLMDB.Model{provider: :test, id: "probe"},
        context: Context.new([])
      }

      assert {:error, ^error} = convert.(response)
      refute Process.alive?(handle)
      assert_received :conversion_cancelled
      refute_received :conversion_cancelled
    end
  end

  @tag :capture_log
  test "callback failures close wrapped and unwrapped streams and invoke provider cleanup once" do
    for wrapped? <- [false, true] do
      name = if wrapped?, do: :wrapped_cleanup_stream, else: :callback_cleanup_stream
      model = %LLMDB.Model{provider: :test, id: "probe"}

      assert {:ok, response} =
               Streaming.start_stream(InProcess, model, Context.new([]),
                 name: name,
                 test_pid: self()
               )

      server = Process.whereis(name)
      assert_receive {:producer, producer}
      original_handle = response.metadata_handle

      response =
        if wrapped? do
          {:ok, wrapped} =
            ReqLLM.Output.Validation.attach_stream_result({:ok, response}, %{}, %{enabled?: true})

          wrapped
        else
          response
        end

      server_ref = Process.monitor(server)
      producer_ref = Process.monitor(producer)

      assert {:error, %RuntimeError{message: "consumer failed"}} =
               StreamResponse.process_stream(response,
                 on_chunk: fn _ -> raise "consumer failed" end
               )

      assert_receive {:DOWN, ^server_ref, :process, ^server, _}
      assert_receive {:DOWN, ^producer_ref, :process, ^producer, _}
      refute Process.alive?(original_handle)
      refute Process.alive?(response.metadata_handle)
      assert_receive :provider_cleanup
      refute_receive :provider_cleanup, 10
    end
  end

  test "conversion cleanup preserves thrown values" do
    owner = self()

    for convert <- [&StreamResponse.to_response/1, &StreamResponse.process_stream/1] do
      {:ok, handle} = StreamResponse.MetadataHandle.start_link(fn -> %{} end)

      response = %StreamResponse{
        stream: Stream.map([:probe], fn _ -> throw(:conversion_failed) end),
        metadata_handle: handle,
        cancel: fn -> send(owner, :thrown_conversion_cancelled) end,
        model: %LLMDB.Model{provider: :test, id: "probe"},
        context: Context.new([])
      }

      assert catch_throw(convert.(response)) == :conversion_failed
      refute Process.alive?(handle)
      assert_received :thrown_conversion_cancelled
      refute_received :thrown_conversion_cancelled
    end
  end

  test "conversion timeout stops the HTTP producer and server" do
    for convert <- [&StreamResponse.to_response/1, &StreamResponse.process_stream/1] do
      with_http_stream(fn response, server, producer, peer ->
        server_ref = Process.monitor(server)
        producer_ref = Process.monitor(producer)
        assert {:error, %ReqLLM.Error.API.Stream{cause: :timeout}} = convert.(response)
        assert_receive {:DOWN, ^server_ref, :process, ^server, _}
        assert_receive {:DOWN, ^producer_ref, :process, ^producer, _}
        refute Process.alive?(response.metadata_handle)
        send(peer, :finish)
      end)
    end
  end

  test "raw HTTP timeout remains resumable and then converts successfully" do
    with_http_stream(fn response, server, producer, peer ->
      assert_raise ReqLLM.Error.API.Stream, fn -> Enum.to_list(response.stream) end
      assert Process.alive?(server)
      assert Process.alive?(producer)
      send(peer, :finish)
      assert {:ok, result} = StreamResponse.process_stream(response)
      assert ReqLLM.Response.text(result) == "late"
      refute Process.alive?(response.metadata_handle)
    end)
  end

  defp with_http_stream(run) do
    saved_timeout = Application.fetch_env(:req_llm, :stream_receive_timeout)
    Application.put_env(:req_llm, :stream_receive_timeout, 30)

    on_exit(fn ->
      case saved_timeout do
        {:ok, value} -> Application.put_env(:req_llm, :stream_receive_timeout, value)
        :error -> Application.delete_env(:req_llm, :stream_receive_timeout)
      end
    end)

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    owner = self()

    peer =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n"
          )

        send(owner, {:peer_ready, self()})

        receive do
          :finish ->
            payload =
              "data: {\"choices\":[{\"delta\":{\"content\":\"late\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"

            :gen_tcp.send(socket, [
              Integer.to_string(byte_size(payload), 16),
              "\r\n",
              payload,
              "\r\n0\r\n\r\n"
            ])
        end

        :gen_tcp.close(socket)
      end)

    model = %LLMDB.Model{provider: :test, id: "probe"}

    {:ok, response} =
      Streaming.start_stream(LocalHTTP, model, Context.new([Context.user("probe")]),
        base_url: "http://127.0.0.1:#{port}/",
        name: :cleanup_http_stream,
        completion_cleanup_after: 1,
        max_retries: 0
      )

    server = Process.whereis(:cleanup_http_stream)
    assert is_pid(server)
    producer = :sys.get_state(server).http_task

    on_exit(fn ->
      StreamResponse.close(response)
      :gen_tcp.close(listener)
      if Process.alive?(peer), do: Process.exit(peer, :kill)
    end)

    assert_receive {:peer_ready, ^peer}, 5000
    run.(response, server, producer, peer)
  end
end

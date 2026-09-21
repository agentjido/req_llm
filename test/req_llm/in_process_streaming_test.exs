defmodule ReqLLM.InProcessStreamingTest do
  use ExUnit.Case, async: false

  alias ReqLLM.{Context, StreamChunk, Streaming, StreamResponse}
  alias ReqLLM.Provider.InProcessStream

  defmodule CanonicalProvider do
    use ReqLLM.Provider,
      id: :canonical_stream_test,
      default_base_url: "in-process://canonical-stream-test"

    @impl ReqLLM.Provider
    def stream_transport(_model, _opts), do: :in_process

    @impl ReqLLM.Provider
    def attach_in_process_stream(_model, _context, opts) do
      case Keyword.get(opts, :test_mode, :success) do
        :success ->
          {:ok,
           [
             StreamChunk.text("Hello "),
             StreamChunk.text("in process"),
             StreamChunk.meta(%{
               usage: %{input_tokens: 2, output_tokens: 3, total_tokens: 5},
               finish_reason: :stop,
               terminal?: true
             })
           ]}

        :error ->
          {:ok, [StreamChunk.text("partial"), {:error, :upstream_failed}]}

        :blocked ->
          test_pid = Keyword.fetch!(opts, :test_pid)

          stream =
            Stream.repeatedly(fn ->
              send(test_pid, :producer_waiting)

              receive do
                {:chunk, chunk} -> chunk
              end
            end)

          {:ok,
           InProcessStream.new(stream,
             cancel: fn -> send(test_pid, :provider_cancelled) end
           )}

        :backpressure ->
          test_pid = Keyword.fetch!(opts, :test_pid)

          stream =
            [
              StreamChunk.text("one"),
              StreamChunk.text("two"),
              StreamChunk.text("three"),
              StreamChunk.meta(%{finish_reason: :stop, terminal?: true})
            ]
            |> Stream.with_index(1)
            |> Stream.map(fn {chunk, index} ->
              send(test_pid, {:produced, index})
              chunk
            end)

          {:ok, stream}
      end
    end
  end

  defmodule FailingProvider do
    def stream_transport(_model, _opts), do: :in_process
    def attach_in_process_stream(_model, _context, _opts), do: {:error, :boom}
  end

  setup_all do
    assert {:ok, :canonical_stream_test} = ReqLLM.Providers.register(CanonicalProvider)
    on_exit(fn -> ReqLLM.Providers.unregister(:canonical_stream_test) end)
  end

  test "a registered provider streams canonical chunks through the public API" do
    model = %{provider: :canonical_stream_test, id: "canonical-model"}

    assert {:ok, response} = ReqLLM.stream_text(model, "Hello")
    assert %StreamResponse{} = response
    assert StreamResponse.text(response) == "Hello in process"
    assert StreamResponse.finish_reason(response) == :stop

    usage = StreamResponse.usage(response)
    assert usage.input_tokens == 2
    assert usage.output_tokens == 3
    assert usage.total_tokens == 5
  end

  test "provider errors use the canonical StreamResponse error path" do
    {:ok, response} = start_stream(test_mode: :error)

    error =
      assert_raise ReqLLM.Error.API.Stream, fn ->
        Enum.to_list(response.stream)
      end

    assert error.cause == :upstream_failed
    assert StreamResponse.finish_reason(response) == :error
  end

  test "explicit cancellation invokes provider cleanup" do
    {:ok, response} = start_stream(test_mode: :blocked, test_pid: self())
    assert_receive :producer_waiting

    assert :ok = StreamResponse.close(response)
    assert_receive :provider_cancelled
  end

  test "total timeout stops the producer and invokes provider cleanup" do
    {:ok, response} =
      start_stream(
        test_mode: :blocked,
        test_pid: self(),
        total_timeout: 25,
        metadata_timeout: 100
      )

    assert_receive :producer_waiting

    error =
      assert_raise ReqLLM.Error.API.Stream, fn ->
        Enum.to_list(response.stream)
      end

    assert %ReqLLM.Error.API.Timeout{kind: :total} = error.cause
    assert_receive :provider_cancelled
  end

  test "receive timeout cancels an inactive provider stream" do
    {:ok, response} =
      start_stream(
        test_mode: :blocked,
        test_pid: self(),
        receive_timeout: 25
      )

    assert_receive :producer_waiting

    error =
      assert_raise ReqLLM.Error.API.Stream, fn ->
        Enum.to_list(response.stream)
      end

    assert error.cause == :timeout
    assert_receive :provider_cancelled
  end

  test "canonical chunks use StreamServer backpressure" do
    {:ok, response} =
      start_stream(test_mode: :backpressure, test_pid: self(), high_watermark: 1)

    assert_receive {:produced, 1}
    refute_receive {:produced, 2}, 20

    test_pid = self()

    consumer =
      Task.async(fn ->
        response.stream
        |> Stream.each(fn chunk ->
          send(test_pid, {:consumed, chunk})

          receive do
            :continue -> :ok
          end
        end)
        |> Enum.to_list()
      end)

    assert_receive {:consumed, %StreamChunk{text: "one"}}
    assert_receive {:produced, 2}
    refute_receive {:produced, 3}, 20

    send(consumer.pid, :continue)
    assert_receive {:consumed, %StreamChunk{text: "two"}}
    assert_receive {:produced, 3}

    send(consumer.pid, :continue)
    assert_receive {:consumed, %StreamChunk{text: "three"}}
    assert_receive {:produced, 4}

    send(consumer.pid, :continue)
    assert_receive {:consumed, %StreamChunk{type: :meta}}
    send(consumer.pid, :continue)

    assert [_one, _two, _three, %StreamChunk{type: :meta}] = Task.await(consumer)
  end

  test "telemetry identifies the in-process transport" do
    handler_id = "in-process-stream-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:req_llm, :request, :start],
        fn event, measurements, metadata, _config ->
          send(test_pid, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, response} = start_stream()
    assert_receive {[:req_llm, :request, :start], _measurements, %{transport: :in_process}}
    assert StreamResponse.text(response) == "Hello in process"
  end

  test "startup failures identify the in-process transport" do
    {:ok, context} = Context.normalize("Hello")

    assert {:error, {:in_process_streaming_failed, {:provider_build_failed, :boom}}} =
             Streaming.start_stream(FailingProvider, model(), context, [])
  end

  defp start_stream(opts \\ []) do
    {:ok, context} = Context.normalize("Hello")
    Streaming.start_stream(CanonicalProvider, model(), context, opts)
  end

  defp model do
    %LLMDB.Model{provider: :canonical_stream_test, id: "canonical-model"}
  end
end

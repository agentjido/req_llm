defmodule ReqLLM.StreamServer.MetadataTest do
  @moduledoc """
  Unit tests for StreamServer metadata extraction and completion handling.

  Tests metadata accumulation from HTTP events (status, headers) and
  completion signaling via both [DONE] SSE events and :done HTTP events.

  Uses mocked HTTP tasks and the shared MockProvider for isolated testing.
  """

  use ExUnit.Case, async: true

  import ReqLLM.Test.StreamServerHelpers

  alias ReqLLM.StreamServer

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "metadata and completion handling" do
    test "extracts and returns metadata on completion" do
      server = start_server()
      _task = mock_http_task(server)

      assert :ok = GenServer.call(server, {:http_event, {:status, 200}})
      assert :ok = GenServer.call(server, {:http_event, {:headers, [{"x-custom", "value"}]}})

      assert :ok = GenServer.call(server, {:http_event, :done})

      assert {:ok, metadata} = StreamServer.await_metadata(server, 100)
      assert metadata.status == 200
      assert metadata.headers == [{"x-custom", "value"}]

      StreamServer.cancel(server)
    end

    test "preserves total_tokens from usage metadata" do
      server = start_server()
      _task = mock_http_task(server)

      usage = %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 42}
      payload = Jason.encode!(%{"usage" => usage})

      StreamServer.http_event(server, {:data, "data: #{payload}\n\n"})
      StreamServer.http_event(server, :done)

      assert {:ok, metadata} = StreamServer.await_metadata(server, 100)
      assert metadata.usage.total_tokens == 42

      StreamServer.cancel(server)
    end

    test "await_metadata blocks until completion" do
      server = start_server()
      _task = mock_http_task(server)

      metadata_task =
        Task.async(fn ->
          StreamServer.await_metadata(server, 200)
        end)

      :timer.sleep(50)
      assert :ok = GenServer.call(server, {:http_event, :done})

      assert {:ok, metadata} = Task.await(metadata_task)
      assert is_map(metadata)

      StreamServer.cancel(server)
    end

    test "await_metadata returns terminal error metadata on stream failure" do
      server = start_server()
      _task = mock_http_task(server)

      error_reason = {:request_failed, "Network error"}
      assert :ok = GenServer.call(server, {:http_event, {:error, error_reason}})

      assert {:ok, metadata} = StreamServer.await_metadata(server, 100)
      assert metadata.error == error_reason
      assert metadata.finish_reason == :error

      StreamServer.cancel(server)
    end

    test "stream failure metadata preserves partial content and observed usage" do
      server = start_server()
      _task = mock_http_task(server)
      server_ref = Process.monitor(server)

      content = Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "partial"}}]})
      usage = Jason.encode!(%{"usage" => %{"prompt_tokens" => 4, "completion_tokens" => 2}})

      StreamServer.http_event(server, {:data, "data: #{content}\n\n"})
      StreamServer.http_event(server, {:data, "data: #{usage}\n\n"})

      error = %Finch.TransportError{source: %Mint.TransportError{reason: :closed}}
      StreamServer.http_event(server, {:error, error})

      assert {:ok, content_chunk} = StreamServer.next(server, 100)
      assert content_chunk.text == "partial"

      assert {:ok, usage_chunk} = StreamServer.next(server, 100)
      assert usage_chunk.metadata.usage["prompt_tokens"] == 4

      assert {:ok, metadata} = StreamServer.await_metadata(server, 100)
      assert metadata.error == error
      assert metadata.finish_reason == :error
      assert metadata.usage.input_tokens == 4
      assert metadata.usage.output_tokens == 2

      assert {:error, ^error} = StreamServer.next(server, 100)
      assert_receive {:DOWN, ^server_ref, :process, ^server, :normal}, 100
    end

    test "cancellation replies to all metadata waiters with partial usage" do
      server = start_server()
      _task = mock_http_task(server)

      usage = %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      payload = Jason.encode!(%{"usage" => usage})

      StreamServer.http_event(server, {:data, "data: #{payload}\n\n"})

      metadata_tasks =
        for _index <- 1..2 do
          Task.async(fn -> StreamServer.await_metadata(server, :infinity) end)
        end

      await_metadata_waiters(server, 2)

      assert :ok = StreamServer.cancel(server)

      results = Task.await_many(metadata_tasks)
      assert length(results) == 2

      Enum.each(results, fn result ->
        assert {:ok, metadata} = result
        assert metadata.finish_reason == :cancelled
        assert metadata.usage.input_tokens == 10
        assert metadata.usage.output_tokens == 5
        assert metadata.usage.total_tokens == 15
      end)
    end

    test "stops after normal HTTP task completion once halt and metadata are delivered" do
      server = start_server()
      task = Task.async(fn -> Process.sleep(20) end)

      StreamServer.attach_http_task(server, task.pid)

      next_task = Task.async(fn -> StreamServer.next(server, 200) end)
      metadata_task = Task.async(fn -> StreamServer.await_metadata(server, 200) end)

      assert :halt = Task.await(next_task)
      assert {:ok, metadata} = Task.await(metadata_task)
      assert metadata.finish_reason == :incomplete

      assert_receive {:EXIT, ^server, :normal}, 200
      refute Process.alive?(server)
    end

    test "terminal? flag from provider meta flips finish_reason to :stop" do
      server = start_server()
      _task = mock_http_task(server)

      payload = Jason.encode!(%{"event" => "terminal"})
      StreamServer.http_event(server, {:data, "data: #{payload}\n\n"})
      StreamServer.http_event(server, :done)

      assert {:ok, metadata} = StreamServer.await_metadata(server, 200)
      assert metadata.finish_reason == :stop
      refute Map.has_key?(metadata, :terminal?)

      StreamServer.cancel(server)
    end

    test "terminal? flag from provider meta completes without transport done" do
      server = start_server()
      _task = mock_http_task(server)

      payload = Jason.encode!(%{"event" => "terminal"})
      StreamServer.http_event(server, {:data, "data: #{payload}\n\n"})

      assert {:ok, metadata} = StreamServer.await_metadata(server, 200)
      assert metadata.finish_reason == :stop
      refute Map.has_key?(metadata, :terminal?)

      StreamServer.cancel(server)
    end

    test "explicit finish_reason from provider wins over terminal? fallback" do
      server = start_server()
      _task = mock_http_task(server)

      finish_payload = Jason.encode!(%{"choices" => [%{"finish_reason" => "length"}]})
      terminal_payload = Jason.encode!(%{"event" => "terminal"})

      StreamServer.http_event(server, {:data, "data: #{finish_payload}\n\n"})
      StreamServer.http_event(server, {:data, "data: #{terminal_payload}\n\n"})
      StreamServer.http_event(server, :done)

      assert {:ok, metadata} = StreamServer.await_metadata(server, 200)
      assert metadata.finish_reason == :length

      StreamServer.cancel(server)
    end
  end

  describe "usage arriving after finish_reason (default decoder)" do
    defmodule DefaultsDecodeProvider do
      @moduledoc false
    end

    test "usage in a separate network chunk after finish_reason is captured" do
      server = start_server(provider_mod: DefaultsDecodeProvider)
      _task = mock_http_task(server)

      metadata_task = Task.async(fn -> StreamServer.await_metadata(server, 500) end)
      :timer.sleep(20)

      finish_payload =
        Jason.encode!(%{
          "id" => "gen-123",
          "choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]
        })

      usage_payload =
        Jason.encode!(%{
          "id" => "gen-123",
          "choices" => [],
          "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 25, "total_tokens" => 125}
        })

      StreamServer.http_event(server, {:data, "data: #{finish_payload}\n\n"})
      StreamServer.http_event(server, {:data, "data: #{usage_payload}\n\n"})
      StreamServer.http_event(server, {:data, "data: [DONE]\n\n"})
      StreamServer.http_event(server, :done)

      assert {:ok, metadata} = Task.await(metadata_task)
      assert metadata.finish_reason == :tool_calls
      assert metadata.usage.input_tokens == 100
      assert metadata.usage.output_tokens == 25

      StreamServer.cancel(server)
    end
  end

  defp await_metadata_waiters(server, expected_count, attempts \\ 50)

  defp await_metadata_waiters(server, expected_count, attempts) when attempts > 0 do
    if length(:sys.get_state(server).waiting_callers) >= expected_count do
      :ok
    else
      Process.sleep(5)
      await_metadata_waiters(server, expected_count, attempts - 1)
    end
  end

  defp await_metadata_waiters(_server, _expected_count, 0) do
    flunk("metadata waiters were not registered")
  end
end

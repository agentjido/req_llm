defmodule ReqLLM.StreamServer.TelemetryProvider do
  @behaviour ReqLLM.Provider

  alias ReqLLM.StreamChunk

  def decode_stream_event(%{data: %{"type" => "thinking", "text" => text}}, _model) do
    [StreamChunk.thinking(text)]
  end

  def decode_stream_event(%{data: %{"type" => "content", "text" => text}}, _model) do
    [StreamChunk.text(text)]
  end

  def decode_stream_event(
        %{data: %{"type" => "meta", "usage" => usage, "reasoning_details" => details}},
        _model
      ) do
    [StreamChunk.meta(%{usage: usage, reasoning_details: details})]
  end

  def decode_stream_event(
        %{data: %{"type" => "finish", "finish_reason" => finish_reason}},
        _model
      ) do
    [StreamChunk.meta(%{finish_reason: finish_reason})]
  end

  def decode_stream_event(_event, _model), do: []

  def prepare_request(_op, _model, _data, _opts), do: {:error, :not_implemented}
  def attach(_req, _model, _opts), do: {:error, :not_implemented}
  def encode_body(_req), do: {:error, :not_implemented}
  def decode_response(_resp), do: {:error, :not_implemented}
end

defmodule ReqLLM.StreamServer.TelemetryTest do
  use ExUnit.Case, async: false

  import ReqLLM.Context
  import ReqLLM.Test.StreamServerHelpers

  alias ReqLLM.StreamServer

  @events [
    [:req_llm, :request, :start],
    [:req_llm, :request, :stop],
    [:req_llm, :request, :exception],
    [:req_llm, :reasoning, :start],
    [:req_llm, :reasoning, :update],
    [:req_llm, :reasoning, :stop],
    [:req_llm, :token_usage]
  ]

  setup do
    Process.flag(:trap_exit, true)
    test_pid = self()
    suffix = System.unique_integer([:positive])

    Enum.each(@events, fn event ->
      :telemetry.attach(
        "#{inspect(event)}-#{suffix}",
        event,
        fn name, measurements, metadata, _ ->
          send(test_pid, {:telemetry_event, name, measurements, metadata})
        end,
        nil
      )
    end)

    on_exit(fn ->
      Enum.each(@events, fn event ->
        :telemetry.detach("#{inspect(event)}-#{suffix}")
      end)
    end)

    :ok
  end

  test "emits streaming request, reasoning, and token usage events with shared request_id" do
    model = reasoning_model()
    server = start_server(provider_mod: ReqLLM.StreamServer.TelemetryProvider, model: model)
    _task = mock_http_task(server)

    telemetry_context =
      model
      |> ReqLLM.Telemetry.new_context(
        [context: ReqLLM.Context.new([user("hello")]), reasoning_effort: :high],
        mode: :stream,
        transport: :finch,
        operation: :chat
      )
      |> ReqLLM.Telemetry.start_request(%{
        "thinking" => %{"type" => "enabled", "budget_tokens" => 4096}
      })

    assert :ok = StreamServer.set_telemetry_context(server, telemetry_context)

    StreamServer.http_event(server, {:status, 200})

    StreamServer.http_event(
      server,
      {:data, "data: #{Jason.encode!(%{"type" => "thinking", "text" => "thinking"})}\n\n"}
    )

    StreamServer.http_event(
      server,
      {:data, "data: #{Jason.encode!(%{"type" => "content", "text" => "answer"})}\n\n"}
    )

    StreamServer.http_event(
      server,
      {:data,
       "data: #{Jason.encode!(%{"type" => "meta", "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "completion_tokens_details" => %{"reasoning_tokens" => 3}}, "reasoning_details" => [%{"signature" => "sig"}]})}\n\n"}
    )

    StreamServer.http_event(
      server,
      {:data, "data: #{Jason.encode!(%{"type" => "finish", "finish_reason" => "stop"})}\n\n"}
    )

    StreamServer.http_event(server, :done)

    assert {:ok, metadata} = StreamServer.await_metadata(server, 500)
    assert metadata.finish_reason == :stop
    assert metadata.request_id

    assert_receive {:telemetry_event, [:req_llm, :request, :start], _, request_start}
    assert_receive {:telemetry_event, [:req_llm, :reasoning, :start], _, reasoning_start}

    updates =
      Enum.map(1..3, fn _ ->
        receive do
          {:telemetry_event, [:req_llm, :reasoning, :update], _, metadata} -> metadata
        after
          500 -> flunk("expected reasoning update event")
        end
      end)

    assert_receive {:telemetry_event, [:req_llm, :request, :stop], _, request_stop}
    assert_receive {:telemetry_event, [:req_llm, :reasoning, :stop], _, reasoning_stop}

    assert_receive {:telemetry_event, [:req_llm, :token_usage], token_measurements,
                    token_metadata}

    request_id = request_start.request_id

    assert reasoning_start.request_id == request_id
    assert Enum.all?(updates, &(&1.request_id == request_id))
    assert request_stop.request_id == request_id
    assert reasoning_stop.request_id == request_id
    assert token_metadata.request_id == request_id

    assert Enum.sort(Enum.map(updates, & &1.milestone)) ==
             Enum.sort([:content_started, :details_available, :usage_updated])

    assert request_stop.reasoning.reasoning_tokens == 3
    assert request_stop.reasoning.channel == :content_and_usage
    assert token_measurements.tokens.reasoning == 3

    StreamServer.cancel(server)
  end

  test "emits cancelled terminal events without request exception" do
    model = reasoning_model()
    server = start_server(provider_mod: ReqLLM.StreamServer.TelemetryProvider, model: model)
    _task = mock_http_task(server)

    telemetry_context =
      model
      |> ReqLLM.Telemetry.new_context(
        [context: ReqLLM.Context.new([user("hello")]), reasoning_effort: :high],
        mode: :stream,
        transport: :finch,
        operation: :chat
      )
      |> ReqLLM.Telemetry.start_request(%{"thinking" => %{"type" => "enabled"}})

    assert :ok = StreamServer.set_telemetry_context(server, telemetry_context)

    StreamServer.http_event(
      server,
      {:data, "data: #{Jason.encode!(%{"type" => "thinking", "text" => "thinking"})}\n\n"}
    )

    assert :ok = StreamServer.cancel(server)

    assert_receive {:telemetry_event, [:req_llm, :request, :start], _, _}
    assert_receive {:telemetry_event, [:req_llm, :reasoning, :start], _, _}
    assert_receive {:telemetry_event, [:req_llm, :reasoning, :update], _, update_meta}
    assert update_meta.milestone == :content_started
    assert_receive {:telemetry_event, [:req_llm, :request, :stop], _, stop_meta}
    assert_receive {:telemetry_event, [:req_llm, :reasoning, :stop], _, reasoning_stop_meta}
    refute_receive {:telemetry_event, [:req_llm, :request, :exception], _, _}
    assert stop_meta.finish_reason == :cancelled
    assert reasoning_stop_meta.milestone == :cancelled
  end

  test "emits request exception for streaming failures" do
    model = reasoning_model()
    server = start_server(provider_mod: ReqLLM.StreamServer.TelemetryProvider, model: model)
    _task = mock_http_task(server)

    telemetry_context =
      model
      |> ReqLLM.Telemetry.new_context(
        [context: ReqLLM.Context.new([user("hello")]), reasoning_effort: :high],
        mode: :stream,
        transport: :finch,
        operation: :chat
      )
      |> ReqLLM.Telemetry.start_request(%{"thinking" => %{"type" => "enabled"}})

    assert :ok = StreamServer.set_telemetry_context(server, telemetry_context)

    StreamServer.http_event(server, {:error, :boom})

    assert {:error, :boom} = StreamServer.await_metadata(server, 200)
    assert_receive {:telemetry_event, [:req_llm, :request, :start], _, _}
    assert_receive {:telemetry_event, [:req_llm, :reasoning, :start], _, _}
    assert_receive {:telemetry_event, [:req_llm, :request, :exception], _, exception_meta}
    assert_receive {:telemetry_event, [:req_llm, :reasoning, :stop], _, reasoning_stop_meta}
    refute_receive {:telemetry_event, [:req_llm, :request, :stop], _, _}
    assert exception_meta.finish_reason == :error
    assert reasoning_stop_meta.milestone == :error

    StreamServer.cancel(server)
  end

  test "preserves public stream finish reasons while telemetry canonicalizes them" do
    model = reasoning_model()
    server = start_server(provider_mod: ReqLLM.StreamServer.TelemetryProvider, model: model)
    _task = mock_http_task(server)

    telemetry_context =
      model
      |> ReqLLM.Telemetry.new_context(
        [context: ReqLLM.Context.new([user("hello")]), reasoning_effort: :high],
        mode: :stream,
        transport: :finch,
        operation: :chat
      )
      |> ReqLLM.Telemetry.start_request(%{"thinking" => %{"type" => "enabled"}})

    assert :ok = StreamServer.set_telemetry_context(server, telemetry_context)

    StreamServer.http_event(
      server,
      {:data, "data: #{Jason.encode!(%{"type" => "finish", "finish_reason" => "tool_use"})}\n\n"}
    )

    StreamServer.http_event(server, :done)

    assert {:ok, metadata} = StreamServer.await_metadata(server, 500)
    assert metadata.finish_reason == "tool_use"

    assert_receive {:telemetry_event, [:req_llm, :request, :start], _, _}
    assert_receive {:telemetry_event, [:req_llm, :reasoning, :start], _, _}
    assert_receive {:telemetry_event, [:req_llm, :request, :stop], _, stop_meta}
    assert_receive {:telemetry_event, [:req_llm, :reasoning, :stop], _, reasoning_stop_meta}

    assert stop_meta.finish_reason == :tool_calls
    assert reasoning_stop_meta.milestone == :tool_calls

    StreamServer.cancel(server)
  end

  defp reasoning_model do
    %LLMDB.Model{
      provider: :anthropic,
      id: "test-reasoning-model",
      capabilities: %{reasoning: %{enabled: true}}
    }
  end
end

defmodule ReqLLM.OpenTelemetryTest do
  use ExUnit.Case, async: true

  alias ReqLLM.OpenTelemetry

  defmodule FakeAdapter do
    @behaviour ReqLLM.OpenTelemetry.Adapter

    @impl true
    def available?, do: true

    @impl true
    def start_span(name, attributes, config) do
      span = make_ref()
      send(config[:test_pid], {:start_span, span, name, attributes})
      span
    end

    @impl true
    def set_attributes(span, attributes, config) do
      send(config[:test_pid], {:set_attributes, span, attributes})
      :ok
    end

    @impl true
    def add_event(span, name, attributes, config) do
      send(config[:test_pid], {:add_event, span, name, attributes})
      :ok
    end

    @impl true
    def set_status(span, status, message, config) do
      send(config[:test_pid], {:set_status, span, status, message})
      :ok
    end

    @impl true
    def end_span(span, config) do
      send(config[:test_pid], {:end_span, span})
      :ok
    end
  end

  test "attaches a GenAI client span for request lifecycle events" do
    handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
    request_id = "req-#{System.unique_integer([:positive])}"

    assert :ok = OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())

    on_exit(fn ->
      OpenTelemetry.detach(handler_id)
    end)

    model = %LLMDB.Model{id: "gpt-5", provider: :openai}

    start_metadata = %{
      request_id: request_id,
      operation: :chat,
      provider: :openai,
      model: model
    }

    stop_metadata = %{
      request_id: request_id,
      operation: :chat,
      provider: :openai,
      model: model,
      finish_reason: :stop,
      usage: %{
        tokens: %{
          input: 21,
          output: 34,
          cached_input: 8,
          cache_creation: 5
        }
      }
    }

    :telemetry.execute(
      [:req_llm, :request, :start],
      %{system_time: System.system_time()},
      start_metadata
    )

    assert_receive {:start_span, span, "chat gpt-5", start_attributes}
    assert start_attributes[:"gen_ai.provider.name"] == "openai"
    assert start_attributes[:"gen_ai.operation.name"] == "chat"
    assert start_attributes[:"gen_ai.request.model"] == "gpt-5"
    assert start_attributes[:"gen_ai.output.type"] == "text"
    assert start_attributes[:"req_llm.request_id"] == request_id

    :telemetry.execute(
      [:req_llm, :request, :stop],
      %{duration: 1, system_time: System.system_time()},
      stop_metadata
    )

    assert_receive {:set_attributes, ^span, stop_attributes}
    assert stop_attributes[:"gen_ai.response.finish_reasons"] == ["stop"]
    assert stop_attributes[:"gen_ai.usage.input_tokens"] == 21
    assert stop_attributes[:"gen_ai.usage.output_tokens"] == 34
    assert stop_attributes[:"gen_ai.usage.cache_read.input_tokens"] == 8
    assert stop_attributes[:"gen_ai.usage.cache_creation.input_tokens"] == 5
    assert_receive {:end_span, ^span}
  end

  test "records exception metadata on request failures" do
    handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
    request_id = "req-#{System.unique_integer([:positive])}"

    assert :ok = OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())

    on_exit(fn ->
      OpenTelemetry.detach(handler_id)
    end)

    model = %LLMDB.Model{id: "gemini-2.5-pro", provider: :google}

    :telemetry.execute(
      [:req_llm, :request, :start],
      %{system_time: System.system_time()},
      %{request_id: request_id, operation: :object, provider: :google, model: model}
    )

    assert_receive {:start_span, span, "chat gemini-2.5-pro", start_attributes}
    assert start_attributes[:"gen_ai.provider.name"] == "gcp.gen_ai"
    assert start_attributes[:"gen_ai.output.type"] == "json"

    error = RuntimeError.exception("request timed out")

    :telemetry.execute(
      [:req_llm, :request, :exception],
      %{duration: 1, system_time: System.system_time()},
      %{
        request_id: request_id,
        operation: :object,
        provider: :google,
        model: model,
        error: error,
        http_status: 504
      }
    )

    assert_receive {:set_attributes, ^span, exception_attributes}
    assert exception_attributes[:"error.type"] == "504"
    assert exception_attributes[:"req_llm.request_id"] == request_id
    assert_receive {:add_event, ^span, :exception, event_attributes}
    assert event_attributes[:"exception.type"] == "504"
    assert event_attributes[:"exception.message"] == "request timed out"
    assert_receive {:set_status, ^span, :error, "request timed out"}
    assert_receive {:end_span, ^span}
  end

  test "maps embedding operations to the OpenTelemetry embeddings span name" do
    assert OpenTelemetry.span_name(%{
             operation: :embedding,
             model: %LLMDB.Model{id: "text-embedding-3-small", provider: :openai}
           }) == "embeddings text-embedding-3-small"
  end
end

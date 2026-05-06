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

  defmodule FakeMetricsAdapter do
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

    @impl true
    def metrics_available?, do: true

    @impl true
    def record_histogram(record, config) do
      send(config[:test_pid], {:record_histogram, record})
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
    assert exception_attributes[:"error.type"] == "RuntimeError"
    assert exception_attributes[:"req_llm.request_id"] == request_id
    assert_receive {:add_event, ^span, :exception, event_attributes}
    assert event_attributes[:"exception.type"] == "RuntimeError"
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

  test "emits gen_ai.request.* and server.* attributes on start" do
    handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
    request_id = "req-#{System.unique_integer([:positive])}"

    assert :ok = OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())

    on_exit(fn ->
      OpenTelemetry.detach(handler_id)
    end)

    model = %LLMDB.Model{id: "gpt-5", provider: :openai}

    :telemetry.execute(
      [:req_llm, :request, :start],
      %{system_time: System.system_time()},
      %{
        request_id: request_id,
        operation: :chat,
        provider: :openai,
        model: model,
        request_options: %{
          temperature: 0.7,
          top_p: 0.95,
          max_tokens: 256,
          stop_sequences: ["END"],
          seed: 42,
          stream?: false,
          conversation_id: "session-abc"
        },
        server: %{address: "api.openai.com", port: 443}
      }
    )

    assert_receive {:start_span, _span, "chat gpt-5", attributes}
    assert attributes[:"gen_ai.request.temperature"] == 0.7
    assert attributes[:"gen_ai.request.top_p"] == 0.95
    assert attributes[:"gen_ai.request.max_tokens"] == 256
    assert attributes[:"gen_ai.request.stop_sequences"] == ["END"]
    assert attributes[:"gen_ai.request.seed"] == 42
    assert attributes[:"gen_ai.request.stream"] == false
    assert attributes[:"gen_ai.conversation.id"] == "session-abc"
    assert attributes[:"server.address"] == "api.openai.com"
    assert attributes[:"server.port"] == 443
  end

  test "emits gen_ai.request.choice.count when n is set" do
    handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
    request_id = "req-#{System.unique_integer([:positive])}"

    assert :ok = OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())

    on_exit(fn ->
      OpenTelemetry.detach(handler_id)
    end)

    :telemetry.execute(
      [:req_llm, :request, :start],
      %{system_time: System.system_time()},
      %{
        request_id: request_id,
        operation: :chat,
        provider: :openai,
        model: %LLMDB.Model{id: "gpt-5", provider: :openai},
        request_options: %{n: 3}
      }
    )

    assert_receive {:start_span, _span, _name, attributes}
    assert attributes[:"gen_ai.request.choice.count"] == 3
  end

  test "emits gen_ai.embeddings.dimension.count for embedding responses" do
    handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
    request_id = "req-#{System.unique_integer([:positive])}"

    assert :ok = OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())

    on_exit(fn ->
      OpenTelemetry.detach(handler_id)
    end)

    model = %LLMDB.Model{id: "text-embedding-3-small", provider: :openai}

    :telemetry.execute(
      [:req_llm, :request, :start],
      %{system_time: System.system_time()},
      %{request_id: request_id, operation: :embedding, provider: :openai, model: model}
    )

    assert_receive {:start_span, span, _name, _attrs}

    :telemetry.execute(
      [:req_llm, :request, :stop],
      %{duration: 1, system_time: System.system_time()},
      %{
        request_id: request_id,
        operation: :embedding,
        provider: :openai,
        model: model,
        finish_reason: nil,
        usage: %{input_tokens: 4, output_tokens: 0},
        response_summary: %{dimensions: 1536}
      }
    )

    assert_receive {:set_attributes, ^span, attributes}
    assert attributes[:"gen_ai.embeddings.dimension.count"] == 1536
  end

  test "emits reasoning output tokens when usage exposes them" do
    handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
    request_id = "req-#{System.unique_integer([:positive])}"

    assert :ok = OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())

    on_exit(fn ->
      OpenTelemetry.detach(handler_id)
    end)

    model = %LLMDB.Model{id: "gpt-5", provider: :openai}

    :telemetry.execute(
      [:req_llm, :request, :start],
      %{system_time: System.system_time()},
      %{request_id: request_id, operation: :chat, provider: :openai, model: model}
    )

    assert_receive {:start_span, span, _name, _attrs}

    :telemetry.execute(
      [:req_llm, :request, :stop],
      %{duration: 1, system_time: System.system_time()},
      %{
        request_id: request_id,
        operation: :chat,
        provider: :openai,
        model: model,
        finish_reason: :stop,
        usage: %{input_tokens: 12, output_tokens: 8, reasoning_tokens: 64}
      }
    )

    assert_receive {:set_attributes, ^span, attributes}
    assert attributes[:"gen_ai.usage.reasoning.output_tokens"] == 64
  end

  test "emits gen_ai.response.id and gen_ai.response.model when response payload is present" do
    handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
    request_id = "req-#{System.unique_integer([:positive])}"

    assert :ok = OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())

    on_exit(fn ->
      OpenTelemetry.detach(handler_id)
    end)

    model = %LLMDB.Model{id: "gpt-5", provider: :openai}

    response_payload = %ReqLLM.Response{
      id: "resp_42",
      model: "gpt-5-2026-03-01",
      context: nil,
      message: nil,
      object: nil,
      stream?: false,
      stream: nil,
      usage: nil,
      finish_reason: :stop,
      provider_meta: %{},
      error: nil
    }

    :telemetry.execute(
      [:req_llm, :request, :start],
      %{system_time: System.system_time()},
      %{request_id: request_id, operation: :chat, provider: :openai, model: model}
    )

    assert_receive {:start_span, span, _name, _attrs}

    :telemetry.execute(
      [:req_llm, :request, :stop],
      %{duration: 1, system_time: System.system_time()},
      %{
        request_id: request_id,
        operation: :chat,
        provider: :openai,
        model: model,
        finish_reason: :stop,
        usage: %{tokens: %{input: 1, output: 2}},
        response_payload: response_payload
      }
    )

    assert_receive {:set_attributes, ^span, attributes}
    assert attributes[:"gen_ai.response.id"] == "resp_42"
    assert attributes[:"gen_ai.response.model"] == "gpt-5-2026-03-01"
  end

  test "marks span as error on stop with HTTP >= 400" do
    handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
    request_id = "req-#{System.unique_integer([:positive])}"

    assert :ok = OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())

    on_exit(fn ->
      OpenTelemetry.detach(handler_id)
    end)

    model = %LLMDB.Model{id: "gpt-5", provider: :openai}

    :telemetry.execute(
      [:req_llm, :request, :start],
      %{system_time: System.system_time()},
      %{request_id: request_id, operation: :chat, provider: :openai, model: model}
    )

    assert_receive {:start_span, span, _name, _attrs}

    :telemetry.execute(
      [:req_llm, :request, :stop],
      %{duration: 1, system_time: System.system_time()},
      %{
        request_id: request_id,
        operation: :chat,
        provider: :openai,
        model: model,
        finish_reason: nil,
        usage: nil,
        http_status: 503
      }
    )

    assert_receive {:set_attributes, ^span, stop_attrs}
    assert stop_attrs[:"error.type"] == "503"
    assert_receive {:set_status, ^span, :error, "HTTP 503"}
    assert_receive {:end_span, ^span}
  end

  describe ":include_content option" do
    alias ReqLLM.{Message, ToolCall}
    alias ReqLLM.Message.ContentPart

    test "default (off) does not attach content attributes" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok = OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())

      on_exit(fn ->
        OpenTelemetry.detach(handler_id)
      end)

      :telemetry.execute(
        [:req_llm, :request, :start],
        %{system_time: System.system_time()},
        %{
          request_id: request_id,
          operation: :chat,
          provider: :openai,
          model: %LLMDB.Model{id: "gpt-5", provider: :openai},
          request_payload: %{
            messages: [
              %Message{role: :system, content: [%ContentPart{type: :text, text: "be helpful"}]},
              %Message{role: :user, content: [%ContentPart{type: :text, text: "hi"}]}
            ],
            tools: [%{name: "get_weather", description: "x", parameter_schema: %{}}]
          }
        }
      )

      assert_receive {:start_span, _span, _name, attributes}
      refute Map.has_key?(attributes, :"gen_ai.input.messages")
      refute Map.has_key?(attributes, :"gen_ai.system_instructions")
      refute Map.has_key?(attributes, :"gen_ai.tool.definitions")
    end

    test "include_content: true promotes messages, system_instructions, tool definitions onto the span" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok =
               OpenTelemetry.attach(handler_id,
                 adapter: FakeAdapter,
                 include_content: true,
                 test_pid: self()
               )

      on_exit(fn ->
        OpenTelemetry.detach(handler_id)
      end)

      tool_call = ToolCall.new("call_w", "get_weather", ~s({"city":"Paris"}))

      :telemetry.execute(
        [:req_llm, :request, :start],
        %{system_time: System.system_time()},
        %{
          request_id: request_id,
          operation: :chat,
          provider: :openai,
          model: %LLMDB.Model{id: "gpt-5", provider: :openai},
          request_payload: %{
            messages: [
              %Message{role: :system, content: [%ContentPart{type: :text, text: "be helpful"}]},
              %Message{role: :user, content: [%ContentPart{type: :text, text: "weather?"}]},
              %Message{role: :assistant, content: [], tool_calls: [tool_call]}
            ],
            tools: [
              %{
                name: "get_weather",
                description: "fetch",
                strict: true,
                parameter_schema: %{"type" => "object"}
              }
            ]
          }
        }
      )

      assert_receive {:start_span, _span, _name, attributes}

      assert attributes[:"gen_ai.system_instructions"] == [
               %{"type" => "text", "content" => "be helpful"}
             ]

      assert [
               %{"role" => "user"},
               %{"role" => "assistant"}
             ] = attributes[:"gen_ai.input.messages"]

      assert [
               %{
                 "type" => "function",
                 "name" => "get_weather",
                 "description" => "fetch",
                 "strict" => true,
                 "parameters" => %{"type" => "object"}
               }
             ] = attributes[:"gen_ai.tool.definitions"]
    end

    test "include_content: true attaches gen_ai.output.messages on stop" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok =
               OpenTelemetry.attach(handler_id,
                 adapter: FakeAdapter,
                 include_content: true,
                 test_pid: self()
               )

      on_exit(fn ->
        OpenTelemetry.detach(handler_id)
      end)

      model = %LLMDB.Model{id: "gpt-5", provider: :openai}

      :telemetry.execute(
        [:req_llm, :request, :start],
        %{system_time: System.system_time()},
        %{request_id: request_id, operation: :chat, provider: :openai, model: model}
      )

      assert_receive {:start_span, span, _name, _attrs}

      :telemetry.execute(
        [:req_llm, :request, :stop],
        %{duration: 1, system_time: System.system_time()},
        %{
          request_id: request_id,
          operation: :chat,
          provider: :openai,
          model: model,
          finish_reason: :stop,
          usage: %{tokens: %{input: 1, output: 1}},
          response_payload: %ReqLLM.Response{
            id: "resp_x",
            model: "gpt-5",
            context: nil,
            message: %Message{
              role: :assistant,
              content: [%ContentPart{type: :text, text: "hi back"}]
            },
            object: nil,
            stream?: false,
            stream: nil,
            usage: nil,
            finish_reason: :stop,
            provider_meta: %{},
            error: nil
          }
        }
      )

      assert_receive {:set_attributes, ^span, attributes}

      assert attributes[:"gen_ai.output.messages"] == [
               %{
                 "role" => "assistant",
                 "parts" => [%{"type" => "text", "content" => "hi back"}],
                 "finish_reason" => "stop"
               }
             ]
    end
  end

  describe "metrics emission" do
    defp millisecond_to_native(ms),
      do: System.convert_time_unit(ms, :millisecond, :native)

    defp marker_model do
      id = "metric-test-#{System.unique_integer([:positive, :monotonic])}"
      %LLMDB.Model{id: id, provider: :openai}
    end

    defp drain_records(model_id, records \\ []) do
      receive do
        {:record_histogram, %{attributes: %{"gen_ai.request.model" => ^model_id}} = record} ->
          drain_records(model_id, [record | records])

        {:record_histogram, _other} ->
          drain_records(model_id, records)
      after
        50 -> Enum.reverse(records)
      end
    end

    defp by_name(records, name), do: Enum.filter(records, &(&1.name == name))

    test "emits duration + token histograms on stop" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok =
               OpenTelemetry.attach(handler_id, adapter: FakeMetricsAdapter, test_pid: self())

      on_exit(fn -> OpenTelemetry.detach(handler_id) end)

      model = marker_model()

      :telemetry.execute(
        [:req_llm, :request, :start],
        %{system_time: System.system_time()},
        %{request_id: request_id, operation: :chat, provider: :openai, model: model}
      )

      :telemetry.execute(
        [:req_llm, :request, :stop],
        %{duration: millisecond_to_native(750), system_time: System.system_time()},
        %{
          request_id: request_id,
          operation: :chat,
          provider: :openai,
          model: model,
          mode: :sync,
          server: %{address: "api.openai.com", port: 443},
          finish_reason: :stop,
          usage: %{tokens: %{input: 100, output: 200}}
        }
      )

      records = drain_records(model.id)

      duration = by_name(records, "gen_ai.client.operation.duration") |> hd()
      assert_in_delta(duration.value, 0.75, 0.05)

      assert duration.attributes == %{
               "gen_ai.operation.name" => "chat",
               "gen_ai.provider.name" => "openai",
               "gen_ai.request.model" => model.id,
               "gen_ai.response.model" => model.id,
               "server.address" => "api.openai.com",
               "server.port" => 443
             }

      tokens = by_name(records, "gen_ai.client.token.usage")
      assert length(tokens) == 2

      assert by_name(records, "gen_ai.client.operation.time_to_first_chunk") == []
      assert by_name(records, "gen_ai.client.operation.time_per_output_chunk") == []
    end

    test "emits TTFC + TPOC and gen_ai.response.time_to_first_chunk attribute on streaming stop" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok =
               OpenTelemetry.attach(handler_id, adapter: FakeMetricsAdapter, test_pid: self())

      on_exit(fn -> OpenTelemetry.detach(handler_id) end)

      model = marker_model()
      ttfc_native = millisecond_to_native(150)
      duration_native = millisecond_to_native(1200)

      :telemetry.execute(
        [:req_llm, :request, :start],
        %{system_time: System.system_time()},
        %{request_id: request_id, operation: :chat, provider: :openai, model: model}
      )

      :telemetry.execute(
        [:req_llm, :request, :stop],
        %{duration: duration_native, system_time: System.system_time()},
        %{
          request_id: request_id,
          operation: :chat,
          provider: :openai,
          model: model,
          mode: :stream,
          streaming: %{first_chunk_at: 0, time_to_first_chunk: ttfc_native},
          finish_reason: :stop,
          usage: %{tokens: %{input: 30, output: 50}}
        }
      )

      assert_receive {:set_attributes, _span, attributes}
      assert_in_delta(attributes[:"gen_ai.response.time_to_first_chunk"], 0.15, 0.001)

      records = drain_records(model.id)

      ttfc = by_name(records, "gen_ai.client.operation.time_to_first_chunk") |> hd()
      assert_in_delta(ttfc.value, 0.15, 0.001)

      tpoc = by_name(records, "gen_ai.client.operation.time_per_output_chunk") |> hd()
      assert_in_delta(tpoc.value, (1.2 - 0.15) / 50, 0.001)
    end

    test "emits duration with error.type on exception" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok =
               OpenTelemetry.attach(handler_id, adapter: FakeMetricsAdapter, test_pid: self())

      on_exit(fn -> OpenTelemetry.detach(handler_id) end)

      model = marker_model()

      :telemetry.execute(
        [:req_llm, :request, :start],
        %{system_time: System.system_time()},
        %{request_id: request_id, operation: :chat, provider: :openai, model: model}
      )

      :telemetry.execute(
        [:req_llm, :request, :exception],
        %{duration: millisecond_to_native(80), system_time: System.system_time()},
        %{
          request_id: request_id,
          operation: :chat,
          provider: :openai,
          model: model,
          error: %RuntimeError{message: "boom"}
        }
      )

      records = drain_records(model.id)
      assert [duration] = records
      assert duration.name == "gen_ai.client.operation.duration"
      assert duration.attributes["error.type"] == "RuntimeError"
    end

    test "skips metrics when adapter does not implement metrics callbacks" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok = OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())
      on_exit(fn -> OpenTelemetry.detach(handler_id) end)

      model = marker_model()

      :telemetry.execute(
        [:req_llm, :request, :start],
        %{system_time: System.system_time()},
        %{request_id: request_id, operation: :chat, provider: :openai, model: model}
      )

      :telemetry.execute(
        [:req_llm, :request, :stop],
        %{duration: 1, system_time: System.system_time()},
        %{
          request_id: request_id,
          operation: :chat,
          provider: :openai,
          model: model,
          mode: :sync,
          finish_reason: :stop,
          usage: %{tokens: %{input: 10, output: 20}}
        }
      )

      assert drain_records(model.id) == []
    end
  end
end

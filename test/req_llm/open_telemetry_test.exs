defmodule ReqLLM.OpenTelemetryTest do
  use ExUnit.Case, async: true

  alias ReqLLM.OpenTelemetry

  defp decode_all(entries) when is_list(entries), do: Enum.map(entries, &Jason.decode!/1)

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

  test "publishes the stable lifecycle subset and rejects duplicate handler ids safely" do
    handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"

    assert OpenTelemetry.events() == [
             [:req_llm, :request, :start],
             [:req_llm, :request, :stop],
             [:req_llm, :request, :exception]
           ]

    assert :ok = OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())

    on_exit(fn ->
      OpenTelemetry.detach(handler_id)
    end)

    assert {:error, :already_exists} =
             OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())

    Enum.each(OpenTelemetry.events(), fn event ->
      assert Enum.count(:telemetry.list_handlers(event), &(&1.id == handler_id)) == 1
    end)
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

  describe ":content option" do
    alias ReqLLM.{Message, ToolCall}
    alias ReqLLM.Message.ContentPart

    test "default (:none) does not attach content attributes" do
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

    test "content: :attributes promotes messages, system_instructions, tool definitions onto the span" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok =
               OpenTelemetry.attach(handler_id,
                 adapter: FakeAdapter,
                 content: :attributes,
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

      assert decode_all(attributes[:"gen_ai.system_instructions"]) == [
               %{"type" => "text", "content" => "be helpful"}
             ]

      assert [
               %{"role" => "user"},
               %{"role" => "assistant"}
             ] = decode_all(attributes[:"gen_ai.input.messages"])

      assert [
               %{
                 "type" => "function",
                 "name" => "get_weather",
                 "description" => "fetch",
                 "strict" => true,
                 "parameters" => %{"type" => "object"}
               }
             ] = decode_all(attributes[:"gen_ai.tool.definitions"])
    end

    test "content: :attributes attaches gen_ai.output.messages on stop" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok =
               OpenTelemetry.attach(handler_id,
                 adapter: FakeAdapter,
                 content: :attributes,
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

      assert decode_all(attributes[:"gen_ai.output.messages"]) == [
               %{
                 "role" => "assistant",
                 "parts" => [%{"type" => "text", "content" => "hi back"}],
                 "finish_reason" => "stop"
               }
             ]
    end

    test "content: :event emits a single inference event on stop without attaching content attrs" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok =
               OpenTelemetry.attach(handler_id,
                 adapter: FakeAdapter,
                 content: :event,
                 test_pid: self()
               )

      on_exit(fn -> OpenTelemetry.detach(handler_id) end)

      model = %LLMDB.Model{id: "gpt-5", provider: :openai}

      :telemetry.execute(
        [:req_llm, :request, :start],
        %{system_time: System.system_time()},
        %{
          request_id: request_id,
          operation: :chat,
          provider: :openai,
          model: model,
          request_payload: %{
            messages: [
              %Message{role: :system, content: [%ContentPart{type: :text, text: "be helpful"}]},
              %Message{role: :user, content: [%ContentPart{type: :text, text: "hi"}]}
            ]
          }
        }
      )

      assert_receive {:start_span, span, _name, start_attrs}
      refute Map.has_key?(start_attrs, :"gen_ai.input.messages")
      refute Map.has_key?(start_attrs, :"gen_ai.system_instructions")

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
          request_payload: %{
            messages: [
              %Message{role: :system, content: [%ContentPart{type: :text, text: "be helpful"}]},
              %Message{role: :user, content: [%ContentPart{type: :text, text: "hi"}]}
            ]
          },
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

      assert_receive {:set_attributes, ^span, stop_attrs}
      refute Map.has_key?(stop_attrs, :"gen_ai.input.messages")
      refute Map.has_key?(stop_attrs, :"gen_ai.output.messages")

      assert_receive {:add_event, ^span, :"gen_ai.client.inference.operation.details",
                      event_attrs}

      assert event_attrs[:"gen_ai.operation.name"] == "chat"
      assert event_attrs[:"gen_ai.provider.name"] == "openai"
      assert event_attrs[:"gen_ai.request.model"] == "gpt-5"
      assert event_attrs[:"gen_ai.response.finish_reasons"] == ["stop"]

      assert event_attrs[:"gen_ai.system_instructions"] == [
               %{"type" => "text", "content" => "be helpful"}
             ]

      assert [%{"role" => "user"}] = event_attrs[:"gen_ai.input.messages"]

      assert [%{"role" => "assistant"}] = event_attrs[:"gen_ai.output.messages"]
      refute Enum.any?(event_attrs[:"gen_ai.input.messages"], &is_binary/1)
      refute Enum.any?(event_attrs[:"gen_ai.output.messages"], &is_binary/1)
    end

    test "content: true is accepted as an alias for :attributes" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok =
               OpenTelemetry.attach(handler_id,
                 adapter: FakeAdapter,
                 content: true,
                 test_pid: self()
               )

      on_exit(fn -> OpenTelemetry.detach(handler_id) end)

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
              %Message{role: :user, content: [%ContentPart{type: :text, text: "hi"}]}
            ]
          }
        }
      )

      assert_receive {:start_span, _span, _name, attributes}
      assert [%{"role" => "user"}] = decode_all(attributes[:"gen_ai.input.messages"])
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

  describe "cost capture" do
    test "emits gen_ai.usage.cost on stop when total_cost is present" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok = OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())
      on_exit(fn -> OpenTelemetry.detach(handler_id) end)

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
          usage: %{
            input_tokens: 100,
            output_tokens: 50,
            input_cost: 0.001,
            output_cost: 0.002,
            total_cost: 0.003
          }
        }
      )

      assert_receive {:set_attributes, ^span, attrs}
      assert attrs[:"gen_ai.usage.cost"] == 0.003
      refute Map.has_key?(attrs, :"langfuse.observation.cost_details")
    end

    test "skips gen_ai.usage.cost when total_cost is missing" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok = OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())
      on_exit(fn -> OpenTelemetry.detach(handler_id) end)

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
          usage: %{input_tokens: 100, output_tokens: 50}
        }
      )

      assert_receive {:set_attributes, ^span, attrs}
      refute Map.has_key?(attrs, :"gen_ai.usage.cost")
    end

    test "langfuse: true adds langfuse.observation.cost_details JSON" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok =
               OpenTelemetry.attach(handler_id,
                 adapter: FakeAdapter,
                 test_pid: self(),
                 langfuse: true
               )

      on_exit(fn -> OpenTelemetry.detach(handler_id) end)

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
          usage: %{
            input_tokens: 100,
            output_tokens: 50,
            input_cost: 0.001,
            output_cost: 0.002,
            reasoning_cost: 0.0005,
            total_cost: 0.0035
          }
        }
      )

      assert_receive {:set_attributes, ^span, attrs}
      assert attrs[:"gen_ai.usage.cost"] == 0.0035

      assert {:ok, decoded} = Jason.decode(attrs[:"langfuse.observation.cost_details"])

      assert decoded == %{
               "input" => 0.001,
               "output" => 0.002,
               "reasoning" => 0.0005,
               "total" => 0.0035
             }
    end
  end

  describe "OpenAI extensions" do
    test "emits openai.api.type and openai.request.service_tier on start" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok = OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())
      on_exit(fn -> OpenTelemetry.detach(handler_id) end)

      model = %LLMDB.Model{id: "gpt-5", provider: :openai}

      :telemetry.execute(
        [:req_llm, :request, :start],
        %{system_time: System.system_time()},
        %{
          request_id: request_id,
          operation: :chat,
          provider: :openai,
          model: model,
          request_options: %{service_tier: "priority"},
          server: %{address: "api.openai.com", port: 443, path: "/v1/chat/completions"}
        }
      )

      assert_receive {:start_span, _span, _name, attrs}
      assert attrs[:"openai.api.type"] == "chat_completions"
      assert attrs[:"openai.request.service_tier"] == "priority"
    end

    test "emits openai.response.{service_tier,system_fingerprint} on stop" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok = OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())
      on_exit(fn -> OpenTelemetry.detach(handler_id) end)

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
          usage: %{input_tokens: 1, output_tokens: 1},
          response_payload: %{
            provider_meta: %{
              "service_tier" => "default",
              "system_fingerprint" => "fp_abc123"
            }
          }
        }
      )

      assert_receive {:set_attributes, ^span, attrs}
      assert attrs[:"openai.response.service_tier"] == "default"
      assert attrs[:"openai.response.system_fingerprint"] == "fp_abc123"
    end

    test "skips openai.* attributes for non-OpenAI providers" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      request_id = "req-#{System.unique_integer([:positive])}"

      assert :ok = OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())
      on_exit(fn -> OpenTelemetry.detach(handler_id) end)

      model = %LLMDB.Model{id: "claude-haiku-4-5", provider: :anthropic}

      :telemetry.execute(
        [:req_llm, :request, :start],
        %{system_time: System.system_time()},
        %{
          request_id: request_id,
          operation: :chat,
          provider: :anthropic,
          model: model,
          request_options: %{service_tier: "priority"},
          server: %{address: "api.anthropic.com", port: 443, path: "/v1/messages"}
        }
      )

      assert_receive {:start_span, _span, _name, attrs}
      refute Map.has_key?(attrs, :"openai.api.type")
      refute Map.has_key?(attrs, :"openai.request.service_tier")
    end
  end

  describe "prune_stale_spans/2" do
    test "removes entries older than the TTL and leaves recent ones intact" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"
      stale_id = "stale-#{System.unique_integer([:positive])}"
      fresh_id = "fresh-#{System.unique_integer([:positive])}"

      assert :ok = OpenTelemetry.attach(handler_id, adapter: FakeAdapter, test_pid: self())

      on_exit(fn -> OpenTelemetry.detach(handler_id) end)

      :telemetry.execute(
        [:req_llm, :request, :start],
        %{system_time: System.system_time()},
        %{
          request_id: stale_id,
          operation: :chat,
          provider: :openai,
          model: %LLMDB.Model{id: "gpt-5", provider: :openai}
        }
      )

      assert_receive {:start_span, _stale_span, _name, _attrs}

      Process.sleep(20)

      :telemetry.execute(
        [:req_llm, :request, :start],
        %{system_time: System.system_time()},
        %{
          request_id: fresh_id,
          operation: :chat,
          provider: :openai,
          model: %LLMDB.Model{id: "gpt-5", provider: :openai}
        }
      )

      assert_receive {:start_span, _fresh_span, _name, _attrs}

      assert OpenTelemetry.prune_stale_spans(handler_id, 10) >= 1

      table = :req_llm_open_telemetry_spans
      refute :ets.member(table, {handler_id, stale_id})
      assert :ets.member(table, {handler_id, fresh_id})
    end

    test "scopes pruning to the matching handler id" do
      handler_a = "req-llm-otel-a-#{System.unique_integer([:positive])}"
      handler_b = "req-llm-otel-b-#{System.unique_integer([:positive])}"

      assert :ok = OpenTelemetry.attach(handler_a, adapter: FakeAdapter, test_pid: self())
      assert :ok = OpenTelemetry.attach(handler_b, adapter: FakeAdapter, test_pid: self())

      on_exit(fn ->
        OpenTelemetry.detach(handler_a)
        OpenTelemetry.detach(handler_b)
      end)

      shared_id = "req-#{System.unique_integer([:positive])}"

      :telemetry.execute(
        [:req_llm, :request, :start],
        %{system_time: System.system_time()},
        %{
          request_id: shared_id,
          operation: :chat,
          provider: :openai,
          model: %LLMDB.Model{id: "gpt-5", provider: :openai}
        }
      )

      assert_receive {:start_span, _, _, _}
      assert_receive {:start_span, _, _, _}

      Process.sleep(20)
      assert OpenTelemetry.prune_stale_spans(handler_a, 10) >= 1

      table = :req_llm_open_telemetry_spans
      refute :ets.member(table, {handler_a, shared_id})
      assert :ets.member(table, {handler_b, shared_id})
    end
  end

  describe "handler exception resilience" do
    defmodule RaisingAdapter do
      @behaviour ReqLLM.OpenTelemetry.Adapter

      @impl true
      def available?, do: true

      @impl true
      def start_span(_name, _attributes, config) do
        send(config[:test_pid], :start_span_called)
        raise "boom"
      end

      @impl true
      def set_attributes(_, _, _), do: :ok

      @impl true
      def add_event(_, _, _, _), do: :ok

      @impl true
      def set_status(_, _, _, _), do: :ok

      @impl true
      def end_span(_, _), do: :ok
    end

    test "survives an adapter that raises and stays attached" do
      handler_id = "req-llm-otel-#{System.unique_integer([:positive])}"

      assert :ok = OpenTelemetry.attach(handler_id, adapter: RaisingAdapter, test_pid: self())
      on_exit(fn -> OpenTelemetry.detach(handler_id) end)

      model = %LLMDB.Model{id: "gpt-5", provider: :openai}

      metadata = fn ->
        %{
          request_id: "req-#{System.unique_integer([:positive])}",
          operation: :chat,
          provider: :openai,
          model: model
        }
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :telemetry.execute(
            [:req_llm, :request, :start],
            %{system_time: System.system_time()},
            metadata.()
          )

          assert_receive :start_span_called

          :telemetry.execute(
            [:req_llm, :request, :start],
            %{system_time: System.system_time()},
            metadata.()
          )

          assert_receive :start_span_called
        end)

      assert log =~ "ReqLLM.OpenTelemetry: handler crashed"
      assert log =~ "boom"
    end
  end
end

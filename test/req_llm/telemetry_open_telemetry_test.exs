defmodule ReqLLM.TelemetryOpenTelemetryTest do
  use ExUnit.Case, async: true

  import ReqLLM.Context

  alias ReqLLM.Telemetry.OpenTelemetry
  alias ReqLLM.ToolCall

  defp decode_all(entries) when is_list(entries), do: Enum.map(entries, &Jason.decode!/1)

  test "maps chat telemetry metadata into GenAI span attributes" do
    tool_call = ToolCall.new("call_weather", "get_weather", ~s({"location":"Paris"}))

    metadata = %{
      operation: :chat,
      provider: :openai,
      model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
      request_payload: %{
        messages: [
          system("You are a helpful bot"),
          user("Weather in Paris?"),
          assistant("", tool_calls: [tool_call]),
          tool_result("call_weather", "rainy, 57F")
        ]
      }
    }

    start_stub = OpenTelemetry.request_start(metadata, content: :attributes)

    assert start_stub.name == "chat gpt-5"
    assert start_stub.kind == :client
    assert start_stub.attributes["gen_ai.provider.name"] == "openai"
    assert start_stub.attributes["gen_ai.operation.name"] == "chat"
    assert start_stub.attributes["gen_ai.request.model"] == "gpt-5"

    assert decode_all(start_stub.attributes["gen_ai.system_instructions"]) == [
             %{"type" => "text", "content" => "You are a helpful bot"}
           ]

    assert decode_all(start_stub.attributes["gen_ai.input.messages"]) == [
             %{
               "role" => "user",
               "parts" => [%{"type" => "text", "content" => "Weather in Paris?"}]
             },
             %{
               "role" => "assistant",
               "parts" => [
                 %{
                   "type" => "tool_call",
                   "id" => "call_weather",
                   "name" => "get_weather",
                   "arguments" => %{"location" => "Paris"}
                 }
               ]
             },
             %{
               "role" => "tool",
               "parts" => [
                 %{
                   "type" => "tool_call_response",
                   "id" => "call_weather",
                   "response" => "rainy, 57F"
                 }
               ]
             }
           ]

    assert start_stub.events == []
  end

  test "maps terminal response metadata, usage, and finish reasons" do
    metadata = %{
      operation: :chat,
      provider: :openai,
      model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
      finish_reason: :stop,
      usage: %{tokens: %{input: 97, output: 52, reasoning: 17}, cost: nil},
      response_payload: %ReqLLM.Response{
        id: "resp_123",
        model: "gpt-5-2026-03-01",
        context: nil,
        message: assistant("The weather in Paris is rainy with a temperature of 57F."),
        object: nil,
        stream?: false,
        stream: nil,
        usage: nil,
        finish_reason: :stop,
        provider_meta: %{},
        error: nil
      }
    }

    stop_stub = OpenTelemetry.request_stop(metadata, content: :attributes)

    assert stop_stub.status == :ok
    assert stop_stub.attributes["gen_ai.response.id"] == "resp_123"
    assert stop_stub.attributes["gen_ai.response.model"] == "gpt-5-2026-03-01"
    assert stop_stub.attributes["gen_ai.usage.input_tokens"] == 97
    assert stop_stub.attributes["gen_ai.usage.output_tokens"] == 52
    assert stop_stub.attributes["gen_ai.response.finish_reasons"] == ["stop"]

    assert decode_all(stop_stub.attributes["gen_ai.output.messages"]) == [
             %{
               "role" => "assistant",
               "parts" => [
                 %{
                   "type" => "text",
                   "content" => "The weather in Paris is rainy with a temperature of 57F."
                 }
               ],
               "finish_reason" => "stop"
             }
           ]
  end

  test "emits gen_ai.request.* and server.* attributes from request_options/server metadata" do
    metadata = %{
      operation: :chat,
      provider: :openai,
      model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
      request_options: %{
        temperature: 0.7,
        top_p: 0.95,
        top_k: 40,
        max_tokens: 256,
        frequency_penalty: 0.1,
        presence_penalty: 0.2,
        stop_sequences: ["END"],
        seed: 42,
        stream?: true,
        encoding_formats: ["float"],
        conversation_id: "session-abc"
      },
      server: %{address: "api.openai.com", port: 443}
    }

    stub = OpenTelemetry.request_start(metadata)

    assert stub.attributes["gen_ai.request.temperature"] == 0.7
    assert stub.attributes["gen_ai.request.top_p"] == 0.95
    assert stub.attributes["gen_ai.request.top_k"] == 40
    assert stub.attributes["gen_ai.request.max_tokens"] == 256
    assert stub.attributes["gen_ai.request.frequency_penalty"] == 0.1
    assert stub.attributes["gen_ai.request.presence_penalty"] == 0.2
    assert stub.attributes["gen_ai.request.stop_sequences"] == ["END"]
    assert stub.attributes["gen_ai.request.seed"] == 42
    assert stub.attributes["gen_ai.request.stream"] == true
    assert stub.attributes["gen_ai.request.encoding_formats"] == ["float"]
    assert stub.attributes["gen_ai.conversation.id"] == "session-abc"
    assert stub.attributes["server.address"] == "api.openai.com"
    assert stub.attributes["server.port"] == 443
    assert stub.attributes["gen_ai.output.type"] == "text"
  end

  test "emits gen_ai.request.choice.count when n is set" do
    metadata = %{
      operation: :chat,
      provider: :openai,
      model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
      request_options: %{n: 3}
    }

    stub = OpenTelemetry.request_start(metadata)

    assert stub.attributes["gen_ai.request.choice.count"] == 3
  end

  test "emits gen_ai.embeddings.dimension.count for embedding responses" do
    metadata = %{
      operation: :embedding,
      provider: :openai,
      model: %LLMDB.Model{provider: :openai, id: "text-embedding-3-small"},
      finish_reason: nil,
      usage: %{input_tokens: 4, output_tokens: 0},
      response_summary: %{dimensions: 1536}
    }

    stub = OpenTelemetry.request_stop(metadata)

    assert stub.attributes["gen_ai.embeddings.dimension.count"] == 1536
  end

  test "emits cache read and creation token attributes when present in usage" do
    metadata = %{
      operation: :chat,
      provider: :openai,
      model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
      finish_reason: :stop,
      usage: %{
        tokens: %{
          input: 10,
          output: 20,
          cached_input: 4,
          cache_creation: 3
        }
      }
    }

    stub = OpenTelemetry.request_stop(metadata)

    assert stub.attributes["gen_ai.usage.input_tokens"] == 10
    assert stub.attributes["gen_ai.usage.output_tokens"] == 20
    assert stub.attributes["gen_ai.usage.cache_read.input_tokens"] == 4
    assert stub.attributes["gen_ai.usage.cache_creation.input_tokens"] == 3
  end

  test "emits gen_ai.usage.reasoning.output_tokens" do
    metadata = %{
      operation: :chat,
      provider: :openai,
      model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
      finish_reason: :stop,
      usage: %{input_tokens: 12, output_tokens: 8, reasoning_tokens: 64}
    }

    stub = OpenTelemetry.request_stop(metadata)

    assert stub.attributes["gen_ai.usage.reasoning.output_tokens"] == 64
  end

  test "sets error.type and error span status on stop with HTTP failure" do
    metadata = %{
      operation: :chat,
      provider: :openai,
      model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
      finish_reason: nil,
      http_status: 503,
      usage: nil
    }

    stub = OpenTelemetry.request_stop(metadata)

    assert stub.attributes["error.type"] == "503"
    assert stub.status == {:error, "HTTP 503"}
  end

  test "builds exception status and event payloads" do
    metadata = %{
      operation: :chat,
      provider: :openai,
      model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
      http_status: 500,
      error: RuntimeError.exception("boom")
    }

    exception_stub = OpenTelemetry.request_exception(metadata)

    assert exception_stub.status == {:error, "boom"}
    assert exception_stub.attributes["error.type"] == "RuntimeError"

    assert exception_stub.events == [
             %{
               name: "exception",
               attributes: %{
                 "exception.type" => "RuntimeError",
                 "exception.message" => "boom"
               }
             }
           ]
  end

  describe "content capture" do
    test "defaults to :none — no content attributes or events" do
      metadata = %{
        operation: :chat,
        provider: :openai,
        model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
        request_payload: %{
          messages: [system("you are helpful"), user("hi")],
          tools: [%{name: "get_weather", description: "fetch", parameter_schema: %{}}]
        }
      }

      start_stub = OpenTelemetry.request_start(metadata)

      refute Map.has_key?(start_stub.attributes, "gen_ai.input.messages")
      refute Map.has_key?(start_stub.attributes, "gen_ai.system_instructions")
      refute Map.has_key?(start_stub.attributes, "gen_ai.tool.definitions")
      assert start_stub.events == []
    end

    test "emits gen_ai.tool.definitions when tools are present" do
      metadata = %{
        operation: :chat,
        provider: :openai,
        model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
        request_payload: %{
          messages: [user("ping")],
          tools: [
            %{
              name: "get_weather",
              description: "fetch the weather",
              strict: true,
              parameter_schema: %{
                "type" => "object",
                "properties" => %{"location" => %{"type" => "string"}}
              }
            }
          ]
        }
      }

      start_stub = OpenTelemetry.request_start(metadata, content: :attributes)

      assert decode_all(start_stub.attributes["gen_ai.tool.definitions"]) == [
               %{
                 "type" => "function",
                 "name" => "get_weather",
                 "description" => "fetch the weather",
                 "strict" => true,
                 "parameters" => %{
                   "type" => "object",
                   "properties" => %{"location" => %{"type" => "string"}}
                 }
               }
             ]
    end

    test "preserves strict: false on tool definitions (regression: false was being dropped)" do
      metadata = %{
        operation: :chat,
        provider: :openai,
        model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
        request_payload: %{
          messages: [user("ping")],
          tools: [
            %{
              name: "get_weather",
              description: "fetch",
              strict: false,
              parameter_schema: %{"type" => "object"}
            }
          ]
        }
      }

      start_stub = OpenTelemetry.request_start(metadata, content: :attributes)

      assert [tool] = decode_all(start_stub.attributes["gen_ai.tool.definitions"])
      assert tool["strict"] == false
    end

    test "content: :event keeps content off start_stub attributes and defers the event to terminal" do
      tool_call = ToolCall.new("call_weather", "get_weather", ~s({"location":"Paris"}))

      metadata = %{
        operation: :chat,
        provider: :openai,
        model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
        request_payload: %{
          messages: [
            system("you are helpful"),
            user("Weather in Paris?"),
            assistant("", tool_calls: [tool_call])
          ],
          tools: [%{name: "get_weather", description: "fetch", parameter_schema: %{}}]
        }
      }

      start_stub = OpenTelemetry.request_start(metadata, content: :event)

      refute Map.has_key?(start_stub.attributes, "gen_ai.input.messages")
      refute Map.has_key?(start_stub.attributes, "gen_ai.system_instructions")
      refute Map.has_key?(start_stub.attributes, "gen_ai.tool.definitions")
      assert start_stub.events == []
    end

    test "content: :event on stop emits operation attributes and structured content" do
      metadata = %{
        operation: :chat,
        provider: :openai,
        model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
        finish_reason: :stop,
        usage: %{tokens: %{input: 10, output: 20}},
        request_payload: %{
          messages: [system("you are helpful"), user("hi")],
          tools: []
        },
        response_payload: %ReqLLM.Response{
          id: "resp_x",
          model: "gpt-5",
          context: nil,
          message: assistant("hello back"),
          object: nil,
          stream?: false,
          stream: nil,
          usage: nil,
          finish_reason: :stop,
          provider_meta: %{},
          error: nil
        }
      }

      stop_stub = OpenTelemetry.request_stop(metadata, content: :event)

      refute Map.has_key?(stop_stub.attributes, "gen_ai.input.messages")
      refute Map.has_key?(stop_stub.attributes, "gen_ai.output.messages")

      assert [event] = stop_stub.events
      assert event.name == "gen_ai.client.inference.operation.details"
      assert event.attributes["gen_ai.operation.name"] == "chat"
      assert event.attributes["gen_ai.provider.name"] == "openai"
      assert event.attributes["gen_ai.request.model"] == "gpt-5"
      assert event.attributes["gen_ai.response.finish_reasons"] == ["stop"]
      assert [%{"role" => "user"}] = event.attributes["gen_ai.input.messages"]
      assert [%{"role" => "assistant"}] = event.attributes["gen_ai.output.messages"]
      refute Enum.any?(event.attributes["gen_ai.input.messages"], &is_binary/1)
      refute Enum.any?(event.attributes["gen_ai.output.messages"], &is_binary/1)
    end

    test "reasoning text is not included in content attributes even with :attributes mode" do
      reasoning_part = %ReqLLM.Message.ContentPart{type: :thinking, text: "secret reasoning"}

      assistant_message = %ReqLLM.Message{
        role: :assistant,
        content: [
          reasoning_part,
          %ReqLLM.Message.ContentPart{type: :text, text: "the public answer"}
        ]
      }

      metadata = %{
        operation: :chat,
        provider: :openai,
        model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
        finish_reason: :stop,
        usage: %{tokens: %{input: 1, output: 1}},
        request_payload: %{
          messages: [
            system("system prompt with secret <thinking>not really</thinking>"),
            user("hi")
          ]
        },
        response_payload: %ReqLLM.Response{
          id: "resp_x",
          model: "gpt-5",
          context: nil,
          message: assistant_message,
          object: nil,
          stream?: false,
          stream: nil,
          usage: nil,
          finish_reason: :stop,
          provider_meta: %{},
          error: nil
        }
      }

      stop_stub = OpenTelemetry.request_stop(metadata, content: :attributes)

      output = decode_all(stop_stub.attributes["gen_ai.output.messages"])

      assert output == [
               %{
                 "role" => "assistant",
                 "parts" => [%{"type" => "text", "content" => "the public answer"}],
                 "finish_reason" => "stop"
               }
             ]

      refute Enum.any?(output, fn message ->
               Enum.any?(message["parts"], fn part -> part["type"] == "thinking" end)
             end)
    end
  end

  describe "metrics + streaming timings" do
    defp millisecond_to_native(ms),
      do: System.convert_time_unit(ms, :millisecond, :native)

    defp by_name(records, name), do: Enum.filter(records, &(&1.name == name))

    test "request_stop/2 returns empty metrics when measurements are absent" do
      stub =
        ReqLLM.Telemetry.OpenTelemetry.request_stop(%{
          request_id: "1",
          operation: :chat,
          mode: :sync,
          provider: :openai,
          model: %LLMDB.Model{id: "gpt-5", provider: :openai},
          usage: %{tokens: %{input: 10, output: 20}}
        })

      assert stub.metrics == []
    end

    test "request_stop/2 builds duration + token records and TTFC span attribute" do
      ttfc_native = millisecond_to_native(120)
      duration_native = millisecond_to_native(900)

      stub =
        ReqLLM.Telemetry.OpenTelemetry.request_stop(
          %{
            request_id: "1",
            operation: :chat,
            mode: :stream,
            provider: :openai,
            model: %LLMDB.Model{id: "gpt-5", provider: :openai},
            server: %{address: "api.openai.com", port: 443},
            streaming: %{first_chunk_at: 0, time_to_first_chunk: ttfc_native},
            usage: %{tokens: %{input: 25, output: 50}}
          },
          measurements: %{duration: duration_native}
        )

      assert_in_delta(
        stub.attributes["gen_ai.response.time_to_first_chunk"],
        0.12,
        0.001
      )

      assert [duration] = by_name(stub.metrics, "gen_ai.client.operation.duration")
      assert_in_delta(duration.value, 0.9, 0.05)

      tokens = by_name(stub.metrics, "gen_ai.client.token.usage")
      assert length(tokens) == 2

      assert [ttfc] = by_name(stub.metrics, "gen_ai.client.operation.time_to_first_chunk")
      assert_in_delta(ttfc.value, 0.12, 0.001)

      assert [tpoc] = by_name(stub.metrics, "gen_ai.client.operation.time_per_output_chunk")
      assert_in_delta(tpoc.value, (0.9 - 0.12) / 50, 0.001)
    end

    test "request_exception/2 records duration with error.type" do
      stub =
        ReqLLM.Telemetry.OpenTelemetry.request_exception(
          %{
            request_id: "1",
            operation: :chat,
            mode: :sync,
            provider: :openai,
            model: %LLMDB.Model{id: "gpt-5", provider: :openai},
            error: %RuntimeError{message: "boom"}
          },
          measurements: %{duration: millisecond_to_native(50)}
        )

      assert [duration] = stub.metrics
      assert duration.name == "gen_ai.client.operation.duration"
      assert duration.attributes["error.type"] == "RuntimeError"
    end
  end

  describe "cost capture" do
    test "emits gen_ai.usage.cost when usage carries total_cost" do
      metadata = %{
        operation: :chat,
        provider: :openai,
        model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
        finish_reason: :stop,
        usage: %{
          input_tokens: 100,
          output_tokens: 50,
          input_cost: 0.001,
          output_cost: 0.002,
          total_cost: 0.003
        }
      }

      stub = OpenTelemetry.request_stop(metadata)

      assert stub.attributes["gen_ai.usage.cost"] == 0.003
    end

    test "omits gen_ai.usage.cost when total_cost is missing" do
      metadata = %{
        operation: :chat,
        provider: :openai,
        model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
        finish_reason: :stop,
        usage: %{input_tokens: 100, output_tokens: 50}
      }

      stub = OpenTelemetry.request_stop(metadata)

      refute Map.has_key?(stub.attributes, "gen_ai.usage.cost")
    end

    test "langfuse: true emits langfuse.observation.cost_details JSON" do
      metadata = %{
        operation: :chat,
        provider: :openai,
        model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
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

      stub = OpenTelemetry.request_stop(metadata, langfuse: true)

      assert {:ok, decoded} = Jason.decode(stub.attributes["langfuse.observation.cost_details"])

      assert decoded == %{
               "input" => 0.001,
               "output" => 0.002,
               "reasoning" => 0.0005,
               "total" => 0.0035
             }
    end

    test "langfuse: true is a no-op when no cost data is available" do
      metadata = %{
        operation: :chat,
        provider: :openai,
        model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
        finish_reason: :stop,
        usage: %{input_tokens: 100, output_tokens: 50}
      }

      stub = OpenTelemetry.request_stop(metadata, langfuse: true)

      refute Map.has_key?(stub.attributes, "langfuse.observation.cost_details")
    end
  end

  describe "OpenAI extensions" do
    test "emits openai.api.type and openai.request.service_tier on chat completions" do
      metadata = %{
        operation: :chat,
        provider: :openai,
        model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
        request_options: %{service_tier: "priority"},
        server: %{address: "api.openai.com", port: 443, path: "/v1/chat/completions"}
      }

      stub = OpenTelemetry.request_start(metadata)

      assert stub.attributes["openai.api.type"] == "chat_completions"
      assert stub.attributes["openai.request.service_tier"] == "priority"
    end

    test "infers openai.api.type=responses from /responses path" do
      metadata = %{
        operation: :chat,
        provider: :openai,
        model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
        server: %{address: "api.openai.com", port: 443, path: "/v1/responses"}
      }

      stub = OpenTelemetry.request_start(metadata)

      assert stub.attributes["openai.api.type"] == "responses"
    end

    test "infers openai.api.type=embeddings from /embeddings path" do
      metadata = %{
        operation: :embedding,
        provider: :openai,
        model: %LLMDB.Model{provider: :openai, id: "text-embedding-3-small"},
        server: %{address: "api.openai.com", port: 443, path: "/v1/embeddings"}
      }

      stub = OpenTelemetry.request_start(metadata)

      assert stub.attributes["openai.api.type"] == "embeddings"
    end

    test "emits openai.response.{service_tier,system_fingerprint} from response payload provider_meta" do
      metadata = %{
        operation: :chat,
        provider: :openai,
        model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
        finish_reason: :stop,
        usage: %{input_tokens: 1, output_tokens: 1},
        response_payload: %{
          provider_meta: %{
            "service_tier" => "default",
            "system_fingerprint" => "fp_abc123"
          }
        }
      }

      stub = OpenTelemetry.request_stop(metadata)

      assert stub.attributes["openai.response.service_tier"] == "default"
      assert stub.attributes["openai.response.system_fingerprint"] == "fp_abc123"
    end

    test "skips OpenAI extensions for non-OpenAI providers" do
      metadata = %{
        operation: :chat,
        provider: :anthropic,
        model: %LLMDB.Model{provider: :anthropic, id: "claude-haiku-4-5"},
        request_options: %{service_tier: "priority"},
        server: %{address: "api.anthropic.com", port: 443, path: "/v1/messages"}
      }

      stub = OpenTelemetry.request_start(metadata)

      refute Map.has_key?(stub.attributes, "openai.api.type")
      refute Map.has_key?(stub.attributes, "openai.request.service_tier")
    end

    test "applies OpenAI extensions to azure provider" do
      metadata = %{
        operation: :chat,
        provider: :azure,
        model: %LLMDB.Model{provider: :azure, id: "gpt-5"},
        request_options: %{service_tier: "priority"},
        server: %{
          address: "my-resource.openai.azure.com",
          port: 443,
          path: "/openai/deployments/gpt-5/chat/completions"
        }
      }

      stub = OpenTelemetry.request_start(metadata)

      assert stub.attributes["openai.api.type"] == "chat_completions"
      assert stub.attributes["openai.request.service_tier"] == "priority"
    end

    test "decoded OpenAI response carries service_tier/system_fingerprint through to OTel attrs" do
      model = %LLMDB.Model{provider: :openai, id: "gpt-5"}

      raw_body = %{
        "id" => "chatcmpl-abc",
        "model" => "gpt-5-2026-03-01",
        "service_tier" => "default",
        "system_fingerprint" => "fp_4fae27f477",
        "choices" => [
          %{"message" => %{"content" => "ok"}, "finish_reason" => "stop"}
        ],
        "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 2, "total_tokens" => 6}
      }

      {:ok, decoded} =
        ReqLLM.Provider.Defaults.decode_response_body_openai_format(raw_body, model)

      assert decoded.provider_meta["service_tier"] == "default"
      assert decoded.provider_meta["system_fingerprint"] == "fp_4fae27f477"

      stub =
        OpenTelemetry.request_stop(%{
          operation: :chat,
          provider: :openai,
          model: model,
          finish_reason: :stop,
          usage: decoded.usage,
          response_payload: decoded,
          server: %{address: "api.openai.com", port: 443, path: "/v1/chat/completions"}
        })

      assert stub.attributes["openai.response.service_tier"] == "default"
      assert stub.attributes["openai.response.system_fingerprint"] == "fp_4fae27f477"
      assert stub.attributes["openai.api.type"] == "chat_completions"
    end
  end
end

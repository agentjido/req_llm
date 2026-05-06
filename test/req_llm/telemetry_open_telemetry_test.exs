defmodule ReqLLM.TelemetryOpenTelemetryTest do
  use ExUnit.Case, async: true

  import ReqLLM.Context

  alias ReqLLM.Telemetry.OpenTelemetry
  alias ReqLLM.ToolCall

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

    assert start_stub.attributes["gen_ai.input.messages"] == [
             %{
               "role" => "system",
               "parts" => [%{"type" => "text", "content" => "You are a helpful bot"}]
             },
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

    assert stop_stub.attributes["gen_ai.output.messages"] == [
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
end

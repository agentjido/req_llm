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

# test/ontology_roundtrip_test.exs
# Purpose: Sanity round-trip tests proving Σ→Π ggen adapters behave deterministically.

defmodule ReqLLM.Ontology.RoundTripTest do
  use ExUnit.Case, async: true
  alias ReqLLM.Ontology.{Emitter, Parser}

  test "response serialization round-trip" do
    response = %{
      id: "resp_123",
      finish_reason: :stop,
      usage: %{input_tokens: 10, output_tokens: 17, total_tokens: 27},
      context: %{
        external_id: "ctx_9",
        messages: [
          %{role: :system, position: 0, parts: [%{type: :TextPart, text: "You are..."}]},
          %{role: :user, position: 1, parts: [%{type: :TextPart, text: "Hi!"}]}
        ]
      },
      message: %{role: :assistant, position: 2, parts: [%{type: :TextPart, text: "Hello!"}]}
    }

    jsonld = Emitter.emit_response(response)
    assert jsonld["@type"] == "Response"
    assert is_map(jsonld["@context"])

    {:ok, parsed} = Parser.parse_response(jsonld)

    # Ensure core invariants hold (exact struct equality not required for brownfield maps)
    assert parsed.id == response.id
    assert parsed.finish_reason == response.finish_reason
    assert length(parsed.context.messages) == 2
    assert hd(parsed.context.messages).role == :system
  end

  test "context with multiple messages" do
    context = %{
      external_id: "ctx_test",
      messages: [
        %{role: :system, position: 0, parts: [%{type: :TextPart, text: "System prompt"}]},
        %{role: :user, position: 1, parts: [%{type: :TextPart, text: "User message"}]},
        %{role: :assistant, position: 2, parts: [%{type: :TextPart, text: "Assistant response"}]}
      ]
    }

    jsonld = Emitter.emit_context(context)
    assert jsonld["@type"] == "Context"
    assert length(jsonld["hasMessage"]) == 3

    parsed = Parser.parse_context(jsonld)
    assert parsed.external_id == "ctx_test"
    assert length(parsed.messages) == 3
  end

  test "message with tool call parts" do
    message = %{
      role: :assistant,
      position: 0,
      parts: [
        %{type: :ToolCallPart, tool_name: "get_weather", arguments_json: "{\"city\":\"NYC\"}"}
      ]
    }

    jsonld = Emitter.emit_message(message)
    assert jsonld["@type"] == "Message"
    assert length(jsonld["hasPart"]) == 1

    parsed = Parser.parse_message(jsonld)
    assert parsed.role == :assistant
    assert hd(parsed.parts).type == :ToolCallPart
    assert hd(parsed.parts).tool_name == "get_weather"
  end

  test "usage metrics serialization" do
    usage = %{
      input_tokens: 100,
      output_tokens: 50,
      reasoning_tokens: 25,
      total_tokens: 175,
      input_cost: 0.001,
      output_cost: 0.002,
      total_cost: 0.003
    }

    jsonld = Emitter.emit_usage(usage)
    assert jsonld["@type"] == "Usage"
    assert jsonld["inputTokens"] == 100
    assert jsonld["totalCost"] == 0.003

    parsed = Parser.parse_usage(jsonld)
    assert parsed.input_tokens == 100
    assert parsed.total_cost == 0.003
  end

  test "stream chunk serialization" do
    chunk = %{
      type: :content,
      text: "Hello",
      metadata: %{timestamp: 123}
    }

    jsonld = Emitter.emit_stream_chunk(chunk)
    assert jsonld["@type"] == "StreamChunk"
    assert jsonld["chunkType"] == "content"
    assert jsonld["chunkText"] == "Hello"
  end

  test "various content part types" do
    parts = [
      %{type: :TextPart, text: "Plain text"},
      %{type: :ImageURLPart, url: "https://example.com/image.png"},
      %{type: :ThinkingPart, thinking: "Let me think..."},
      %{type: :ToolResultPart, tool_call_id: "call_123", result_json: "{\"result\":\"ok\"}"}
    ]

    jsonld_parts = Enum.map(parts, &Emitter.emit_part/1)
    assert length(jsonld_parts) == 4
    assert Enum.at(jsonld_parts, 0)["@type"] == "TextPart"
    assert Enum.at(jsonld_parts, 1)["@type"] == "ImageURLPart"
    assert Enum.at(jsonld_parts, 2)["@type"] == "ThinkingPart"
    assert Enum.at(jsonld_parts, 3)["@type"] == "ToolResultPart"

    parsed_parts = Enum.map(jsonld_parts, &Parser.parse_part/1)
    assert Enum.at(parsed_parts, 0).type == :TextPart
    assert Enum.at(parsed_parts, 1).type == :ImageURLPart
  end
end

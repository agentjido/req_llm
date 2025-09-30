defmodule ReqLLM.Providers.Bedrock.AnthropicTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Providers.Bedrock.Anthropic}

  describe "format_request/3" do
    test "formats basic request with messages" do
      context =
        Context.new()
        |> Context.add_message(:user, "Hello")

      formatted =
        Anthropic.format_request(
          "anthropic.claude-3-haiku-20240307-v1:0",
          context,
          []
        )

      assert formatted["anthropic_version"] == "bedrock-2023-05-31"
      assert formatted["max_tokens"] == 1024

      assert formatted["messages"] == [
               %{"role" => "user", "content" => [%{"type" => "text", "text" => "Hello"}]}
             ]
    end

    test "includes system message when present" do
      context =
        Context.new()
        |> Context.add_message(:system, "You are a helpful assistant")
        |> Context.add_message(:user, "Hello")

      formatted =
        Anthropic.format_request(
          "anthropic.claude-3-haiku-20240307-v1:0",
          context,
          []
        )

      assert formatted["system"] == "You are a helpful assistant"
      assert length(formatted["messages"]) == 1
    end

    test "includes optional parameters when provided" do
      context =
        Context.new()
        |> Context.add_message(:user, "Hello")

      formatted =
        Anthropic.format_request(
          "anthropic.claude-3-haiku-20240307-v1:0",
          context,
          max_tokens: 2048,
          temperature: 0.7,
          top_p: 0.9,
          top_k: 40,
          stop_sequences: ["\\n\\n", "END"]
        )

      assert formatted["max_tokens"] == 2048
      assert formatted["temperature"] == 0.7
      assert formatted["top_p"] == 0.9
      assert formatted["top_k"] == 40
      assert formatted["stop_sequences"] == ["\\n\\n", "END"]
    end

    test "excludes nil parameters" do
      context =
        Context.new()
        |> Context.add_message(:user, "Hello")

      formatted =
        Anthropic.format_request(
          "anthropic.claude-3-haiku-20240307-v1:0",
          context,
          max_tokens: 1000,
          temperature: nil,
          top_p: nil
        )

      assert formatted["max_tokens"] == 1000
      refute Map.has_key?(formatted, "temperature")
      refute Map.has_key?(formatted, "top_p")
    end
  end

  describe "parse_stream_chunk/2" do
    test "parses text delta chunk" do
      # Bedrock wraps Anthropic events in a chunk with base64-encoded bytes
      inner_event = %{
        "type" => "content_block_delta",
        "delta" => %{
          "type" => "text_delta",
          "text" => "Hello"
        }
      }

      chunk = %{
        "chunk" => %{
          "bytes" => Base.encode64(Jason.encode!(inner_event))
        }
      }

      assert {:ok, stream_chunk} = Anthropic.parse_stream_chunk(chunk, [])
      assert stream_chunk.type == :text
      assert stream_chunk.data == "Hello"
    end

    test "parses message start chunk" do
      inner_event = %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_123",
          "model" => "claude-3-haiku",
          "role" => "assistant"
        }
      }

      chunk = %{
        "chunk" => %{
          "bytes" => Base.encode64(Jason.encode!(inner_event))
        }
      }

      assert {:ok, stream_chunk} = Anthropic.parse_stream_chunk(chunk, [])
      assert stream_chunk.type == :start
      assert stream_chunk.data[:id] == "msg_123"
      assert stream_chunk.data[:model] == "claude-3-haiku"
    end

    test "parses message stop chunk" do
      inner_event = %{
        "type" => "message_stop"
      }

      chunk = %{
        "chunk" => %{
          "bytes" => Base.encode64(Jason.encode!(inner_event))
        }
      }

      assert {:ok, stream_chunk} = Anthropic.parse_stream_chunk(chunk, [])
      assert stream_chunk.type == :end
    end

    test "parses message delta with usage" do
      inner_event = %{
        "type" => "message_delta",
        "delta" => %{
          "stop_reason" => "end_turn"
        },
        "usage" => %{
          "output_tokens" => 42
        }
      }

      chunk = %{
        "chunk" => %{
          "bytes" => Base.encode64(Jason.encode!(inner_event))
        }
      }

      assert {:ok, stream_chunk} = Anthropic.parse_stream_chunk(chunk, [])
      assert stream_chunk.type == :metadata
      assert stream_chunk.data[:finish_reason] == "end_turn"
      assert stream_chunk.data[:usage]["output_tokens"] == 42
    end

    test "parses content block start" do
      inner_event = %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{
          "type" => "text",
          "text" => ""
        }
      }

      chunk = %{
        "chunk" => %{
          "bytes" => Base.encode64(Jason.encode!(inner_event))
        }
      }

      assert {:ok, stream_chunk} = Anthropic.parse_stream_chunk(chunk, [])
      assert stream_chunk.type == :content_block_start
    end

    test "parses content block stop" do
      inner_event = %{
        "type" => "content_block_stop",
        "index" => 0
      }

      chunk = %{
        "chunk" => %{
          "bytes" => Base.encode64(Jason.encode!(inner_event))
        }
      }

      assert {:ok, stream_chunk} = Anthropic.parse_stream_chunk(chunk, [])
      assert stream_chunk.type == :content_block_stop
    end

    test "parses tool use delta" do
      inner_event = %{
        "type" => "content_block_delta",
        "delta" => %{
          "type" => "input_json_delta",
          "partial_json" => "{\"location\":"
        }
      }

      chunk = %{
        "chunk" => %{
          "bytes" => Base.encode64(Jason.encode!(inner_event))
        }
      }

      assert {:ok, stream_chunk} = Anthropic.parse_stream_chunk(chunk, [])
      assert stream_chunk.type == :tool_call_delta
      assert stream_chunk.data[:partial] == "{\"location\":"
    end

    test "handles malformed chunk" do
      chunk = %{"invalid" => "format"}

      assert {:error, reason} = Anthropic.parse_stream_chunk(chunk, [])
      assert reason =~ "Failed to parse stream chunk"
    end

    test "handles missing bytes field" do
      chunk = %{"chunk" => %{}}

      assert {:error, reason} = Anthropic.parse_stream_chunk(chunk, [])
      assert reason =~ "Failed to parse stream chunk"
    end

    test "handles invalid base64" do
      chunk = %{"chunk" => %{"bytes" => "not-valid-base64!!!"}}

      assert {:error, reason} = Anthropic.parse_stream_chunk(chunk, [])
      assert reason =~ "Failed to parse stream chunk"
    end
  end

  describe "convert_message/1" do
    test "converts user message" do
      message = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Hello"}]
      }

      converted = Anthropic.convert_message(message)

      assert converted["role"] == "user"
      assert converted["content"] == [%{"type" => "text", "text" => "Hello"}]
    end

    test "converts assistant message" do
      message = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Hi there"}]
      }

      converted = Anthropic.convert_message(message)

      assert converted["role"] == "assistant"
      assert converted["content"] == [%{"type" => "text", "text" => "Hi there"}]
    end

    test "handles multiple content parts" do
      message = %ReqLLM.Message{
        role: :user,
        content: [
          %ReqLLM.Message.ContentPart{type: :text, text: "First"},
          %ReqLLM.Message.ContentPart{type: :text, text: "Second"}
        ]
      }

      converted = Anthropic.convert_message(message)

      assert length(converted["content"]) == 2
      assert Enum.at(converted["content"], 0)["text"] == "First"
      assert Enum.at(converted["content"], 1)["text"] == "Second"
    end
  end
end

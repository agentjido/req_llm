defmodule ReqLLM.Providers.AmazonBedrock.AnthropicTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Providers.AmazonBedrock.Anthropic}

  describe "format_request/3" do
    test "formats basic request with messages" do
      context = Context.new([Context.user("Hello")])

      formatted =
        Anthropic.format_request(
          "anthropic.claude-3-haiku-20240307-v1:0",
          context,
          []
        )

      assert formatted[:anthropic_version] == "bedrock-2023-05-31"
      assert formatted[:max_tokens] == 1024

      assert [%{role: "user", content: _}] = formatted[:messages]
    end

    test "includes system message when present" do
      context =
        Context.new([
          Context.system("You are a helpful assistant"),
          Context.user("Hello")
        ])

      formatted =
        Anthropic.format_request(
          "anthropic.claude-3-haiku-20240307-v1:0",
          context,
          []
        )

      assert formatted[:system] == "You are a helpful assistant"
      assert length(formatted[:messages]) == 1
    end

    test "includes optional parameters when provided" do
      context = Context.new([Context.user("Hello")])

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

      assert formatted[:max_tokens] == 2048
      assert formatted[:temperature] == 0.7
      assert formatted[:top_p] == 0.9
      assert formatted[:top_k] == 40
      assert formatted[:stop_sequences] == ["\\n\\n", "END"]
    end

    test "excludes nil parameters" do
      context = Context.new([Context.user("Hello")])

      formatted =
        Anthropic.format_request(
          "anthropic.claude-3-haiku-20240307-v1:0",
          context,
          max_tokens: 1000,
          temperature: nil,
          top_p: nil
        )

      assert formatted[:max_tokens] == 1000
      refute Map.has_key?(formatted, :temperature)
      refute Map.has_key?(formatted, :top_p)
    end

    test "excludes model field (Bedrock specifies it in URL)" do
      context = Context.new([Context.user("Hello")])

      formatted =
        Anthropic.format_request(
          "us.anthropic.claude-3-5-haiku-20241022-v1:0",
          context,
          []
        )

      # Bedrock doesn't accept model in body - it's in the URL path
      refute Map.has_key?(formatted, :model)
      # But should have all the Anthropic format
      assert formatted[:messages]
      assert formatted[:anthropic_version] == "bedrock-2023-05-31"
    end

    test "includes tools when provided" do
      # Create a test tool using NimbleOptions schema format
      get_weather =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get the current weather for a location",
          parameter_schema: [
            location: [type: :string, required: true, doc: "City name"]
          ],
          callback: fn _args -> {:ok, "sunny"} end
        )

      context = Context.new([Context.user("What's the weather?")])
      # Properly set tools on context
      context = Map.put(context, :tools, [get_weather])

      formatted =
        Anthropic.format_request(
          "anthropic.claude-3-haiku-20240307-v1:0",
          context,
          []
        )

      assert is_list(formatted[:tools])
      assert length(formatted[:tools]) == 1

      tool = List.first(formatted[:tools])
      assert tool[:name] == "get_weather"
      assert tool[:description] == "Get the current weather for a location"
      assert is_map(tool[:input_schema])
      assert tool[:input_schema]["type"] == "object"
    end

    test "merges consecutive tool results into single user message" do
      context =
        Context.new([
          Context.system("You are helpful."),
          Context.user("What's the weather in Paris and London?"),
          Context.assistant("",
            tool_calls: [
              %ReqLLM.ToolCall{
                id: "tool_1",
                type: "function",
                function: %{name: "get_weather", arguments: ~s({"location":"Paris"})}
              },
              %ReqLLM.ToolCall{
                id: "tool_2",
                type: "function",
                function: %{name: "get_weather", arguments: ~s({"location":"London"})}
              }
            ]
          ),
          Context.tool_result("tool_1", "22°C and sunny"),
          Context.tool_result("tool_2", "18°C and cloudy")
        ])

      formatted =
        Anthropic.format_request(
          "anthropic.claude-3-haiku-20240307-v1:0",
          context,
          []
        )

      messages = formatted[:messages]

      user_messages = Enum.filter(messages, &(&1[:role] == "user"))
      assert length(user_messages) == 2

      tool_result_msg = List.last(user_messages)
      assert is_list(tool_result_msg[:content])
      assert length(tool_result_msg[:content]) == 2

      [result1, result2] = tool_result_msg[:content]
      assert result1[:type] == "tool_result"
      assert result1[:tool_use_id] == "tool_1"
      assert result2[:type] == "tool_result"
      assert result2[:tool_use_id] == "tool_2"
    end
  end

  describe "parse_response/2" do
    test "parses basic Anthropic response" do
      response_body = %{
        "id" => "msg_abc123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-haiku-20240307",
        "content" => [
          %{"type" => "text", "text" => "Hello! How can I help you?"}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 25
        }
      }

      assert {:ok, parsed} = Anthropic.parse_response(response_body, [])
      assert %ReqLLM.Response{} = parsed
      assert parsed.id == "msg_abc123"
      assert parsed.model == "claude-3-haiku-20240307"
      assert parsed.finish_reason == :stop
      assert parsed.usage.input_tokens == 10
      assert parsed.usage.output_tokens == 25
    end

    test "parses response with tool calls" do
      response_body = %{
        "id" => "msg_tool123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-haiku",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "call_xyz",
            "name" => "get_weather",
            "input" => %{"location" => "San Francisco"}
          }
        ],
        "stop_reason" => "tool_use",
        "usage" => %{
          "input_tokens" => 15,
          "output_tokens" => 30
        }
      }

      assert {:ok, parsed} = Anthropic.parse_response(response_body, [])
      assert parsed.finish_reason == :tool_calls

      # Verify tool call is properly decoded
      assert [%ReqLLM.ToolCall{} = tool_call] = ReqLLM.Response.tool_calls(parsed)
      assert tool_call.function.name == "get_weather"
      assert tool_call.function.arguments == ~s({"location":"San Francisco"})
      assert tool_call.id == "call_xyz"
    end
  end

  describe "parse_stream_chunk/2" do
    test "parses text delta chunk" do
      # Bedrock wraps Anthropic events in a chunk with base64-encoded bytes
      inner_event = %{
        "type" => "content_block_delta",
        "index" => 0,
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
      assert stream_chunk.type == :content
      assert stream_chunk.text == "Hello"
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

      # message_start events are not currently processed by Anthropic.Response
      # They're informational and not needed for assembling the response
      assert {:ok, nil} = Anthropic.parse_stream_chunk(chunk, [])
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
      assert stream_chunk.type == :meta
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
      assert stream_chunk.type == :meta
      # When usage is present, the usage chunk is returned first
      # The finish_reason chunk comes after but we only return the first
      assert stream_chunk.metadata[:usage]["output_tokens"] == 42
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
      # content_block_start with text creates a content chunk
      assert stream_chunk.type == :content
      assert stream_chunk.text == ""
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

      # content_block_stop events don't produce chunks in the new implementation
      assert {:ok, nil} = Anthropic.parse_stream_chunk(chunk, [])
    end

    test "parses tool use delta" do
      inner_event = %{
        "type" => "content_block_delta",
        "index" => 0,
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
      assert stream_chunk.type == :meta
      # Tool args are in metadata
      assert stream_chunk.metadata[:tool_call_args][:fragment] == "{\"location\":"
    end

    test "handles malformed chunk" do
      chunk = %{"invalid" => "format"}

      assert {:error, reason} = Anthropic.parse_stream_chunk(chunk, [])
      # Error is now a tuple from unwrap_stream_chunk
      assert reason == :unknown_chunk_format
    end

    test "handles missing bytes field" do
      chunk = %{"chunk" => %{}}

      assert {:error, reason} = Anthropic.parse_stream_chunk(chunk, [])
      # Error is now a tuple from unwrap_stream_chunk
      assert reason == :unknown_chunk_format
    end

    test "handles invalid base64" do
      chunk = %{"chunk" => %{"bytes" => "not-valid-base64!!!"}}

      assert {:error, {:unwrap_failed, _}} = Anthropic.parse_stream_chunk(chunk, [])
    end
  end

  describe "structured output (:object operation)" do
    test "format_request creates structured_output tool for :object operation" do
      schema = [
        name: [type: :string, required: true, doc: "Person's full name"],
        age: [type: :pos_integer, required: true, doc: "Person's age in years"],
        occupation: [type: :string, doc: "Person's job or profession"]
      ]

      {:ok, compiled_schema} = ReqLLM.Schema.compile(schema)

      context = Context.new([Context.user("Generate a software engineer profile")])

      formatted =
        Anthropic.format_request(
          "anthropic.claude-3-5-sonnet-20240620-v2:0",
          context,
          operation: :object,
          compiled_schema: compiled_schema,
          max_tokens: 500
        )

      # Should include tools array with structured_output tool
      assert is_list(formatted[:tools])
      assert length(formatted[:tools]) == 1

      tool = List.first(formatted[:tools])
      assert tool[:name] == "structured_output"
      assert tool[:description] == "Generate structured output matching the provided schema"

      # Should have input_schema with the user's schema
      assert is_map(tool[:input_schema])
      assert tool[:input_schema]["type"] == "object"
      assert tool[:input_schema]["properties"]["name"]["type"] == "string"
      assert tool[:input_schema]["properties"]["age"]["type"] == "integer"
      assert tool[:input_schema]["properties"]["age"]["minimum"] == 1
      assert tool[:input_schema]["required"] == ["name", "age"]

      # Should force tool choice
      # Note: tool_choice is added to opts but not directly to the body in our implementation
      # It's passed through opts and will be in the request when encode_request is called
    end

    test "parse_response extracts object from tool call for :object operation" do
      response_body = %{
        "id" => "msg_obj123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-5-sonnet-20240620",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_abc",
            "name" => "structured_output",
            "input" => %{
              "name" => "Jane Doe",
              "age" => 32,
              "occupation" => "Software Engineer"
            }
          }
        ],
        "stop_reason" => "tool_use",
        "usage" => %{
          "input_tokens" => 451,
          "output_tokens" => 69
        }
      }

      assert {:ok, parsed} =
               Anthropic.parse_response(response_body, operation: :object)

      assert %ReqLLM.Response{} = parsed
      assert parsed.id == "msg_obj123"
      assert parsed.model == "claude-3-5-sonnet-20240620"
      assert parsed.finish_reason == :tool_calls

      # For :object operation, should extract and set the object field
      assert parsed.object == %{
               "name" => "Jane Doe",
               "age" => 32,
               "occupation" => "Software Engineer"
             }
    end

    test "parse_response returns response without object extraction for :chat operation" do
      response_body = %{
        "id" => "msg_chat123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-haiku",
        "content" => [
          %{"type" => "text", "text" => "Hello!"}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 5
        }
      }

      assert {:ok, parsed} =
               Anthropic.parse_response(response_body, operation: :chat)

      assert %ReqLLM.Response{} = parsed
      assert parsed.finish_reason == :stop
      # Should not have object field for :chat operation
      assert is_nil(parsed.object)
    end
  end
end

defmodule ReqLLM.Providers.AmazonBedrock.OpenAITest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Providers.AmazonBedrock.OpenAI}

  describe "format_request/3" do
    test "formats basic request with messages" do
      context = Context.new([Context.user("Hello")])

      formatted =
        OpenAI.format_request(
          "openai.gpt-oss-20b-1:0",
          context,
          []
        )

      # Should have standard OpenAI format
      assert formatted["messages"]
      assert is_list(formatted["messages"])

      # Should include model field (unlike Anthropic which rejects it)
      assert formatted["model"] == "openai.gpt-oss-20b-1:0"
    end

    test "includes system message when present" do
      context =
        Context.new([
          Context.system("You are a helpful assistant"),
          Context.user("Hello")
        ])

      formatted =
        OpenAI.format_request(
          "openai.gpt-oss-120b-1:0",
          context,
          []
        )

      messages = formatted["messages"]
      assert length(messages) == 2
      assert List.first(messages)["role"] == "system"
      assert List.first(messages)["content"] == "You are a helpful assistant"
    end

    test "includes optional parameters when provided" do
      context = Context.new([Context.user("Hello")])

      formatted =
        OpenAI.format_request(
          "openai.gpt-oss-20b-1:0",
          context,
          max_tokens: 2048,
          temperature: 0.7,
          top_p: 0.9
        )

      assert formatted["max_tokens"] == 2048
      assert formatted["temperature"] == 0.7
      assert formatted["top_p"] == 0.9
    end

    test "includes tools when provided" do
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
      context = Map.put(context, :tools, [get_weather])

      formatted =
        OpenAI.format_request(
          "openai.gpt-oss-120b-1:0",
          context,
          []
        )

      assert is_list(formatted["tools"])
      assert length(formatted["tools"]) == 1

      tool = List.first(formatted["tools"])
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "get_weather"
    end
  end

  describe "parse_response/2" do
    test "parses basic OpenAI response" do
      response_body = %{
        "id" => "chatcmpl-123",
        "object" => "chat.completion",
        "created" => 1_677_652_288,
        "model" => "openai.gpt-oss-20b-1:0",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => "Hello! How can I help you?"
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 25,
          "total_tokens" => 35
        }
      }

      assert {:ok, parsed} = OpenAI.parse_response(response_body, [])
      assert %ReqLLM.Response{} = parsed
      assert parsed.id == "chatcmpl-123"
      assert parsed.model == "openai.gpt-oss-20b-1:0"
      assert parsed.finish_reason == :stop
      assert parsed.usage.input_tokens == 10
      assert parsed.usage.output_tokens == 25
    end

    test "parses response with tool calls" do
      response_body = %{
        "id" => "chatcmpl-tool123",
        "object" => "chat.completion",
        "created" => 1_677_652_288,
        "model" => "openai.gpt-oss-120b-1:0",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_xyz",
                  "type" => "function",
                  "function" => %{
                    "name" => "get_weather",
                    "arguments" => ~s({"location":"Paris"})
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 15,
          "completion_tokens" => 30,
          "total_tokens" => 45
        }
      }

      assert {:ok, parsed} = OpenAI.parse_response(response_body, [])
      assert parsed.finish_reason == :tool_calls

      assert [%ReqLLM.ToolCall{} = tool_call] = ReqLLM.Response.tool_calls(parsed)
      assert tool_call.function.name == "get_weather"
      assert tool_call.function.arguments == ~s({"location":"Paris"})
      assert tool_call.id == "call_xyz"
    end
  end

  describe "parse_stream_chunk/2" do
    test "parses text delta chunk" do
      inner_event = %{
        "id" => "chatcmpl-123",
        "object" => "chat.completion.chunk",
        "created" => 1_677_652_288,
        "model" => "openai.gpt-oss-20b-1:0",
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "content" => "Hello"
            },
            "finish_reason" => nil
          }
        ]
      }

      chunk = %{
        "chunk" => %{
          "bytes" => Base.encode64(Jason.encode!(inner_event))
        }
      }

      assert {:ok, stream_chunk} =
               OpenAI.parse_stream_chunk(chunk, id: "openai.gpt-oss-20b-1:0")

      assert stream_chunk.type == :content
      assert stream_chunk.text == "Hello"
    end

    test "parses finish chunk" do
      inner_event = %{
        "id" => "chatcmpl-123",
        "object" => "chat.completion.chunk",
        "created" => 1_677_652_288,
        "model" => "openai.gpt-oss-20b-1:0",
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{},
            "finish_reason" => "stop"
          }
        ]
      }

      chunk = %{
        "chunk" => %{
          "bytes" => Base.encode64(Jason.encode!(inner_event))
        }
      }

      assert {:ok, stream_chunk} =
               OpenAI.parse_stream_chunk(chunk, id: "openai.gpt-oss-20b-1:0")

      assert stream_chunk.type == :meta
      assert stream_chunk.metadata[:finish_reason] == :stop
    end

    test "handles malformed chunk" do
      chunk = %{"invalid" => "format"}

      assert {:error, reason} = OpenAI.parse_stream_chunk(chunk, [])
      assert reason == :unknown_chunk_format
    end

    test "handles invalid base64" do
      chunk = %{"chunk" => %{"bytes" => "not-valid-base64!!!"}}

      assert {:error, {:unwrap_failed, _}} = OpenAI.parse_stream_chunk(chunk, [])
    end
  end

  describe "extract_usage/2" do
    test "extracts usage from response" do
      body = %{
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 20,
          "total_tokens" => 30
        }
      }

      assert {:ok, usage} = OpenAI.extract_usage(body, nil)
      assert usage.input_tokens == 10
      assert usage.output_tokens == 20
      assert usage.total_tokens == 30
    end

    test "returns error when no usage" do
      body = %{"id" => "test"}

      assert {:error, :no_usage} = OpenAI.extract_usage(body, nil)
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
        OpenAI.format_request(
          "openai.gpt-oss-120b-1:0",
          context,
          operation: :object,
          compiled_schema: compiled_schema,
          max_tokens: 500
        )

      # Should include tools array with structured_output tool
      assert is_list(formatted["tools"])
      assert length(formatted["tools"]) == 1

      tool = List.first(formatted["tools"])
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "structured_output"

      assert tool["function"]["description"] ==
               "Generate structured output matching the provided schema"

      # Should have parameters with the user's schema
      assert is_map(tool["function"]["parameters"])
      assert tool["function"]["parameters"]["type"] == "object"
      assert tool["function"]["parameters"]["properties"]["name"]["type"] == "string"
      assert tool["function"]["parameters"]["properties"]["age"]["type"] == "integer"
      assert tool["function"]["parameters"]["properties"]["age"]["minimum"] == 1
      assert tool["function"]["parameters"]["required"] == ["name", "age"]

      # Should force tool choice
      assert formatted["tool_choice"]["type"] == "function"
      assert formatted["tool_choice"]["function"]["name"] == "structured_output"
    end

    test "parse_response extracts object from tool call for :object operation" do
      response_body = %{
        "id" => "chatcmpl-abc",
        "model" => "openai.gpt-oss-120b-1:0",
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_xyz",
                  "type" => "function",
                  "function" => %{
                    "name" => "structured_output",
                    "arguments" =>
                      Jason.encode!(%{
                        "name" => "Bob Smith",
                        "age" => 35,
                        "occupation" => "DevOps Engineer"
                      })
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 451,
          "completion_tokens" => 69
        }
      }

      assert {:ok, parsed} =
               OpenAI.parse_response(response_body, operation: :object)

      assert %ReqLLM.Response{} = parsed
      assert parsed.id == "chatcmpl-abc"
      assert parsed.model == "openai.gpt-oss-120b-1:0"
      assert parsed.finish_reason == :tool_calls

      # For :object operation, should extract and set the object field
      assert parsed.object == %{
               "name" => "Bob Smith",
               "age" => 35,
               "occupation" => "DevOps Engineer"
             }
    end

    test "parse_response returns response without object extraction for :chat operation" do
      response_body = %{
        "id" => "chatcmpl-xyz",
        "model" => "openai.gpt-oss-120b-1:0",
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => "Hello there!"
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 5
        }
      }

      assert {:ok, parsed} =
               OpenAI.parse_response(response_body, operation: :chat)

      assert %ReqLLM.Response{} = parsed
      assert parsed.finish_reason == :stop
      # Should not have object field for :chat operation
      assert is_nil(parsed.object)
    end
  end
end

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
        "created" => 1677_652_288,
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
        "created" => 1677_652_288,
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

      tool_calls = ReqLLM.Response.tool_calls(parsed)
      assert length(tool_calls) == 1

      [tool_call] = tool_calls
      assert tool_call.function.name == "get_weather"
      arguments = Jason.decode!(tool_call.function.arguments)
      assert arguments["location"] == "Paris"
    end
  end

  describe "parse_stream_chunk/2" do
    test "parses text delta chunk" do
      inner_event = %{
        "id" => "chatcmpl-123",
        "object" => "chat.completion.chunk",
        "created" => 1677_652_288,
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
               OpenAI.parse_stream_chunk(chunk, model: "openai.gpt-oss-20b-1:0")

      assert stream_chunk.type == :content
      assert stream_chunk.text == "Hello"
    end

    test "parses finish chunk" do
      inner_event = %{
        "id" => "chatcmpl-123",
        "object" => "chat.completion.chunk",
        "created" => 1677_652_288,
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
               OpenAI.parse_stream_chunk(chunk, model: "openai.gpt-oss-20b-1:0")

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
end

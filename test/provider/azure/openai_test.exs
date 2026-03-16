defmodule ReqLLM.Providers.Azure.OpenAITest do
  @moduledoc """
  Unit tests for Azure.OpenAI formatter module.

  Tests OpenAI model formatting for Azure AI Services:
  - Request formatting (no model field, chat completions format)
  - Token limit handling (max_tokens vs max_completion_tokens)
  - Reasoning model support (o1, o3, o4)
  - Tool calling with strict mode
  - Embedding request formatting
  - Usage extraction

  This module tests the adapter layer that translates between
  Azure's deployment-based API and OpenAI's model format.
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Azure

  describe "format_request/3" do
    test "does not include model field in body" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      refute Map.has_key?(body, :model)
      assert Map.has_key?(body, :messages)
    end

    test "includes messages in correct format" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello world")])
      opts = [stream: false]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert [%{role: "user", content: "Hello world"}] = body[:messages]
    end

    test "includes stream_options when streaming" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: true]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:stream] == true
      assert body[:stream_options] == %{include_usage: true}
    end

    test "includes temperature and other options" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false, temperature: 0.7, max_tokens: 100]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:temperature] == 0.7
      assert body[:max_tokens] == 100
    end

    test "includes tools when provided" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("What's the weather?")])

      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather info",
          parameter_schema: [location: [type: :string, required: true]],
          callback: fn _ -> {:ok, %{}} end
        )

      opts = [stream: false, tools: [tool]]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert length(body[:tools]) == 1
      assert hd(body[:tools])["function"]["name"] == "get_weather"
    end

    test "uses max_completion_tokens for reasoning models" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Think about this")])
      opts = [stream: false, max_tokens: 1000]

      body = Azure.OpenAI.format_request("o1-preview", context, opts)

      assert body[:max_completion_tokens] == 1000
      refute Map.has_key?(body, "max_tokens")
      refute Map.has_key?(body, :max_tokens)
    end

    test "uses max_tokens for standard models" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false, max_tokens: 500]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:max_tokens] == 500
      refute Map.has_key?(body, :max_completion_tokens)
    end

    test "translates tool_choice from ReqLLM format to OpenAI format" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("What's the weather?")])

      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather info",
          parameter_schema: [location: [type: :string, required: true]],
          callback: fn _ -> {:ok, %{}} end
        )

      opts = [
        stream: false,
        tools: [tool],
        tool_choice: %{type: "tool", name: "get_weather"}
      ]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:tool_choice] == %{
               type: "function",
               function: %{name: "get_weather"}
             }
    end

    test "includes tool_choice auto" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "Test tool",
          parameter_schema: [x: [type: :string]],
          callback: fn _ -> {:ok, %{}} end
        )

      opts = [stream: false, tools: [tool], tool_choice: :auto]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:tool_choice] == :auto
    end

    test "includes tool_choice none" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "Test tool",
          parameter_schema: [x: [type: :string]],
          callback: fn _ -> {:ok, %{}} end
        )

      opts = [stream: false, tools: [tool], tool_choice: :none]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:tool_choice] == :none
    end

    test "includes tool_choice required" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "Test tool",
          parameter_schema: [x: [type: :string]],
          callback: fn _ -> {:ok, %{}} end
        )

      opts = [stream: false, tools: [tool], tool_choice: :required]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:tool_choice] == :required
    end

    test "includes service_tier when specified" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false, provider_options: [service_tier: "priority"]]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:service_tier] == "priority"
    end

    test "includes reasoning_effort for reasoning models" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Complex problem")])
      opts = [stream: false, provider_options: [reasoning_effort: "high"]]

      body = Azure.OpenAI.format_request("o1-preview", context, opts)

      assert body[:reasoning_effort] == "high"
    end
  end

  describe "format_embedding_request/3" do
    test "includes input text" do
      opts = []

      body = Azure.OpenAI.format_embedding_request("text-embedding-3-small", "Hello world", opts)

      assert body.input == "Hello world"
    end

    test "includes dimensions when specified" do
      opts = [provider_options: [dimensions: 256]]

      body = Azure.OpenAI.format_embedding_request("text-embedding-3-small", "Hello", opts)

      assert body.dimensions == 256
    end
  end

  describe "extract_usage/2" do
    test "extracts token counts from response" do
      body = %{
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 20,
          "total_tokens" => 30
        }
      }

      {:ok, usage} = Azure.OpenAI.extract_usage(body, nil)

      assert usage.input_tokens == 10
      assert usage.output_tokens == 20
      assert usage.total_tokens == 30
      assert usage.cached_tokens == 0
      assert usage.reasoning_tokens == 0
    end

    test "extracts cached and reasoning tokens when present" do
      body = %{
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 200,
          "total_tokens" => 300,
          "prompt_tokens_details" => %{
            "cached_tokens" => 50
          },
          "completion_tokens_details" => %{
            "reasoning_tokens" => 75
          }
        }
      }

      {:ok, usage} = Azure.OpenAI.extract_usage(body, nil)

      assert usage.input_tokens == 100
      assert usage.output_tokens == 200
      assert usage.total_tokens == 300
      assert usage.cached_tokens == 50
      assert usage.reasoning_tokens == 75
    end

    test "infers reasoning tokens from reasoning_content in choices" do
      body = %{
        "usage" => %{
          "prompt_tokens" => 8,
          "completion_tokens" => 10,
          "total_tokens" => 18
        },
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "content" => "The answer is 84.",
              "reasoning_content" => "Let me think about 12 * 7...",
              "role" => "assistant"
            }
          }
        ]
      }

      {:ok, usage} = Azure.OpenAI.extract_usage(body, nil)

      reasoning_text = "Let me think about 12 * 7..."
      answer_text = "The answer is 84."

      expected =
        round(
          10 * String.length(reasoning_text) /
            (String.length(reasoning_text) + String.length(answer_text))
        )

      assert usage.reasoning_tokens == expected
    end

    test "prefers completion_tokens_details over reasoning_content inference" do
      body = %{
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 200,
          "total_tokens" => 300,
          "completion_tokens_details" => %{
            "reasoning_tokens" => 75
          }
        },
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "content" => "Answer",
              "reasoning_content" => "Some reasoning",
              "role" => "assistant"
            }
          }
        ]
      }

      {:ok, usage} = Azure.OpenAI.extract_usage(body, nil)

      assert usage.reasoning_tokens == 75
    end

    test "does not infer reasoning tokens when no reasoning_content" do
      body = %{
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 20,
          "total_tokens" => 30
        },
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "content" => "Hello!",
              "role" => "assistant"
            }
          }
        ]
      }

      {:ok, usage} = Azure.OpenAI.extract_usage(body, nil)

      assert usage.reasoning_tokens == 0
    end

    test "returns error when no usage data" do
      body = %{"choices" => []}

      assert {:error, :no_usage} = Azure.OpenAI.extract_usage(body, nil)
    end
  end

  describe "parse_response/3 tool calls" do
    test "parses OpenAI function call response" do
      body = %{
        "id" => "chatcmpl-123",
        "object" => "chat.completion",
        "model" => "gpt-4o",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_abc123",
                  "type" => "function",
                  "function" => %{
                    "name" => "get_weather",
                    "arguments" => ~s({"location":"San Francisco"})
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 20,
          "completion_tokens" => 15,
          "total_tokens" => 35
        }
      }

      model = %LLMDB.Model{id: "gpt-4o", provider: :azure}
      opts = [operation: :chat]

      {:ok, response} = Azure.OpenAI.parse_response(body, model, opts)

      assert response.finish_reason == :tool_calls
      tool_calls = ReqLLM.Response.tool_calls(response)
      assert length(tool_calls) == 1
      assert hd(tool_calls).function.name == "get_weather"
    end

    test "parses multiple tool calls in OpenAI response" do
      body = %{
        "id" => "chatcmpl-456",
        "object" => "chat.completion",
        "model" => "gpt-4o",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{
                    "name" => "get_weather",
                    "arguments" => ~s({"location":"NYC"})
                  }
                },
                %{
                  "id" => "call_2",
                  "type" => "function",
                  "function" => %{
                    "name" => "get_time",
                    "arguments" => ~s({"timezone":"EST"})
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 30,
          "completion_tokens" => 25,
          "total_tokens" => 55
        }
      }

      model = %LLMDB.Model{id: "gpt-4o", provider: :azure}
      opts = [operation: :chat]

      {:ok, response} = Azure.OpenAI.parse_response(body, model, opts)

      assert response.finish_reason == :tool_calls
      tool_calls = ReqLLM.Response.tool_calls(response)
      assert length(tool_calls) == 2

      names = Enum.map(tool_calls, & &1.function.name)
      assert "get_weather" in names
      assert "get_time" in names
    end
  end

  describe "additional options" do
    test "includes n parameter for multiple completions" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false, n: 3]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:n] == 3
    end

    test "includes encoding_format for embeddings" do
      opts = [provider_options: [encoding_format: "base64"]]

      body = Azure.OpenAI.format_embedding_request("text-embedding-3-small", "Hello", opts)

      assert body.encoding_format == "base64"
    end

    test "includes parallel_tool_calls from top-level option" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather info",
          parameter_schema: [location: [type: :string, required: true]],
          callback: fn _ -> {:ok, %{}} end
        )

      opts = [stream: false, tools: [tool], parallel_tool_calls: true]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:parallel_tool_calls] == true
    end

    test "includes parallel_tool_calls from provider_options" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather info",
          parameter_schema: [location: [type: :string, required: true]],
          callback: fn _ -> {:ok, %{}} end
        )

      opts = [
        stream: false,
        tools: [tool],
        provider_options: [openai_parallel_tool_calls: true]
      ]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:parallel_tool_calls] == true
    end
  end

  describe "response_format handling" do
    test "includes json_object response_format" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false, provider_options: [response_format: %{type: "json_object"}]]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:response_format] == %{type: "json_object"}
    end

    test "includes json_schema response_format with schema" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      opts = [
        stream: false,
        provider_options: [
          response_format: %{
            type: "json_schema",
            json_schema: %{
              name: "person",
              schema: [
                name: [type: :string, required: true],
                age: [type: :pos_integer, required: true]
              ]
            }
          }
        ]
      ]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:response_format][:type] == "json_schema"
      assert body[:response_format][:json_schema][:name] == "person"
      assert is_map(body[:response_format][:json_schema][:schema])
    end

    test "passes through text response_format unchanged" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false, provider_options: [response_format: %{type: "text"}]]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:response_format] == %{type: "text"}
    end
  end
end

defmodule Provider.OpenAI.ResponsesAPIUnitTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.OpenAI.ResponsesAPI

  describe "path/0" do
    test "returns correct endpoint path" do
      assert ResponsesAPI.path() == "/responses"
    end
  end

  describe "encode_body/1" do
    test "encodes basic request with max_output_tokens" do
      request = build_request(max_output_tokens: 1000)

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["max_output_tokens"] == 1000
      assert body["model"] == "gpt-5"
      assert body["stream"] == nil
    end

    test "normalizes max_completion_tokens to max_output_tokens" do
      request = build_request(max_completion_tokens: 2048)

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["max_output_tokens"] == 2048
    end

    test "normalizes max_tokens to max_output_tokens" do
      request = build_request(max_tokens: 512)

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["max_output_tokens"] == 512
    end

    test "prioritizes max_output_tokens over other token limits" do
      request =
        build_request(
          max_output_tokens: 1000,
          max_completion_tokens: 2000,
          max_tokens: 3000
        )

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["max_output_tokens"] == 1000
    end

    test "encodes streaming request" do
      request = build_request(stream: true)

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["stream"] == true
    end

    test "encodes tools when present" do
      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather",
          parameter_schema: [
            location: [type: :string, required: true]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      request = build_request(tools: [tool])

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert [encoded_tool] = body["tools"]
      assert encoded_tool["type"] == "function"
      assert encoded_tool["name"] == "get_weather"
      assert encoded_tool["description"] == "Get weather"
      assert encoded_tool["parameters"]["properties"]["location"]["type"] == "string"
    end

    test "encodes non-strict tools without required field" do
      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather",
          parameter_schema: [
            location: [type: :string, required: true]
          ],
          callback: fn _ -> {:ok, "result"} end,
          strict: false
        )

      request = build_request(tools: [tool])

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert [encoded_tool] = body["tools"]
      assert encoded_tool["strict"] == false
      refute Map.has_key?(encoded_tool["parameters"], "required")
    end

    test "encodes strict tools with required field listing all parameters" do
      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather",
          parameter_schema: [
            location: [type: :string, required: true],
            units: [type: :string]
          ],
          callback: fn _ -> {:ok, "result"} end,
          strict: true
        )

      request = build_request(tools: [tool])

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert [encoded_tool] = body["tools"]
      assert encoded_tool["strict"] == true
      assert Enum.sort(encoded_tool["parameters"]["required"]) == ["location", "units"]
    end

    test "omits tools when empty list" do
      request = build_request(tools: [])

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      refute Map.has_key?(body, "tools")
    end

    test "encodes tool_choice auto" do
      request = build_request(tool_choice: :auto)

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["tool_choice"] == "auto"
    end

    test "encodes tool_choice none" do
      request = build_request(tool_choice: :none)

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["tool_choice"] == "none"
    end

    test "encodes tool_choice required" do
      request = build_request(tool_choice: :required)

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["tool_choice"] == "required"
    end

    test "encodes structured tool outputs from context metadata" do
      tool_call = %ReqLLM.ToolCall{
        id: "call_1",
        type: "function",
        function: %{name: "get_weather", arguments: ~s({"location":"SF"})}
      }

      assistant_msg = %ReqLLM.Message{
        role: :assistant,
        content: [],
        tool_calls: [tool_call]
      }

      tool_result =
        ReqLLM.Context.tool_result_message(
          "get_weather",
          "call_1",
          %ReqLLM.ToolResult{output: %{temp: 72}}
        )

      context = %ReqLLM.Context{messages: [assistant_msg, tool_result]}
      request = build_request(context: context)

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      tool_output =
        Enum.find(body["input"], fn item ->
          item["type"] == "function_call_output"
        end)

      assert tool_output["call_id"] == "call_1"
      assert Jason.decode!(tool_output["output"]) == %{"temp" => 72}
    end

    test "encodes specific tool choice with atom keys" do
      request =
        build_request(tool_choice: %{type: "function", function: %{name: "get_weather"}})

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["tool_choice"] == %{"type" => "function", "name" => "get_weather"}
    end

    test "encodes specific tool choice with string keys" do
      request =
        build_request(tool_choice: %{"type" => "function", "function" => %{"name" => "search"}})

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["tool_choice"] == %{"type" => "function", "name" => "search"}
    end

    test "encodes reasoning effort with atom" do
      request = build_request(reasoning_effort: :medium)

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["reasoning"] == %{"effort" => "medium"}
    end

    test "encodes reasoning effort with string" do
      request = build_request(reasoning_effort: "high")

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["reasoning"] == %{"effort" => "high"}
    end

    test "encodes reasoning effort :none" do
      request = build_request(reasoning_effort: :none)

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["reasoning"] == %{"effort" => "none"}
    end

    test "encodes reasoning effort :minimal" do
      request = build_request(reasoning_effort: :minimal)

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["reasoning"] == %{"effort" => "minimal"}
    end

    test "encodes reasoning effort :xhigh" do
      request = build_request(reasoning_effort: :xhigh)

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["reasoning"] == %{"effort" => "xhigh"}
    end

    test "omits reasoning effort when nil" do
      request = build_request(provider_options: [])

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      refute Map.has_key?(body, "reasoning")
    end

    test "encodes input messages correctly" do
      msg1 = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Hello"}]
      }

      msg2 = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Hi there"}]
      }

      context = %ReqLLM.Context{messages: [msg1, msg2]}
      request = build_request(context: context)

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert [input1, input2] = body["input"]
      assert input1["role"] == "user"
      assert input1["content"] == [%{"type" => "input_text", "text" => "Hello"}]
      assert input2["role"] == "assistant"
      assert input2["content"] == [%{"type" => "output_text", "text" => "Hi there"}]
    end

    test "encodes response_format with keyword list schema (converts to JSON schema)" do
      keyword_schema = [
        name: [type: :string, required: true, doc: "Person name"],
        age: [type: :pos_integer, doc: "Person age"]
      ]

      response_format = %{
        type: "json_schema",
        json_schema: %{
          name: "person_schema",
          strict: true,
          schema: keyword_schema
        }
      }

      request = build_request(provider_options: [response_format: response_format])

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["text"]["format"]["type"] == "json_schema"
      assert body["text"]["format"]["name"] == "person_schema"
      assert body["text"]["format"]["strict"] == true
      assert body["text"]["format"]["schema"]["type"] == "object"
      assert body["text"]["format"]["schema"]["properties"]["name"]["type"] == "string"
      assert body["text"]["format"]["schema"]["properties"]["age"]["type"] == "integer"
      assert body["text"]["format"]["schema"]["properties"]["age"]["minimum"] == 1
      assert body["text"]["format"]["schema"]["required"] == ["name"]
    end

    test "encodes response_format with direct JSON schema (pass-through)" do
      json_schema = %{
        "type" => "object",
        "properties" => %{
          "location" => %{"type" => "string", "description" => "City name"},
          "units" => %{"type" => "string", "enum" => ["celsius", "fahrenheit"]}
        },
        "required" => ["location"],
        "additionalProperties" => false
      }

      response_format = %{
        type: "json_schema",
        json_schema: %{
          name: "weather_schema",
          strict: true,
          schema: json_schema
        }
      }

      request = build_request(provider_options: [response_format: response_format])

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["text"]["format"]["type"] == "json_schema"
      assert body["text"]["format"]["name"] == "weather_schema"
      assert body["text"]["format"]["strict"] == true
      # Schema should pass through unchanged
      assert body["text"]["format"]["schema"] == json_schema
    end

    test "encodes response_format with string keys" do
      json_schema = %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      }

      response_format = %{
        "type" => "json_schema",
        "json_schema" => %{
          "name" => "search_schema",
          "strict" => true,
          "schema" => json_schema
        }
      }

      request = build_request(provider_options: [response_format: response_format])

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["text"]["format"]["type"] == "json_schema"
      assert body["text"]["format"]["name"] == "search_schema"
      assert body["text"]["format"]["strict"] == true
      assert body["text"]["format"]["schema"] == json_schema
    end

    test "encodes verbosity when provided as atom" do
      request = build_request(provider_options: [verbosity: :low])

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["text"]["verbosity"] == "low"
    end

    test "encodes verbosity when provided as string" do
      request = build_request(provider_options: [verbosity: "high"])

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["text"]["verbosity"] == "high"
    end

    test "omits text field when no verbosity or response_format" do
      request = build_request(provider_options: [])

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      refute Map.has_key?(body, "text")
    end

    test "encodes verbosity alongside response_format in text object" do
      json_schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      }

      response_format = %{
        type: "json_schema",
        json_schema: %{
          name: "test_schema",
          strict: true,
          schema: json_schema
        }
      }

      request =
        build_request(provider_options: [response_format: response_format, verbosity: :medium])

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["text"]["format"]["type"] == "json_schema"
      assert body["text"]["format"]["name"] == "test_schema"
      assert body["text"]["verbosity"] == "medium"
    end
  end

  describe "decode_response/1" do
    test "decodes successful response with output_text field" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output_text" => "Hello world",
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 20
        }
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert %ReqLLM.Response{} = resp.body
      assert resp.body.id == "resp_123"
      assert resp.body.model == "gpt-5"
      assert resp.body.message.role == :assistant
      assert [part] = resp.body.message.content
      assert part.type == :text
      assert part.text == "Hello world"
      assert resp.body.usage.input_tokens == 10
      assert resp.body.usage.output_tokens == 20
      assert resp.body.usage.total_tokens == 30
    end

    test "decodes response with message segments" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output" => [
          %{
            "type" => "message",
            "content" => [
              %{"type" => "output_text", "text" => "Part 1 "},
              %{"type" => "output_text", "text" => "Part 2"}
            ]
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert [part] = resp.body.message.content
      assert part.type == :text
      assert part.text == "Part 1 Part 2"
    end

    test "decodes response with direct output_text segments" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output" => [
          %{"type" => "output_text", "text" => "Direct text"}
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert [part] = resp.body.message.content
      assert part.type == :text
      assert part.text == "Direct text"
    end

    test "aggregates text from multiple sources" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output_text" => "Top level ",
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "message "}]
          },
          %{"type" => "output_text", "text" => "direct"}
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert [part] = resp.body.message.content
      assert part.type == :text
      assert part.text == "Top level message direct"
    end

    test "decodes reasoning summary" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output" => [
          %{"type" => "reasoning", "summary" => "Thinking about this..."}
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert [thinking_part] = resp.body.message.content
      assert thinking_part.type == :thinking
      assert thinking_part.text == "Thinking about this..."
    end

    test "decodes reasoning content" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output" => [
          %{
            "type" => "reasoning",
            "content" => [
              %{"text" => "Step 1 "},
              %{"text" => "Step 2"}
            ]
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert [thinking_part] = resp.body.message.content
      assert thinking_part.type == :thinking
      assert thinking_part.text == "Step 1 Step 2"
    end

    test "aggregates reasoning from summary and content" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output" => [
          %{
            "type" => "reasoning",
            "summary" => "Summary ",
            "content" => [%{"text" => "details"}]
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert [thinking_part] = resp.body.message.content
      assert thinking_part.type == :thinking
      assert thinking_part.text == "Summary details"
    end

    test "decodes tool calls" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output" => [
          %{
            "type" => "function_call",
            "call_id" => "call_abc",
            "name" => "get_weather",
            "arguments" => ~s({"location": "NYC"})
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert [tool_call] = resp.body.message.tool_calls
      assert tool_call.id == "call_abc"
      assert tool_call.function.name == "get_weather"
      assert Jason.decode!(tool_call.function.arguments) == %{"location" => "NYC"}
    end

    test "handles malformed tool call arguments" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output" => [
          %{
            "type" => "function_call",
            "call_id" => "call_abc",
            "name" => "get_weather",
            "arguments" => "invalid json"
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert [tool_call] = resp.body.message.tool_calls
      assert tool_call.id == "call_abc"
      assert tool_call.function.name == "get_weather"
      assert tool_call.function.arguments == "invalid json"
    end

    test "normalizes usage with reasoning_tokens" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output_text" => "Hello",
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 20,
          "output_tokens_details" => %{
            "reasoning_tokens" => 5
          }
        }
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert resp.body.usage.input_tokens == 10
      assert resp.body.usage.output_tokens == 20
      assert resp.body.usage.total_tokens == 30
    end

    test "returns error for non-200 status" do
      {_req, result} = ResponsesAPI.decode_response(build_response(500, %{"error" => "boom"}))

      assert %ReqLLM.Error.API.Response{} = result
      assert result.status == 500
      assert result.reason == "OpenAI Responses API error"
    end

    test "handles missing usage gracefully" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output_text" => "Hello"
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert resp.body.usage.input_tokens == 0
      assert resp.body.usage.output_tokens == 0
      assert resp.body.usage.total_tokens == 0
    end

    test "appends message to request context" do
      msg = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Hello"}]
      }

      context = %ReqLLM.Context{messages: [msg]}

      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output_text" => "Hi",
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} =
        ResponsesAPI.decode_response(build_response(200, response_body, context: context))

      assert length(resp.body.context.messages) == 2
      assert Enum.at(resp.body.context.messages, 0).role == :user
      assert Enum.at(resp.body.context.messages, 1).role == :assistant
    end
  end

  describe "decode_stream_event/2" do
    setup do
      {:ok, model} = ReqLLM.model("openai:gpt-5")
      {:ok, model: model}
    end

    test "decodes output_text delta", %{model: model} do
      event = %{data: %{"event" => "response.output_text.delta", "delta" => "Hello"}}

      assert [chunk] = ResponsesAPI.decode_stream_event(event, model)
      assert chunk.type == :content
      assert chunk.text == "Hello"
    end

    test "ignores empty output_text delta", %{model: model} do
      event = %{data: %{"event" => "response.output_text.delta", "delta" => ""}}

      assert [] = ResponsesAPI.decode_stream_event(event, model)
    end

    test "decodes reasoning delta", %{model: model} do
      event = %{data: %{"event" => "response.reasoning.delta", "delta" => "Thinking..."}}

      assert [chunk] = ResponsesAPI.decode_stream_event(event, model)
      assert chunk.type == :thinking
      assert chunk.text == "Thinking..."
    end

    test "ignores empty reasoning delta", %{model: model} do
      event = %{data: %{"event" => "response.reasoning.delta", "delta" => ""}}

      assert [] = ResponsesAPI.decode_stream_event(event, model)
    end

    test "decodes usage event", %{model: model} do
      event = %{
        data: %{
          "event" => "response.usage",
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 20
          }
        }
      }

      assert [chunk] = ResponsesAPI.decode_stream_event(event, model)
      assert chunk.type == :meta
      assert chunk.metadata.usage.input_tokens == 10
      assert chunk.metadata.usage.output_tokens == 20
      assert chunk.metadata.usage.total_tokens == 30
      assert chunk.metadata.model == "gpt-5"
    end

    test "normalizes usage with reasoning_tokens", %{model: model} do
      event = %{
        data: %{
          "event" => "response.usage",
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 20,
            "output_tokens_details" => %{
              "reasoning_tokens" => 5
            }
          }
        }
      }

      assert [chunk] = ResponsesAPI.decode_stream_event(event, model)
      assert chunk.metadata.usage.input_tokens == 10
      assert chunk.metadata.usage.output_tokens == 20
      assert chunk.metadata.usage.total_tokens == 30
      assert chunk.metadata.usage.cached_tokens == 0
      assert chunk.metadata.usage.reasoning_tokens == 5
    end

    test "ignores output_text done event", %{model: model} do
      event = %{data: %{"event" => "response.output_text.done"}}

      assert [] = ResponsesAPI.decode_stream_event(event, model)
    end

    test "decodes completed event", %{model: model} do
      event = %{data: %{"event" => "response.completed"}}

      assert [chunk] = ResponsesAPI.decode_stream_event(event, model)
      assert chunk.type == :meta
      assert chunk.metadata.terminal? == true
      assert chunk.metadata.finish_reason == :stop
    end

    test "decodes incomplete event", %{model: model} do
      event = %{data: %{"event" => "response.incomplete", "reason" => "length"}}

      assert [chunk] = ResponsesAPI.decode_stream_event(event, model)
      assert chunk.type == :meta
      assert chunk.metadata.terminal? == true
      assert chunk.metadata.finish_reason == :length
    end

    test "decodes incomplete event with usage so metadata includes usage when finish_reason is length",
         %{model: model} do
      event = %{
        data: %{
          "event" => "response.incomplete",
          "reason" => "length",
          "response" => %{
            "incomplete_details" => %{"reason" => "length"},
            "usage" => %{
              "input_tokens" => 8,
              "output_tokens" => 12
            }
          }
        }
      }

      assert [chunk] = ResponsesAPI.decode_stream_event(event, model)
      assert chunk.type == :meta
      assert chunk.metadata.terminal? == true
      assert chunk.metadata.finish_reason == :length
      assert %{input_tokens: 8, output_tokens: 12, total_tokens: 20} = chunk.metadata.usage
    end

    test "handles [DONE] event", %{model: model} do
      event = %{data: "[DONE]"}

      assert [chunk] = ResponsesAPI.decode_stream_event(event, model)
      assert chunk.type == :meta
      assert chunk.metadata.terminal? == true
    end

    test "uses type field when event field missing", %{model: model} do
      event = %{data: %{"type" => "response.output_text.delta", "delta" => "Text"}}

      assert [chunk] = ResponsesAPI.decode_stream_event(event, model)
      assert chunk.type == :content
      assert chunk.text == "Text"
    end

    test "ignores unknown event types", %{model: model} do
      event = %{data: %{"event" => "response.unknown.type"}}

      assert [] = ResponsesAPI.decode_stream_event(event, model)
    end

    test "ignores events with missing event type", %{model: model} do
      event = %{data: %{"delta" => "text"}}

      assert [] = ResponsesAPI.decode_stream_event(event, model)
    end
  end

  describe "reasoning details - decode_response/1" do
    test "decodes reasoning items with summary_text array and populates reasoning_details" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output" => [
          %{
            "id" => "rs_abc123",
            "type" => "reasoning",
            "summary" => [
              %{"type" => "summary_text", "text" => "Analyzing the problem..."},
              %{"type" => "summary_text", "text" => " Breaking it down..."}
            ],
            "encrypted_content" => "base64_encrypted_content_here"
          },
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "The answer is 42."}]
          }
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 50}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert %ReqLLM.Response{} = resp.body
      assert [reasoning_detail] = resp.body.message.reasoning_details
      assert %ReqLLM.Message.ReasoningDetails{} = reasoning_detail
      assert reasoning_detail.text == "Analyzing the problem... Breaking it down..."
      assert reasoning_detail.signature == "base64_encrypted_content_here"
      assert reasoning_detail.encrypted? == true
      assert reasoning_detail.provider == :openai
      assert reasoning_detail.format == "openai-responses-v1"
      assert reasoning_detail.index == 0
      assert reasoning_detail.provider_data == %{"id" => "rs_abc123", "type" => "reasoning"}
    end

    test "decodes reasoning items with string summary" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output" => [
          %{
            "id" => "rs_xyz789",
            "type" => "reasoning",
            "summary" => "Thinking step by step..."
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert [reasoning_detail] = resp.body.message.reasoning_details
      assert reasoning_detail.text == "Thinking step by step..."
      assert reasoning_detail.encrypted? == false
      assert reasoning_detail.signature == nil
    end

    test "decodes multiple reasoning items preserving order" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output" => [
          %{
            "id" => "rs_001",
            "type" => "reasoning",
            "summary" => [%{"type" => "summary_text", "text" => "First thought"}]
          },
          %{
            "id" => "rs_002",
            "type" => "reasoning",
            "summary" => [%{"type" => "summary_text", "text" => "Second thought"}]
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert [first, second] = resp.body.message.reasoning_details
      assert first.text == "First thought"
      assert first.index == 0
      assert second.text == "Second thought"
      assert second.index == 1
    end

    test "response without reasoning items has nil reasoning_details" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output_text" => "Just a simple response",
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert resp.body.message.reasoning_details == nil
    end

    test "response with empty reasoning has nil text but retains encrypted_content" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output" => [
          %{
            "id" => "rs_abc",
            "type" => "reasoning",
            "summary" => [],
            "encrypted_content" => "encrypted_data"
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert [detail] = resp.body.message.reasoning_details
      assert detail.text == nil
      assert detail.signature == "encrypted_data"
      assert detail.encrypted? == true
    end
  end

  describe "reasoning details - encode_body/1" do
    test "includes reasoning items in input when no previous_response_id" do
      reasoning_detail = %ReqLLM.Message.ReasoningDetails{
        text: "Previous reasoning",
        signature: "encrypted_sig_abc",
        encrypted?: true,
        provider: :openai,
        format: "openai-responses-v1",
        index: 0,
        provider_data: %{"id" => "rs_prev123", "type" => "reasoning"}
      }

      assistant_msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Previous answer"}],
        reasoning_details: [reasoning_detail]
      }

      user_msg = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Follow up question"}]
      }

      context = %ReqLLM.Context{messages: [assistant_msg, user_msg]}
      request = build_request(context: context)

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert [reasoning_input | _rest] = body["input"]
      assert reasoning_input["type"] == "reasoning"
      assert reasoning_input["id"] == "rs_prev123"
      assert reasoning_input["encrypted_content"] == "encrypted_sig_abc"
    end

    test "does not include reasoning items when previous_response_id is present" do
      reasoning_detail = %ReqLLM.Message.ReasoningDetails{
        text: "Previous reasoning",
        signature: "encrypted_sig",
        encrypted?: true,
        provider: :openai,
        format: "openai-responses-v1",
        index: 0,
        provider_data: %{"id" => "rs_123", "type" => "reasoning"}
      }

      assistant_msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Previous answer"}],
        reasoning_details: [reasoning_detail],
        metadata: %{response_id: "resp_prev_123"}
      }

      user_msg = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Follow up"}]
      }

      context = %ReqLLM.Context{messages: [assistant_msg, user_msg]}
      request = build_request(context: context)

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["previous_response_id"] == "resp_prev_123"

      refute Enum.any?(body["input"], fn item ->
               item["type"] == "reasoning"
             end)
    end

    test "skips non-OpenAI reasoning details with warning" do
      import ExUnit.CaptureLog

      anthropic_detail = %ReqLLM.Message.ReasoningDetails{
        text: "Anthropic thinking",
        signature: "anthro_sig",
        encrypted?: false,
        provider: :anthropic,
        format: "anthropic-thinking-v1",
        index: 0,
        provider_data: %{}
      }

      assistant_msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Response"}],
        reasoning_details: [anthropic_detail]
      }

      user_msg = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Next question"}]
      }

      context = %ReqLLM.Context{messages: [assistant_msg, user_msg]}
      request = build_request(context: context)

      log =
        capture_log(fn ->
          encoded = ResponsesAPI.encode_body(request)
          body = Jason.decode!(encoded.body)

          refute Enum.any?(body["input"], fn item ->
                   item["type"] == "reasoning"
                 end)
        end)

      assert log =~ "Skipping non-OpenAI reasoning detail from provider: :anthropic"
    end

    test "encodes reasoning detail without id when provider_data has no id" do
      reasoning_detail = %ReqLLM.Message.ReasoningDetails{
        text: "Reasoning text",
        signature: "sig_123",
        encrypted?: true,
        provider: :openai,
        format: "openai-responses-v1",
        index: 0,
        provider_data: %{}
      }

      assistant_msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Answer"}],
        reasoning_details: [reasoning_detail]
      }

      user_msg = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Question"}]
      }

      context = %ReqLLM.Context{messages: [assistant_msg, user_msg]}
      request = build_request(context: context)

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert [reasoning_input | _rest] = body["input"]
      assert reasoning_input["type"] == "reasoning"
      assert reasoning_input["encrypted_content"] == "sig_123"
      refute Map.has_key?(reasoning_input, "id")
    end
  end

  defp build_request(opts) do
    context = Keyword.get(opts, :context, %ReqLLM.Context{messages: []})
    provider_opts = Keyword.get(opts, :provider_options, [])

    req_opts = %{
      id: "gpt-5",
      context: context,
      stream: Keyword.get(opts, :stream),
      max_output_tokens: Keyword.get(opts, :max_output_tokens),
      max_completion_tokens: Keyword.get(opts, :max_completion_tokens),
      max_tokens: Keyword.get(opts, :max_tokens),
      tools: Keyword.get(opts, :tools),
      tool_choice: Keyword.get(opts, :tool_choice),
      reasoning_effort: Keyword.get(opts, :reasoning_effort),
      provider_options: provider_opts
    }

    %Req.Request{
      method: :post,
      url: URI.parse("https://api.openai.com/v1/responses"),
      headers: %{},
      body: {:json, %{}},
      options: req_opts
    }
  end

  defp build_response(status, body, opts \\ []) do
    context = Keyword.get(opts, :context, %ReqLLM.Context{messages: []})

    req = %Req.Request{
      method: :post,
      url: URI.parse("https://api.openai.com/v1/responses"),
      headers: %{},
      body: {:json, %{}},
      options: %{id: "gpt-5", context: context}
    }

    resp = %Req.Response{
      status: status,
      headers: %{},
      body: body
    }

    {req, resp}
  end

  describe "ResponseBuilder - streaming reasoning_details extraction" do
    alias ReqLLM.Providers.OpenAI.ResponsesAPI.ResponseBuilder

    test "extracts reasoning_details from thinking chunks" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      thinking_meta = %{
        provider: :openai,
        format: "openai-responses-v1",
        encrypted?: false,
        provider_data: %{"type" => "reasoning"}
      }

      chunks = [
        ReqLLM.StreamChunk.thinking("Step 1: Analyze the problem", thinking_meta),
        ReqLLM.StreamChunk.thinking("Step 2: Consider solutions", thinking_meta),
        ReqLLM.StreamChunk.text("The answer is 42.")
      ]

      metadata = %{finish_reason: :stop, response_id: "resp_123"}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.reasoning_details != nil
      assert length(response.message.reasoning_details) == 2

      [first, second] = response.message.reasoning_details
      assert %ReqLLM.Message.ReasoningDetails{} = first
      assert first.text == "Step 1: Analyze the problem"
      assert first.provider == :openai
      assert first.format == "openai-responses-v1"
      assert first.index == 0

      assert second.text == "Step 2: Consider solutions"
      assert second.index == 1
    end

    test "returns nil reasoning_details when no thinking chunks" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.text("Just a simple response.")
      ]

      metadata = %{finish_reason: :stop}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.reasoning_details == nil
    end

    test "propagates response_id to message metadata" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.thinking("Thinking..."),
        ReqLLM.StreamChunk.text("Response")
      ]

      metadata = %{finish_reason: :stop, response_id: "resp_abc123"}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.metadata[:response_id] == "resp_abc123"
      assert length(response.message.reasoning_details) == 1
    end

    test "attaches reasoning_details to context messages" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.thinking("Deep thought"),
        ReqLLM.StreamChunk.text("Final answer")
      ]

      metadata = %{finish_reason: :stop}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      [context_msg] = response.context.messages
      assert context_msg.reasoning_details != nil
      assert length(context_msg.reasoning_details) == 1
      assert hd(context_msg.reasoning_details).text == "Deep thought"
    end
  end
end

defmodule Provider.OpenAI.ResponsesAPIUnitTest do
  use ExUnit.Case, async: false

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
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["max_output_tokens"] == 1000
      assert body["model"] == "gpt-5"
      assert body["stream"] == nil
    end

    test "normalizes max_completion_tokens to max_output_tokens" do
      request = build_request(max_completion_tokens: 2048)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["max_output_tokens"] == 2048
    end

    test "normalizes max_tokens to max_output_tokens" do
      request = build_request(max_tokens: 512)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

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
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["max_output_tokens"] == 1000
    end

    test "encodes streaming request" do
      request = build_request(stream: true)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

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
      body = ReqLLM.Test.Helpers.json_body(encoded)

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
      body = ReqLLM.Test.Helpers.json_body(encoded)

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
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert [encoded_tool] = body["tools"]
      assert encoded_tool["strict"] == true
      assert Enum.sort(encoded_tool["parameters"]["required"]) == ["location", "units"]
    end

    test "strictifies raw function tools with JSON schema placeholder parameters" do
      tool = %{
        "type" => "function",
        "function" => %{
          "name" => "websearch",
          "description" => "Search the web",
          "parameters" => %{
            "type" => "object",
            "required" => ["query"],
            "properties" => %{
              "query" => %{"type" => "string"},
              "outputSchema" => %{
                "description" => "JSON schema for synthesized output.content"
              },
              "summary" => %{
                "anyOf" => [
                  %{"type" => "boolean"},
                  %{
                    "type" => "object",
                    "properties" => %{
                      "schema" => %{
                        "description" => "JSON schema for structured summary output"
                      }
                    }
                  }
                ]
              }
            }
          }
        }
      }

      request = build_request(tools: [tool])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert [encoded_tool] = body["tools"]
      assert encoded_tool["type"] == "function"
      assert encoded_tool["name"] == "websearch"
      assert encoded_tool["strict"] == true

      params = encoded_tool["parameters"]
      assert Enum.sort(params["required"]) == ["outputSchema", "query", "summary"]
      assert params["additionalProperties"] == false

      output_schema = params["properties"]["outputSchema"]
      assert output_schema["description"] == "JSON schema for synthesized output.content"
      assert output_schema["type"] == "object"
      assert output_schema["properties"] == %{}
      assert output_schema["required"] == []
      assert output_schema["additionalProperties"] == false

      [_, summary_object] = params["properties"]["summary"]["anyOf"]
      nested_schema = summary_object["properties"]["schema"]
      assert nested_schema["description"] == "JSON schema for structured summary output"
      assert nested_schema["type"] == "object"
      assert nested_schema["properties"] == %{}
      assert nested_schema["required"] == []
      assert nested_schema["additionalProperties"] == false
    end

    test "passes through code_interpreter tool maps unchanged" do
      tool = %{
        "type" => "code_interpreter",
        "container" => %{"type" => "auto", "memory_limit" => "4g"}
      }

      request = build_request(tools: [tool])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert [encoded_tool] = body["tools"]
      assert encoded_tool["type"] == "code_interpreter"
      assert encoded_tool["container"] == %{"type" => "auto", "memory_limit" => "4g"}
      refute Map.has_key?(encoded_tool, "strict")
      refute Map.has_key?(encoded_tool, "parameters")
    end

    test "passes through atom-keyed code_interpreter tool maps" do
      tool = %{type: :code_interpreter, container: %{type: :auto, memory_limit: "4g"}}

      request = build_request(tools: [tool])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert [encoded_tool] = body["tools"]
      assert encoded_tool["type"] == "code_interpreter"
      assert encoded_tool["container"] == %{"type" => "auto", "memory_limit" => "4g"}
    end

    test "passes through string container IDs for code_interpreter" do
      tool = %{"type" => "code_interpreter", "container" => "cntr_abc123"}

      request = build_request(tools: [tool])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert [encoded_tool] = body["tools"]
      assert encoded_tool["type"] == "code_interpreter"
      assert encoded_tool["container"] == "cntr_abc123"
    end

    test "does not emit unverified-model warnings when the request uses the id field" do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          request = build_request([])

          encoded = ResponsesAPI.encode_body(request)
          body = ReqLLM.Test.Helpers.json_body(encoded)

          assert body["model"] == "gpt-5"
        end)

      assert warning == ""
    end

    test "encodes file_id content parts as input_file items" do
      file_part = ReqLLM.Message.ContentPart.file_id("file-6F2ksmvXxt4VdoqmHRw6kL")

      context = %ReqLLM.Context{
        messages: [
          %ReqLLM.Message{
            role: :user,
            content: [
              ReqLLM.Message.ContentPart.text("Summarize this file"),
              file_part
            ]
          }
        ]
      }

      request = build_request(context: context)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert [
               %{
                 "role" => "user",
                 "content" => [
                   %{"type" => "input_text", "text" => "Summarize this file"},
                   %{"type" => "input_file", "file_id" => "file-6F2ksmvXxt4VdoqmHRw6kL"}
                 ]
               }
             ] = body["input"]
    end

    test "omits tools when empty list" do
      request = build_request(tools: [])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      refute Map.has_key?(body, "tools")
    end

    test "encodes tool_choice auto" do
      request = build_request(tool_choice: :auto)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["tool_choice"] == "auto"
    end

    test "encodes tool_choice none" do
      request = build_request(tool_choice: :none)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["tool_choice"] == "none"
    end

    test "encodes tool_choice required" do
      request = build_request(tool_choice: :required)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

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
      body = ReqLLM.Test.Helpers.json_body(encoded)

      tool_output =
        Enum.find(body["input"], fn item ->
          item["type"] == "function_call_output"
        end)

      assert tool_output["call_id"] == "call_1"
      assert Jason.decode!(tool_output["output"]) == %{"temp" => 72}
    end

    test "prefers explicit model-facing content over application output" do
      tool_result =
        ReqLLM.Context.tool_result(
          "call_1",
          "search_documents",
          %ReqLLM.ToolResult{
            output: %{records: [%{id: 1}], internal_cursor: "cursor_123"},
            content: [ReqLLM.Message.ContentPart.text("One matching document was found.")]
          }
        )

      context = %ReqLLM.Context{messages: [tool_result]}
      request = build_request(context: context)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      tool_output =
        Enum.find(body["input"], fn item ->
          item["type"] == "function_call_output"
        end)

      assert tool_output["output"] == "One matching document was found."
    end

    test "skips builtin tool calls when replaying assistant context" do
      contexts = [
        %ReqLLM.Context{
          messages: [
            %ReqLLM.Message{
              role: :assistant,
              content: [],
              tool_calls: [
                ReqLLM.ToolCall.new_builtin("ws_1", "web_search_call", ~s({"query":"elixir"}))
              ]
            }
          ]
        },
        %ReqLLM.Context{
          messages: [
            %ReqLLM.Message{
              role: :assistant,
              content: [],
              tool_calls: [
                %{
                  "id" => "ws_1",
                  "function" => %{
                    "name" => "web_search_call",
                    "arguments" => ~s({"query":"elixir"}),
                    "builtin?" => true
                  }
                }
              ]
            }
          ]
        }
      ]

      for context <- contexts do
        request = build_request(context: context)
        encoded = ResponsesAPI.encode_body(request)
        body = Jason.decode!(encoded.body)

        refute Enum.any?(body["input"], &(&1["type"] == "function_call"))
      end
    end

    test "requires and encodes explicit results for provider-native calls" do
      base_context = ReqLLM.Context.new([ReqLLM.Context.user("Search provider data")])

      provider_native_call =
        "native_1"
        |> ReqLLM.ToolCall.new("provider_search", ~s({"query":"elixir"}))
        |> ReqLLM.ToolCall.put_metadata(%{provider_native: :openai})

      assistant =
        ReqLLM.Context.assistant("", tool_calls: [provider_native_call])

      assert {:error, %ReqLLM.Error.Validation.Error{context: error_context}} =
               ReqLLM.Context.append_tool_exchange(base_context, assistant, [])

      assert error_context[:kind] == :missing_tool_results

      result =
        ReqLLM.Context.tool_result(
          "native_1",
          "provider_search",
          "provider search complete"
        )

      assert {:ok, context} =
               ReqLLM.Context.append_tool_exchange(base_context, assistant, [result])

      request = build_request(context: context)
      body = request |> ResponsesAPI.encode_body() |> ReqLLM.Test.Helpers.json_body()

      function_items =
        Enum.filter(body["input"], &(&1["type"] in ["function_call", "function_call_output"]))

      assert Enum.map(function_items, & &1["type"]) == [
               "function_call",
               "function_call_output"
             ]

      assert Enum.map(function_items, & &1["call_id"]) == ["native_1", "native_1"]
    end

    test "encodes multimodal tool results as array function_call_output" do
      tool_call = %ReqLLM.ToolCall{
        id: "call_1",
        type: "function",
        function: %{name: "take_screenshot", arguments: ~s({})}
      }

      assistant_msg = %ReqLLM.Message{
        role: :assistant,
        content: [],
        tool_calls: [tool_call]
      }

      tool_result =
        ReqLLM.Context.tool_result("call_1", [
          ReqLLM.Message.ContentPart.text("Captured screenshot"),
          ReqLLM.Message.ContentPart.image(<<137, 80, 78, 71>>, "image/png")
        ])

      context = %ReqLLM.Context{messages: [assistant_msg, tool_result]}
      request = build_request(context: context)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      tool_output =
        Enum.find(body["input"], fn item ->
          item["type"] == "function_call_output"
        end)

      assert tool_output["call_id"] == "call_1"
      assert is_list(tool_output["output"])

      assert Enum.any?(tool_output["output"], fn part ->
               part["type"] == "input_text" and part["text"] == "Captured screenshot"
             end)

      assert Enum.any?(tool_output["output"], fn part ->
               part["type"] == "input_image" and
                 String.starts_with?(part["image_url"], "data:image/png;base64,")
             end)
    end

    test "encodes file-bearing tool results as array function_call_output" do
      tool_call = %ReqLLM.ToolCall{
        id: "call_1",
        type: "function",
        function: %{name: "export_report", arguments: ~s({})}
      }

      assistant_msg = %ReqLLM.Message{
        role: :assistant,
        content: [],
        tool_calls: [tool_call]
      }

      tool_result =
        ReqLLM.Context.tool_result("call_1", [
          ReqLLM.Message.ContentPart.text("Attached report"),
          ReqLLM.Message.ContentPart.file("report-bytes", "report.txt", "text/plain")
        ])

      context = %ReqLLM.Context{messages: [assistant_msg, tool_result]}
      request = build_request(context: context)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      tool_output =
        Enum.find(body["input"], fn item ->
          item["type"] == "function_call_output"
        end)

      assert tool_output["call_id"] == "call_1"
      assert is_list(tool_output["output"])

      assert Enum.any?(tool_output["output"], fn part ->
               part["type"] == "input_text" and part["text"] == "Attached report"
             end)

      assert Enum.any?(tool_output["output"], fn part ->
               part["type"] == "input_file" and
                 part["filename"] == "report.txt" and
                 String.starts_with?(part["file_data"], "data:text/plain;base64,")
             end)
    end

    test "encodes specific tool choice with atom keys" do
      request =
        build_request(tool_choice: %{type: "function", function: %{name: "get_weather"}})

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["tool_choice"] == %{"type" => "function", "name" => "get_weather"}
    end

    test "encodes specific tool choice with string keys" do
      request =
        build_request(tool_choice: %{"type" => "function", "function" => %{"name" => "search"}})

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["tool_choice"] == %{"type" => "function", "name" => "search"}
    end

    test "encodes parallel_tool_calls true" do
      request = build_request(parallel_tool_calls: true)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["parallel_tool_calls"] == true
    end

    test "encodes parallel_tool_calls false" do
      request = build_request(parallel_tool_calls: false)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["parallel_tool_calls"] == false
    end

    test "omits parallel_tool_calls when not set" do
      request = build_request([])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      refute Map.has_key?(body, "parallel_tool_calls")
    end

    test "encodes reasoning effort with atom" do
      request = build_request(reasoning_effort: :medium)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["reasoning"] == %{"effort" => "medium"}
    end

    test "encodes reasoning effort with string" do
      request = build_request(reasoning_effort: "high")

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["reasoning"] == %{"effort" => "high"}
    end

    test "encodes reasoning effort :none" do
      request = build_request(reasoning_effort: :none)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["reasoning"] == %{"effort" => "none"}
    end

    test "encodes reasoning effort :minimal" do
      request = build_request(reasoning_effort: :minimal)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["reasoning"] == %{"effort" => "minimal"}
    end

    test "encodes reasoning effort :xhigh" do
      request = build_request(reasoning_effort: :xhigh)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["reasoning"] == %{"effort" => "xhigh"}
    end

    test "encodes reasoning summary alongside effort" do
      request = build_request(reasoning_effort: :high, reasoning_summary: "auto")

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["reasoning"] == %{"effort" => "high", "summary" => "auto"}
    end

    test "encodes atom reasoning summary value" do
      request = build_request(reasoning_effort: :medium, reasoning_summary: :detailed)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["reasoning"] == %{"effort" => "medium", "summary" => "detailed"}
    end

    test "encodes reasoning summary without effort" do
      request = build_request(reasoning_summary: "auto")

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["reasoning"] == %{"summary" => "auto"}
      refute Map.has_key?(body["reasoning"], "effort")
    end

    test "keeps backward-compatible reasoning shape without summary" do
      request = build_request(reasoning_effort: :low)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["reasoning"] == %{"effort" => "low"}
    end

    test "omits reasoning effort when nil" do
      request = build_request(provider_options: [])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      refute Map.has_key?(body, "reasoning")
    end

    test "passes explicit include through unchanged" do
      include = ["reasoning.encrypted_content", "file_search_call.results"]
      request = build_request(provider_options: [include: include])

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["include"] == include
    end

    test "defaults include for reasoning models" do
      request = build_request(id: "gpt-5-mini")

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["include"] == ["reasoning.encrypted_content"]
    end

    test "respects empty include override for reasoning models" do
      request = build_request(id: "gpt-5-mini", provider_options: [include: []])

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["include"] == []
    end

    test "does not default include for non-reasoning Responses models" do
      request = build_request(id: "gpt-4o-mini")

      encoded = ResponsesAPI.encode_body(request)
      body = Jason.decode!(encoded.body)

      refute Map.has_key?(body, "include")
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
      body = ReqLLM.Test.Helpers.json_body(encoded)

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
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["text"]["format"]["type"] == "json_schema"
      assert body["text"]["format"]["name"] == "person_schema"
      assert body["text"]["format"]["strict"] == true
      assert body["text"]["format"]["schema"]["type"] == "object"
      assert body["text"]["format"]["schema"]["properties"]["name"]["type"] == "string"
      assert body["text"]["format"]["schema"]["properties"]["age"]["type"] == "integer"
      assert body["text"]["format"]["schema"]["properties"]["age"]["minimum"] == 1
      assert body["text"]["format"]["schema"]["required"] == ["name"]

      # propertyOrdering is consumed during encoding — verify wire order instead
      refute Map.has_key?(body["text"]["format"]["schema"], "propertyOrdering")

      # Verify the actual JSON wire order of properties
      assert IO.iodata_to_binary(ReqLLM.Test.Helpers.json_iodata(encoded)) =~
               ~r/"properties"\s*:\s*\{\s*"name".*"age"/s
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
      body = ReqLLM.Test.Helpers.json_body(encoded)

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
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["text"]["format"]["type"] == "json_schema"
      assert body["text"]["format"]["name"] == "search_schema"
      assert body["text"]["format"]["strict"] == true
      assert body["text"]["format"]["schema"] == json_schema
    end

    test "encodes verbosity when provided as atom" do
      request = build_request(provider_options: [verbosity: :low])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["text"]["verbosity"] == "low"
    end

    test "encodes verbosity when provided as string" do
      request = build_request(provider_options: [verbosity: "high"])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["text"]["verbosity"] == "high"
    end

    test "omits text field when no verbosity or response_format" do
      request = build_request(provider_options: [])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

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
      body = ReqLLM.Test.Helpers.json_body(encoded)

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

    test "deduplicates identical commentary and final_answer message segments" do
      text = "Do you want a shortcut for all users or just the current user?"

      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5.4",
        "output" => [
          %{
            "type" => "message",
            "phase" => "commentary",
            "content" => [%{"type" => "output_text", "text" => text}]
          },
          %{
            "type" => "message",
            "phase" => "final_answer",
            "content" => [%{"type" => "output_text", "text" => text}]
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert [part] = resp.body.message.content
      assert part.type == :text
      assert part.text == text
    end

    test "preserves distinct commentary and final_answer message segments" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5.4",
        "output" => [
          %{
            "type" => "message",
            "phase" => "commentary",
            "content" => [%{"type" => "output_text", "text" => "Let me check that. "}]
          },
          %{
            "type" => "message",
            "phase" => "final_answer",
            "content" => [%{"type" => "output_text", "text" => "Here is the result."}]
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert [part] = resp.body.message.content
      assert part.type == :text
      assert part.text == "Let me check that. Here is the result."
    end

    test "preserves single-message phase metadata" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5.4",
        "output" => [
          %{
            "type" => "message",
            "phase" => "final_answer",
            "content" => [%{"type" => "output_text", "text" => "Root cause found."}]
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert resp.body.message.metadata[:response_id] == "resp_123"
      assert resp.body.message.metadata[:phase] == "final_answer"
      refute Map.has_key?(resp.body.message.metadata, :phase_items)
    end

    test "preserves ordered phase_items for multi-segment phased output" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5.4",
        "output" => [
          %{
            "type" => "message",
            "phase" => "commentary",
            "content" => [%{"type" => "output_text", "text" => "Inspecting logs. "}]
          },
          %{
            "type" => "message",
            "phase" => "final_answer",
            "content" => [%{"type" => "output_text", "text" => "Cache race confirmed."}]
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert resp.body.message.metadata[:response_id] == "resp_123"

      assert resp.body.message.metadata[:phase_items] == [
               %{
                 "phase" => "commentary",
                 "content" => [%{"type" => "output_text", "text" => "Inspecting logs. "}]
               },
               %{
                 "phase" => "final_answer",
                 "content" => [%{"type" => "output_text", "text" => "Cache race confirmed."}]
               }
             ]
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

    test "extracts reasoning summary text via Response.thinking/1" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output" => [
          %{
            "type" => "reasoning",
            "id" => "rs_123",
            "summary" => [
              %{"type" => "summary_text", "text" => "Determining if 143 is prime..."}
            ]
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert ReqLLM.Response.thinking(resp.body) == "Determining if 143 is prime..."
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

    test "decodes builtin tool calls as non-actionable final answers" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "status" => "completed",
        "output" => [
          %{
            "type" => "web_search_call",
            "id" => "ws_1",
            "status" => "completed",
            "action" => %{"type" => "search", "query" => "elixir"}
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert resp.body.finish_reason == :stop
      assert [tool_call] = resp.body.message.tool_calls
      assert ReqLLM.ToolCall.builtin?(tool_call)
      assert tool_call.id == "ws_1"
      assert tool_call.function.name == "web_search_call"

      assert Jason.decode!(tool_call.function.arguments) == %{
               "action" => %{"type" => "search", "query" => "elixir"}
             }

      assert ReqLLM.Response.classify(resp.body).type == :final_answer
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

    test "collects code_interpreter output items in provider_meta" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "The result is 4."}]
          },
          %{
            "type" => "code_interpreter_call",
            "id" => "ci_xxx",
            "code" => "print(2+2)",
            "status" => "completed"
          },
          %{
            "type" => "code_interpreter_logs",
            "call_id" => "ci_xxx",
            "logs" => "4\n"
          },
          %{
            "type" => "code_interpreter_interpretation",
            "call_id" => "ci_xxx",
            "text" => "The result is 4."
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert [part] = resp.body.message.content
      assert part.type == :text
      assert part.text == "The result is 4."
      assert resp.body.message.tool_calls == nil

      assert [call, logs, interpretation] =
               get_in(resp.body.provider_meta, ["code_interpreter", "items"])

      assert call["type"] == "code_interpreter_call"
      assert call["id"] == "ci_xxx"
      assert logs["type"] == "code_interpreter_logs"
      assert logs["logs"] == "4\n"
      assert interpretation["type"] == "code_interpreter_interpretation"
      assert interpretation["text"] == "The result is 4."
    end

    test "preserves code_interpreter_call outputs in provider_meta" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output" => [
          %{
            "type" => "code_interpreter_call",
            "id" => "ci_xxx",
            "code" => "print(2+2)",
            "status" => "completed",
            "outputs" => [
              %{"type" => "code_interpreter_logs", "logs" => "4\n"},
              %{"type" => "code_interpreter_interpretation", "text" => "Four."}
            ]
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert [item] = get_in(resp.body.provider_meta, ["code_interpreter", "items"])
      assert item["type"] == "code_interpreter_call"
      assert [logs, interpretation] = item["outputs"]
      assert logs["type"] == "code_interpreter_logs"
      assert logs["logs"] == "4\n"
      assert interpretation["type"] == "code_interpreter_interpretation"
      assert interpretation["text"] == "Four."
    end

    test "counts code_interpreter usage in tool_usage" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output" => [
          %{
            "type" => "code_interpreter_call",
            "id" => "ci_xxx",
            "code" => "print(2+2)",
            "status" => "completed"
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert resp.body.usage.tool_usage == %{code_interpreter: %{count: 1, unit: :call}}
    end

    test "keeps text and function calls separate from code_interpreter items" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "The result is 4."}]
          },
          %{
            "type" => "function_call",
            "call_id" => "call_123",
            "name" => "get_weather",
            "arguments" => ~s({"location":"SF"})
          },
          %{
            "type" => "code_interpreter_call",
            "id" => "ci_xxx",
            "code" => "print(2+2)",
            "status" => "completed"
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      assert [part] = resp.body.message.content
      assert part.type == :text
      assert part.text == "The result is 4."

      assert [%ReqLLM.ToolCall{function: %{name: "get_weather"}}] = resp.body.message.tool_calls

      assert [call] = get_in(resp.body.provider_meta, ["code_interpreter", "items"])
      assert call["type"] == "code_interpreter_call"
      assert call["id"] == "ci_xxx"
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

    test "validates nested schemas with string keys converted to atoms" do
      result_schema =
        {:map,
         [
           id: [type: :pos_integer, required: true],
           reasoning: [type: :string, required: true],
           tags: [type: {:list, {:in, ~w[IT transport]}}, required: true]
         ]}

      schema = [
        results: [type: {:list, result_schema}, required: true]
      ]

      {:ok, compiled_schema} = ReqLLM.Schema.compile(schema)

      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5",
        "output_text" =>
          ~s({"results": [{"id": 1, "reasoning": "Transport job", "tags": ["transport"]}]}),
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
      }

      msg = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Tag these jobs"}]
      }

      context = %ReqLLM.Context{messages: [msg]}

      req = %Req.Request{
        method: :post,
        url: URI.parse("https://api.openai.com/v1/responses"),
        headers: %{},
        body: {:json, %{}},
        options: %{
          id: "gpt-5",
          context: context,
          operation: :object,
          compiled_schema: compiled_schema
        }
      }

      resp = %Req.Response{
        status: 200,
        headers: %{},
        body: response_body
      }

      {_req, decoded_resp} = ResponsesAPI.decode_response({req, resp})

      assert %ReqLLM.Response{} = decoded_resp.body
      assert decoded_resp.body.object != nil

      assert decoded_resp.body.object["results"] == [
               %{"id" => 1, "reasoning" => "Transport job", "tags" => ["transport"]}
             ]

      assert decoded_resp.body.provider_meta[:object_parse_error] == nil
    end

    test "extracts structured output from tool call when text is empty (gpt-5.4 style)" do
      schema = [name: [type: :string, required: true]]
      {:ok, compiled_schema} = ReqLLM.Schema.compile(schema)

      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5.4",
        "output" => [
          %{
            "type" => "function_call",
            "call_id" => "call_abc",
            "name" => "structured_output",
            "arguments" => ~s({"name": "Alice"})
          }
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
      }

      req = %Req.Request{
        method: :post,
        url: URI.parse("https://api.openai.com/v1/responses"),
        headers: %{},
        body: {:json, %{}},
        options: %{
          id: "gpt-5",
          operation: :object,
          compiled_schema: compiled_schema
        }
      }

      resp = %Req.Response{status: 200, headers: %{}, body: response_body}

      {_req, decoded_resp} = ResponsesAPI.decode_response({req, resp})

      assert %ReqLLM.Response{} = decoded_resp.body
      assert decoded_resp.body.object == %{"name" => "Alice"}
      assert decoded_resp.body.provider_meta[:object_parse_error] == nil
    end

    test "validates structured output from tool calls against the compiled schema" do
      schema = [name: [type: :string, required: true], age: [type: :integer, required: true]]
      {:ok, compiled_schema} = ReqLLM.Schema.compile(schema)

      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5.4",
        "output" => [
          %{
            "type" => "function_call",
            "call_id" => "call_abc",
            "name" => "structured_output",
            "arguments" => ~s({"name": "Alice"})
          }
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
      }

      req = %Req.Request{
        method: :post,
        url: URI.parse("https://api.openai.com/v1/responses"),
        headers: %{},
        body: {:json, %{}},
        options: %{
          id: "gpt-5",
          operation: :object,
          compiled_schema: compiled_schema
        }
      }

      resp = %Req.Response{status: 200, headers: %{}, body: response_body}

      {_req, decoded_resp} = ResponsesAPI.decode_response({req, resp})

      assert %ReqLLM.Response{} = decoded_resp.body
      assert decoded_resp.body.object == nil
      assert decoded_resp.body.provider_meta[:object_parse_error] == :validation_failed
    end

    test "respects json_repair option for structured output tool calls" do
      schema = [name: [type: :string, required: true]]
      {:ok, compiled_schema} = ReqLLM.Schema.compile(schema)

      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5.4",
        "output" => [
          %{
            "type" => "function_call",
            "call_id" => "call_abc",
            "name" => "structured_output",
            "arguments" => ~s({"name":"Alice",})
          }
        ],
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
      }

      req = %Req.Request{
        method: :post,
        url: URI.parse("https://api.openai.com/v1/responses"),
        headers: %{},
        body: {:json, %{}},
        options: %{
          id: "gpt-5",
          operation: :object,
          compiled_schema: compiled_schema,
          json_repair: false
        }
      }

      resp = %Req.Response{status: 200, headers: %{}, body: response_body}

      {_req, decoded_resp} = ResponsesAPI.decode_response({req, resp})

      assert %ReqLLM.Response{} = decoded_resp.body
      assert decoded_resp.body.object == nil
      assert decoded_resp.body.provider_meta[:object_parse_error] == :invalid_json
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

    test "decodes reasoning summary text delta", %{model: model} do
      event = %{
        data: %{
          "event" => "response.reasoning_summary_text.delta",
          "delta" => "Checking primality..."
        }
      }

      assert [chunk] = ResponsesAPI.decode_stream_event(event, model)
      assert chunk.type == :thinking
      assert chunk.text == "Checking primality..."
    end

    test "ignores empty reasoning summary text delta", %{model: model} do
      event = %{
        data: %{
          "event" => "response.reasoning_summary_text.delta",
          "delta" => ""
        }
      }

      assert [] = ResponsesAPI.decode_stream_event(event, model)
    end

    test "ignores reasoning summary text done event", %{model: model} do
      event = %{data: %{"event" => "response.reasoning_summary_text.done"}}

      assert [] = ResponsesAPI.decode_stream_event(event, model)
    end

    test "ignores reasoning summary part done event", %{model: model} do
      event = %{data: %{"event" => "response.reasoning_summary_part.done"}}

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

    test "decodes completed function_call output items", %{model: model} do
      event = %{
        data: %{
          "event" => "response.output_item.done",
          "output_index" => 0,
          "item" => %{
            "type" => "function_call",
            "call_id" => "call_123",
            "name" => "get_weather",
            "arguments" => ~s({"location":"SF"})
          }
        }
      }

      assert [tool_chunk, args_chunk] = ResponsesAPI.decode_stream_event(event, model)
      assert tool_chunk.type == :tool_call
      assert tool_chunk.name == "get_weather"
      assert tool_chunk.metadata.id == "call_123"
      assert tool_chunk.metadata.index == 0
      assert args_chunk.metadata.tool_call_args.fragment == ~s({"location":"SF"})
    end

    test "decodes completed message output items", %{model: model} do
      event = %{
        data: %{
          "event" => "response.output_item.done",
          "output_index" => 0,
          "item" => %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "Final answer"}]
          }
        }
      }

      assert [chunk] = ResponsesAPI.decode_stream_event(event, model)
      assert chunk.type == :content
      assert chunk.text == "Final answer"
    end

    test "marks builtin output item starts for stream server timing", %{model: model} do
      event = %{
        data: %{
          "event" => "response.output_item.added",
          "output_index" => 0,
          "item" => %{
            "id" => "ws_1",
            "type" => "web_search_call"
          }
        }
      }

      assert [%ReqLLM.StreamChunk{type: :meta, metadata: metadata}] =
               ResponsesAPI.decode_stream_event(event, model)

      assert metadata.builtin_tool_started.id == "ws_1"
      assert metadata.builtin_tool_started.name == "web_search_call"
      assert metadata.builtin_tool_started.index == 0
      assert is_integer(metadata.builtin_tool_started.started_at_unix_nano)
    end

    test "marks builtin output item completions for stream server timing", %{model: model} do
      event = %{
        data: %{
          "event" => "response.output_item.done",
          "output_index" => 0,
          "item" => %{
            "id" => "ws_1",
            "type" => "web_search_call",
            "action" => %{"query" => "elixir telemetry"},
            "status" => "completed"
          }
        }
      }

      assert [%ReqLLM.StreamChunk{type: :tool_call} = chunk] =
               ResponsesAPI.decode_stream_event(event, model)

      assert chunk.name == "web_search_call"
      assert chunk.arguments == %{"action" => %{"query" => "elixir telemetry"}}
      assert chunk.metadata.id == "ws_1"
      assert chunk.metadata.builtin? == true
      assert is_integer(chunk.metadata.done_at_unix_nano)
    end

    test "decodes atom-keyed builtin output item events", %{model: model} do
      added = %{
        event: "response.output_item.added",
        data: %{
          output_index: 0,
          item: %{
            id: "ws_1",
            type: "web_search_call"
          }
        }
      }

      done = %{
        event: "response.output_item.done",
        data: %{
          output_index: 0,
          item: %{
            id: "ws_1",
            type: "web_search_call",
            action: %{"query" => "elixir telemetry"},
            status: "completed"
          }
        }
      }

      assert [%ReqLLM.StreamChunk{type: :meta, metadata: start_meta}] =
               ResponsesAPI.decode_stream_event(added, model)

      assert start_meta.builtin_tool_started.id == "ws_1"

      assert [%ReqLLM.StreamChunk{type: :tool_call} = chunk] =
               ResponsesAPI.decode_stream_event(done, model)

      assert chunk.arguments == %{action: %{"query" => "elixir telemetry"}}
      assert chunk.metadata.id == "ws_1"
      assert chunk.metadata.builtin? == true
      assert is_integer(chunk.metadata.done_at_unix_nano)
    end

    test "emits code_interpreter items from output_item.added", %{model: model} do
      event = %{
        data: %{
          "event" => "response.output_item.added",
          "output_index" => 0,
          "item" => %{
            "id" => "ci_xxx",
            "type" => "code_interpreter_call",
            "code" => "print(2+2)",
            "status" => "in_progress"
          }
        }
      }

      assert [%ReqLLM.StreamChunk{type: :meta, metadata: metadata}] =
               ResponsesAPI.decode_stream_event(event, model)

      assert metadata.code_interpreter_item["type"] == "code_interpreter_call"
      assert metadata.code_interpreter_item["id"] == "ci_xxx"
    end

    test "emits code_interpreter items from output_item.done", %{model: model} do
      event = %{
        data: %{
          "event" => "response.output_item.done",
          "output_index" => 0,
          "item" => %{
            "type" => "code_interpreter_logs",
            "call_id" => "ci_xxx",
            "logs" => "4\n"
          }
        }
      }

      assert [%ReqLLM.StreamChunk{type: :meta, metadata: metadata}] =
               ResponsesAPI.decode_stream_event(event, model)

      assert metadata.code_interpreter_item["type"] == "code_interpreter_logs"
      assert metadata.code_interpreter_item["logs"] == "4\n"
    end

    test "collects code_interpreter items in response.completed provider_meta", %{model: model} do
      completed = %{
        data: %{
          "event" => "response.completed",
          "response" => %{
            "id" => "resp_123",
            "output" => [
              %{
                "type" => "code_interpreter_call",
                "id" => "ci_xxx",
                "code" => "print(2+2)",
                "status" => "completed"
              },
              %{
                "type" => "code_interpreter_logs",
                "call_id" => "ci_xxx",
                "logs" => "4\n"
              }
            ]
          }
        }
      }

      assert [%ReqLLM.StreamChunk{type: :meta, metadata: metadata}] =
               ResponsesAPI.decode_stream_event(completed, model)

      assert metadata.terminal? == true
      assert [call, logs] = get_in(metadata.provider_meta, ["code_interpreter", "items"])
      assert call["type"] == "code_interpreter_call"
      assert logs["type"] == "code_interpreter_logs"
    end

    test "stateful decoding avoids duplicate completed output items", %{model: model} do
      added = %{
        data: %{
          "event" => "response.output_item.added",
          "output_index" => 0,
          "item" => %{
            "type" => "function_call",
            "call_id" => "call_123",
            "name" => "get_weather"
          }
        }
      }

      delta = %{
        data: %{
          "event" => "response.function_call_arguments.delta",
          "output_index" => 0,
          "delta" => ~s({"location":"SF"})
        }
      }

      done = %{
        data: %{
          "event" => "response.output_item.done",
          "output_index" => 0,
          "item" => %{
            "type" => "function_call",
            "call_id" => "call_123",
            "name" => "get_weather",
            "arguments" => ~s({"location":"SF"})
          }
        }
      }

      {added_chunks, state} = ResponsesAPI.decode_stream_event(added, model, nil)
      {delta_chunks, state} = ResponsesAPI.decode_stream_event(delta, model, state)
      {done_chunks, _state} = ResponsesAPI.decode_stream_event(done, model, state)

      assert [%ReqLLM.StreamChunk{type: :tool_call}] = added_chunks
      assert [%ReqLLM.StreamChunk{type: :meta}] = delta_chunks
      assert done_chunks == []
    end

    test "empty text deltas do not suppress completed message output items", %{model: model} do
      delta = %{
        data: %{
          "event" => "response.output_text.delta",
          "output_index" => 0,
          "delta" => ""
        }
      }

      done = %{
        data: %{
          "event" => "response.output_item.done",
          "output_index" => 0,
          "item" => %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "Final answer"}]
          }
        }
      }

      {delta_chunks, state} = ResponsesAPI.decode_stream_event(delta, model, nil)
      {done_chunks, _state} = ResponsesAPI.decode_stream_event(done, model, state)

      assert delta_chunks == []
      assert [%ReqLLM.StreamChunk{type: :content, text: "Final answer"}] = done_chunks
    end

    test "decodes completed event", %{model: model} do
      event = %{data: %{"event" => "response.completed"}}

      assert [chunk] = ResponsesAPI.decode_stream_event(event, model)
      assert chunk.type == :meta
      assert chunk.metadata.terminal? == true
      assert chunk.metadata.finish_reason == :stop
    end

    test "extracts phase metadata from completed event output items", %{model: model} do
      event = %{
        data: %{
          "event" => "response.completed",
          "response" => %{
            "id" => "resp_123",
            "output" => [
              %{
                "type" => "message",
                "phase" => "commentary",
                "content" => [%{"type" => "output_text", "text" => "Inspecting logs. "}]
              },
              %{
                "type" => "message",
                "phase" => "final_answer",
                "content" => [%{"type" => "output_text", "text" => "Cache race confirmed."}]
              }
            ]
          }
        }
      }

      assert [chunk] = ResponsesAPI.decode_stream_event(event, model)
      assert chunk.type == :meta
      assert chunk.metadata.response_id == "resp_123"

      assert chunk.metadata.phase_items == [
               %{
                 "phase" => "commentary",
                 "content" => [%{"type" => "output_text", "text" => "Inspecting logs. "}]
               },
               %{
                 "phase" => "final_answer",
                 "content" => [%{"type" => "output_text", "text" => "Cache race confirmed."}]
               }
             ]
    end

    test "extracts encrypted reasoning details from completed event output items", %{model: model} do
      event = %{
        data: %{
          "event" => "response.completed",
          "response" => %{
            "id" => "resp_123",
            "output" => [
              %{
                "id" => "rs_123",
                "type" => "reasoning",
                "summary" => [%{"type" => "summary_text", "text" => "Checked constraints."}],
                "encrypted_content" => "encrypted_reasoning_payload"
              },
              %{
                "type" => "message",
                "content" => [%{"type" => "output_text", "text" => "OK"}]
              }
            ]
          }
        }
      }

      assert [chunk] = ResponsesAPI.decode_stream_event(event, model)
      assert chunk.type == :meta
      assert [detail] = chunk.metadata.reasoning_details
      assert detail.text == "Checked constraints."
      assert detail.signature == "encrypted_reasoning_payload"
      assert detail.encrypted? == true
      assert detail.provider == :openai
      assert detail.format == "openai-responses-v1"
      assert detail.index == 0
      assert detail.provider_data == %{"id" => "rs_123", "type" => "reasoning"}
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

  describe "attach_websocket_stream/3" do
    test "builds websocket create event from standard responses request body" do
      original_key = System.get_env("OPENAI_API_KEY")
      System.put_env("OPENAI_API_KEY", "test-key-12345")

      on_exit(fn ->
        if original_key do
          System.put_env("OPENAI_API_KEY", original_key)
        else
          System.delete_env("OPENAI_API_KEY")
        end
      end)

      {:ok, model} = ReqLLM.model("openai:gpt-5")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Say hello")])

      {:ok, config} =
        ResponsesAPI.attach_websocket_stream(
          model,
          context,
          base_url: "http://localhost:4010/v1",
          provider_options: []
        )

      assert config.url == "ws://localhost:4010/v1/responses"
      assert [{"Authorization", "Bearer test-key-12345"}] = config.headers
      assert %ReqLLM.Streaming.Fixtures.HTTPContext{} = config.http_context
      assert config.canonical_json["model"] == "gpt-5"
      refute Map.has_key?(config.canonical_json, "stream")

      [message] = config.initial_messages
      payload = Jason.decode!(message)

      assert payload["type"] == "response.create"
      assert payload["response"] == config.canonical_json
    end

    test "keeps previous_response_id with store false over websocket transport" do
      original_key = System.get_env("OPENAI_API_KEY")
      System.put_env("OPENAI_API_KEY", "test-key-12345")

      on_exit(fn ->
        if original_key do
          System.put_env("OPENAI_API_KEY", original_key)
        else
          System.delete_env("OPENAI_API_KEY")
        end
      end)

      {:ok, model} = ReqLLM.model("openai:gpt-5")

      assistant_msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Previous answer"}],
        metadata: %{response_id: "resp_ws_123"}
      }

      user_msg = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Follow up"}]
      }

      context = %ReqLLM.Context{messages: [assistant_msg, user_msg]}

      {:ok, config} =
        ResponsesAPI.attach_websocket_stream(
          model,
          context,
          base_url: "http://localhost:4010/v1",
          provider_options: [store: false]
        )

      assert config.canonical_json["previous_response_id"] == "resp_ws_123"
      assert config.canonical_json["store"] == false
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
      body = ReqLLM.Test.Helpers.json_body(encoded)

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
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["previous_response_id"] == "resp_prev_123"

      refute Enum.any?(body["input"], fn item ->
               item["type"] == "reasoning"
             end)
    end

    test "store: false suppresses previous_response_id outside websocket transport" do
      assistant_msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Previous answer"}],
        metadata: %{response_id: "resp_prev_123"}
      }

      user_msg = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Follow up"}]
      }

      context = %ReqLLM.Context{messages: [assistant_msg, user_msg]}
      request = build_request(context: context, provider_options: [store: false])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      refute Map.has_key?(body, "previous_response_id")
      assert body["store"] == false
    end

    test "explicit previous_response_id provider option is suppressed with store: false outside websocket transport" do
      user_msg = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Follow up"}]
      }

      context = %ReqLLM.Context{messages: [user_msg]}

      request =
        build_request(
          context: context,
          provider_options: [store: false, previous_response_id: "resp_x"]
        )

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      refute Map.has_key?(body, "previous_response_id")
      assert body["store"] == false
    end

    test "store: true (default) preserves previous_response_id behavior" do
      assistant_msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Previous answer"}],
        metadata: %{response_id: "resp_prev_456"}
      }

      user_msg = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Follow up"}]
      }

      context = %ReqLLM.Context{messages: [assistant_msg, user_msg]}
      request = build_request(context: context)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["previous_response_id"] == "resp_prev_456"
      assert body["store"] == true
    end

    test "websocket transport with codex models defaults store to false but still chains via previous_response_id" do
      assistant_msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Previous answer"}],
        metadata: %{response_id: "resp_prev_codex"}
      }

      user_msg = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Follow up"}]
      }

      context = %ReqLLM.Context{messages: [assistant_msg, user_msg]}

      request =
        build_request(
          id: "gpt-5.3-codex",
          context: context,
          responses_transport: :websocket
        )

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["previous_response_id"] == "resp_prev_codex"
      assert body["store"] == false
    end

    test "store: false without prior response_id omits both fields" do
      user_msg = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Hello"}]
      }

      context = %ReqLLM.Context{messages: [user_msg]}
      request = build_request(context: context, provider_options: [store: false])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      refute Map.has_key?(body, "previous_response_id")
      assert body["store"] == false
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
          body = ReqLLM.Test.Helpers.json_body(encoded)

          refute Enum.any?(body["input"], fn item ->
                   item["type"] == "reasoning"
                 end)
        end)

      assert log =~ "Skipping reasoning detail from provider :anthropic for :openai request"
    end

    test "does not replay Meta reasoning details into OpenAI requests" do
      meta_detail = %ReqLLM.Message.ReasoningDetails{
        text: "Meta reasoning",
        signature: "meta_encrypted_reasoning",
        encrypted?: true,
        provider: :meta,
        format: "openai-responses-v1",
        index: 0,
        provider_data: %{"id" => "rs_meta_1", "type" => "reasoning"}
      }

      assistant_msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Response"}],
        reasoning_details: [meta_detail]
      }

      context = %ReqLLM.Context{messages: [assistant_msg]}

      body =
        build_request(context: context)
        |> ResponsesAPI.encode_body()
        |> ReqLLM.Test.Helpers.json_body()

      refute Enum.any?(body["input"], &(&1["type"] == "reasoning"))
    end

    test "encodes summary from reasoning detail text" do
      reasoning_detail = %ReqLLM.Message.ReasoningDetails{
        text: "I need to think about this carefully",
        signature: "encrypted_sig_abc",
        encrypted?: true,
        provider: :openai,
        format: "openai-responses-v1",
        index: 0,
        provider_data: %{"id" => "rs_prev123", "type" => "reasoning"}
      }

      assistant_msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Answer"}],
        reasoning_details: [reasoning_detail]
      }

      user_msg = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Follow up"}]
      }

      context = %ReqLLM.Context{messages: [assistant_msg, user_msg]}
      request = build_request(context: context)

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      [reasoning_input | _] = body["input"]
      assert reasoning_input["type"] == "reasoning"

      assert reasoning_input["summary"] == [
               %{"type" => "summary_text", "text" => "I need to think about this carefully"}
             ]
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
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert [reasoning_input | _rest] = body["input"]
      assert reasoning_input["type"] == "reasoning"
      assert reasoning_input["encrypted_content"] == "sig_123"
      refute Map.has_key?(reasoning_input, "id")
    end
  end

  describe "phase replay - encode_body/1" do
    test "includes phase when assistant metadata has a single phase" do
      assistant_msg = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Root cause found"}],
        metadata: %{phase: "final_answer", response_id: "resp_prev_123"}
      }

      user_msg = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Continue"}]
      }

      context = %ReqLLM.Context{messages: [assistant_msg, user_msg]}
      request = build_request(context: context, provider_options: [store: false])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert Enum.at(body["input"], 0) == %{
               "role" => "assistant",
               "phase" => "final_answer",
               "content" => [%{"type" => "output_text", "text" => "Root cause found"}]
             }
    end

    test "replays ordered phase_items from assistant metadata" do
      assistant_msg = %ReqLLM.Message{
        role: :assistant,
        content: [
          %ReqLLM.Message.ContentPart{
            type: :text,
            text: "Inspecting logs. Cache race confirmed."
          }
        ],
        metadata: %{
          phase_items: [
            %{
              "phase" => "commentary",
              "content" => [%{"type" => "output_text", "text" => "Inspecting logs. "}]
            },
            %{
              "phase" => "final_answer",
              "content" => [%{"type" => "output_text", "text" => "Cache race confirmed."}]
            }
          ]
        }
      }

      user_msg = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Continue"}]
      }

      context = %ReqLLM.Context{messages: [assistant_msg, user_msg]}
      request = build_request(context: context, provider_options: [store: false])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert Enum.take(body["input"], 2) == [
               %{
                 "role" => "assistant",
                 "phase" => "commentary",
                 "content" => [%{"type" => "output_text", "text" => "Inspecting logs. "}]
               },
               %{
                 "role" => "assistant",
                 "phase" => "final_answer",
                 "content" => [%{"type" => "output_text", "text" => "Cache race confirmed."}]
               }
             ]
    end

    test "round-trips phased output through decode and encode" do
      response_body = %{
        "id" => "resp_123",
        "model" => "gpt-5.4",
        "output" => [
          %{
            "type" => "message",
            "phase" => "commentary",
            "content" => [%{"type" => "output_text", "text" => "Inspecting logs. "}]
          },
          %{
            "type" => "message",
            "phase" => "final_answer",
            "content" => [%{"type" => "output_text", "text" => "Cache race confirmed."}]
          }
        ],
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {_req, decoded_resp} = ResponsesAPI.decode_response(build_response(200, response_body))

      request =
        build_request(context: decoded_resp.body.context, provider_options: [store: false])

      encoded = ResponsesAPI.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["input"] == [
               %{
                 "role" => "assistant",
                 "phase" => "commentary",
                 "content" => [%{"type" => "output_text", "text" => "Inspecting logs. "}]
               },
               %{
                 "role" => "assistant",
                 "phase" => "final_answer",
                 "content" => [%{"type" => "output_text", "text" => "Cache race confirmed."}]
               }
             ]
    end
  end

  defp build_request(opts) do
    context = Keyword.get(opts, :context, %ReqLLM.Context{messages: []})
    provider_opts = Keyword.get(opts, :provider_options, [])

    provider_opts =
      case Keyword.get(opts, :reasoning_summary) do
        nil -> provider_opts
        summary -> Keyword.put(provider_opts, :reasoning_summary, summary)
      end

    req_opts =
      %{
        id: Keyword.get(opts, :id, "gpt-5"),
        context: context,
        stream: Keyword.get(opts, :stream),
        max_output_tokens: Keyword.get(opts, :max_output_tokens),
        max_completion_tokens: Keyword.get(opts, :max_completion_tokens),
        max_tokens: Keyword.get(opts, :max_tokens),
        tools: Keyword.get(opts, :tools),
        tool_choice: Keyword.get(opts, :tool_choice),
        parallel_tool_calls: Keyword.get(opts, :parallel_tool_calls),
        reasoning_effort: Keyword.get(opts, :reasoning_effort),
        provider_options: provider_opts
      }
      |> maybe_put_responses_transport(Keyword.get(opts, :responses_transport))

    %Req.Request{
      method: :post,
      url: URI.parse("https://api.openai.com/v1/responses"),
      headers: %{},
      body: {:json, %{}},
      options: req_opts
    }
  end

  defp maybe_put_responses_transport(opts, nil), do: opts

  defp maybe_put_responses_transport(opts, transport),
    do: Map.put(opts, :responses_transport, transport)

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

    test "upgrades stop finish reason to tool_calls when tool chunks are present" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.tool_call("get_weather", %{"city" => "SF"}),
        ReqLLM.StreamChunk.text("Calling a tool")
      ]

      {:ok, response} =
        ResponseBuilder.build_response(
          chunks,
          %{finish_reason: :stop},
          context: context,
          model: model
        )

      assert response.finish_reason == :tool_calls
      assert [%ReqLLM.ToolCall{function: %{name: "get_weather"}}] = response.message.tool_calls
    end

    test "preserves stop finish reason when only builtin tool chunks are present" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.tool_call("web_search_call", %{"query" => "docs"}, %{
          id: "ws_1",
          builtin?: true
        })
      ]

      {:ok, response} =
        ResponseBuilder.build_response(
          chunks,
          %{finish_reason: :stop},
          context: context,
          model: model
        )

      assert response.finish_reason == :stop
      assert [%ReqLLM.ToolCall{} = tool_call] = response.message.tool_calls
      assert ReqLLM.ToolCall.builtin?(tool_call)
    end

    test "upgrades string stop finish reason to tool_calls when tool chunks are present" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.tool_call("search", %{"query" => "docs"})
      ]

      {:ok, response} =
        ResponseBuilder.build_response(
          chunks,
          %{finish_reason: "stop"},
          context: context,
          model: model
        )

      assert response.finish_reason == :tool_calls
    end

    test "preserves non-stop finish reason when tool chunks are present" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.tool_call("search", %{"query" => "docs"})
      ]

      {:ok, response} =
        ResponseBuilder.build_response(
          chunks,
          %{finish_reason: :length},
          context: context,
          model: model
        )

      assert response.finish_reason == :length
    end

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

    test "propagates phase replay metadata to message metadata" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.text("Inspecting logs. Cache race confirmed.")
      ]

      metadata = %{
        finish_reason: :stop,
        response_id: "resp_abc123",
        phase_items: [
          %{
            "phase" => "commentary",
            "content" => [%{"type" => "output_text", "text" => "Inspecting logs. "}]
          },
          %{
            "phase" => "final_answer",
            "content" => [%{"type" => "output_text", "text" => "Cache race confirmed."}]
          }
        ]
      }

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.metadata[:response_id] == "resp_abc123"

      assert response.message.metadata[:phase_items] == [
               %{
                 "phase" => "commentary",
                 "content" => [%{"type" => "output_text", "text" => "Inspecting logs. "}]
               },
               %{
                 "phase" => "final_answer",
                 "content" => [%{"type" => "output_text", "text" => "Cache race confirmed."}]
               }
             ]
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

    test "leaves message metadata unchanged when response_id is absent" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.text("No response id")
      ]

      {:ok, response} =
        ResponseBuilder.build_response(
          chunks,
          %{finish_reason: :stop},
          context: context,
          model: model
        )

      assert response.message.metadata == %{}
    end
  end
end

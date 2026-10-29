defmodule ReqLLM.Providers.Google.ToolsTest do
  @moduledoc """
  Google function calling, tool schema encoding, and tool result payloads.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Google, async: true

  alias ReqLLM.Context
  alias ReqLLM.Providers.Google

  describe "validated function calling" do
    setup do
      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get the weather in a city",
          parameter_schema: [city: [type: :string, required: true]],
          callback: fn _ -> {:ok, "sunny"} end
        )

      {:ok, model: ReqLLM.model!("google:gemini-2.5-flash"), tools: [tool]}
    end

    for tool_choice <- [:validated, "validated"] do
      test "serializes #{inspect(tool_choice)} for non-streaming requests", %{
        model: model,
        tools: tools
      } do
        assert {:ok, request} =
                 Google.prepare_request(:chat, model, "Weather in Madrid?",
                   tools: tools,
                   tool_choice: unquote(tool_choice),
                   api_key: "test"
                 )

        body = request |> Google.encode_body() |> ReqLLM.Test.Helpers.json_body()

        assert body["toolConfig"] == %{"functionCallingConfig" => %{"mode" => "VALIDATED"}}
        assert [%{"functionDeclarations" => [%{"name" => "get_weather"}]}] = body["tools"]
      end

      test "serializes #{inspect(tool_choice)} for streaming requests", %{
        model: model,
        tools: tools
      } do
        context = Context.new([Context.user("Weather in Madrid?")])

        assert {:ok, request} =
                 Google.attach_stream(
                   model,
                   context,
                   [tools: tools, tool_choice: unquote(tool_choice), api_key: "test"],
                   nil
                 )

        body = Jason.decode!(request.body)

        assert body["toolConfig"] == %{"functionCallingConfig" => %{"mode" => "VALIDATED"}}
        assert [%{"functionDeclarations" => [%{"name" => "get_weather"}]}] = body["tools"]
      end
    end
  end

  describe "body encoding & context translation" do
    test "encode_body with tools but no tool_choice" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "A test tool",
          parameter_schema: [
            name: [type: :string, required: true, doc: "A name parameter"]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool],
          operation: :chat
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert is_list(decoded["tools"])
      assert length(decoded["tools"]) == 1

      [tool_def] = decoded["tools"]
      assert Map.has_key?(tool_def, "functionDeclarations")
      assert is_list(tool_def["functionDeclarations"])
    end

    test "encode_body strips atom-keyed forbidden fields from tool schemas" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "register_company",
          description: "Register company",
          parameter_schema: %{
            :type => :object,
            :required => [:company],
            :properties => %{
              :company => %{
                :type => :object,
                :required => [:name, :address],
                :properties => %{
                  :name => %{type: :string},
                  :address => %{
                    :type => :object,
                    :required => [:city],
                    :properties => %{city: %{type: :string}},
                    :additionalProperties => false
                  }
                },
                :additionalProperties => false
              }
            },
            :additionalProperties => false,
            :"$schema" => "https://json-schema.org/draft/2020-12/schema"
          },
          callback: fn _ -> {:ok, %{}} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool],
          operation: :chat
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)
      [tool_def] = decoded["tools"]
      [function_def] = tool_def["functionDeclarations"]
      parameters = function_def["parameters"]
      company = parameters["properties"]["company"]
      address = company["properties"]["address"]

      refute Map.has_key?(parameters, "$schema")
      refute Map.has_key?(parameters, "additionalProperties")
      refute Map.has_key?(company, "additionalProperties")
      refute Map.has_key?(address, "additionalProperties")
    end

    test "encode_body with empty tools list and tool_choice omits toolConfig" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()

      # Create a mock request mimicking Jido AI's default behavior
      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [],
          tool_choice: :auto,
          operation: :chat
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      # Ensure both tools and toolConfig are completely omitted when tools is empty
      refute Map.has_key?(decoded, "tools"), "tools array should be omitted"

      refute Map.has_key?(decoded, "toolConfig"),
             "toolConfig should not be attached if there are no tools"
    end

    test "encode_body includes tool_result name and structured response" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

      tool_result =
        Context.tool_result_message(
          "get_weather",
          "call_1",
          %ReqLLM.ToolResult{output: %{"temperature" => 72}}
        )

      context =
        Context.new([
          Context.user("What's the weather?"),
          Context.assistant("",
            tool_calls: [
              %ReqLLM.ToolCall{
                id: "call_1",
                type: "function",
                function: %{name: "get_weather", arguments: ~s({"location":"SF"})}
              }
            ]
          ),
          tool_result
        ])

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          operation: :chat
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      tool_parts =
        decoded["contents"]
        |> Enum.flat_map(& &1["parts"])
        |> Enum.filter(&Map.has_key?(&1, "functionResponse"))

      [tool_part] = tool_parts
      function_response = tool_part["functionResponse"]
      assert function_response["name"] == "get_weather"
      assert function_response["response"]["temperature"] == 72
    end

    test "encode_body emits text tool results only inside functionResponse" do
      {:ok, model} = ReqLLM.model("google:gemini-2.5-flash-lite")

      context =
        Context.new([
          Context.user("Check NPI 1234567890."),
          Context.assistant("",
            tool_calls: [
              %ReqLLM.ToolCall{
                id: "call_1",
                type: "function",
                function: %{name: "lookup_npi", arguments: ~s({"npi":"1234567890"})}
              }
            ]
          ),
          Context.tool_result(
            "call_1",
            "lookup_npi",
            "NPI 1234567890 is valid and active"
          )
        ])

      request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          operation: :chat
        ]
      }

      decoded = request |> Google.encode_body() |> ReqLLM.Test.Helpers.json_body()

      tool_result_entry =
        Enum.find(decoded["contents"], fn entry ->
          Enum.any?(entry["parts"], &Map.has_key?(&1, "functionResponse"))
        end)

      assert tool_result_entry["parts"] == [
               %{
                 "functionResponse" => %{
                   "name" => "lookup_npi",
                   "response" => %{"content" => "NPI 1234567890 is valid and active"}
                 }
               }
             ]
    end

    test "encode_body preserves video_url media in raw tool result messages" do
      video_url = "https://example.com/tool-result.mp4"

      messages = [
        %{
          "role" => "tool",
          "name" => "inspect_video",
          "tool_call_id" => "call_1",
          "content" => [
            %{"type" => "text", "text" => "The video shows a blue car."},
            %{"type" => "video_url", "video_url" => %{"url" => video_url}}
          ]
        }
      ]

      encode_for_model = fn model_id ->
        {:ok, model} = ReqLLM.model("google:#{model_id}")

        %Req.Request{
          options: [
            messages: messages,
            model: model.model,
            stream: false,
            operation: :chat
          ]
        }
        |> Google.encode_body()
        |> ReqLLM.Test.Helpers.json_body()
      end

      gemini_2_5_body = encode_for_model.("gemini-2.5-flash-lite")

      assert [%{"parts" => parts}] = gemini_2_5_body["contents"]

      assert parts == [
               %{
                 "fileData" => %{
                   "fileUri" => video_url,
                   "mimeType" => "video/mp4"
                 }
               },
               %{
                 "functionResponse" => %{
                   "name" => "inspect_video",
                   "response" => %{"content" => "The video shows a blue car."}
                 }
               }
             ]

      gemini_3_body = encode_for_model.("gemini-3-pro-preview")

      assert [%{"parts" => [%{"functionResponse" => function_response}]}] =
               gemini_3_body["contents"]

      assert function_response["response"] == %{
               "content" => "The video shows a blue car."
             }

      assert function_response["parts"] == [
               %{
                 "fileData" => %{
                   "fileUri" => video_url,
                   "mimeType" => "video/mp4"
                 }
               }
             ]
    end

    test "encode_body prefers explicit model-facing content over application output" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

      tool_result =
        Context.tool_result(
          "call_1",
          "search_documents",
          %ReqLLM.ToolResult{
            output: %{records: [%{id: 1}], internal_cursor: "cursor_123"},
            content: [ReqLLM.Message.ContentPart.text("One matching document was found.")]
          }
        )

      context = Context.new([tool_result])

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          operation: :chat
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [tool_part] =
        decoded["contents"]
        |> Enum.flat_map(& &1["parts"])
        |> Enum.filter(&Map.has_key?(&1, "functionResponse"))

      assert tool_part["functionResponse"]["response"] == %{
               "content" => "One matching document was found."
             }
    end

    test "encode_body nests file content in functionResponse.parts for Gemini 3+" do
      {:ok, model} = ReqLLM.model("google:gemini-3-pro-preview")

      pdf_bytes = <<37, 80, 68, 70, 1, 2, 3>>

      tool_result = %ReqLLM.Message{
        role: :tool,
        name: "extract_pdf",
        tool_call_id: "call_1",
        content: [
          ReqLLM.Message.ContentPart.text("Here is the file:"),
          ReqLLM.Message.ContentPart.file(pdf_bytes, "doc.pdf", "application/pdf")
        ],
        metadata: %{}
      }

      context =
        Context.new([
          Context.user("Summarise this PDF."),
          Context.assistant("",
            tool_calls: [
              %ReqLLM.ToolCall{
                id: "call_1",
                type: "function",
                function: %{name: "extract_pdf", arguments: ~s({"path":"doc.pdf"})}
              }
            ]
          ),
          tool_result
        ])

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          operation: :chat
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      tool_user_msg =
        decoded["contents"]
        |> Enum.find(fn entry ->
          entry["role"] == "user" and
            Enum.any?(entry["parts"], &Map.has_key?(&1, "functionResponse"))
        end)

      assert tool_user_msg, "expected a user message carrying functionResponse"

      function_response_parts =
        Enum.filter(tool_user_msg["parts"], &Map.has_key?(&1, "functionResponse"))

      assert [function_response_part] = function_response_parts

      function_response = function_response_part["functionResponse"]
      assert function_response["name"] == "extract_pdf"

      assert is_list(function_response["parts"]),
             "functionResponse must carry a nested parts array on Gemini 3+"

      assert Enum.any?(function_response["parts"], fn
               %{"inline_data" => %{"mime_type" => "application/pdf", "data" => data}} ->
                 Base.decode64!(data) == pdf_bytes

               _ ->
                 false
             end),
             "PDF payload must live inside functionResponse.parts"

      refute Enum.any?(tool_user_msg["parts"], &Map.has_key?(&1, "inline_data")),
             "PDF must not be emitted as a sibling inline_data part on Gemini 3+"

      assert function_response["response"]["content"] =~ "Here is the file:",
             "accompanying text must survive into functionResponse.response.content"
    end

    test "encode_body keeps legacy shape for Gemini 2.5 multimodal tool results" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

      pdf_bytes = <<37, 80, 68, 70, 1, 2, 3>>

      tool_result = %ReqLLM.Message{
        role: :tool,
        name: "extract_pdf",
        tool_call_id: "call_1",
        content: [
          ReqLLM.Message.ContentPart.text("Here is the file:"),
          ReqLLM.Message.ContentPart.file(pdf_bytes, "doc.pdf", "application/pdf")
        ],
        metadata: %{}
      }

      context =
        Context.new([
          Context.user("Summarise this PDF."),
          Context.assistant("",
            tool_calls: [
              %ReqLLM.ToolCall{
                id: "call_1",
                type: "function",
                function: %{name: "extract_pdf", arguments: ~s({"path":"doc.pdf"})}
              }
            ]
          ),
          tool_result
        ])

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          operation: :chat
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      tool_user_msg =
        decoded["contents"]
        |> Enum.find(fn entry ->
          entry["role"] == "user" and
            Enum.any?(entry["parts"], &Map.has_key?(&1, "functionResponse"))
        end)

      assert tool_user_msg

      function_response_parts =
        Enum.filter(tool_user_msg["parts"], &Map.has_key?(&1, "functionResponse"))

      assert [function_response_part] = function_response_parts

      refute Map.has_key?(function_response_part["functionResponse"], "parts"),
             "Gemini 2.5 must not emit functionResponse.parts"

      assert Enum.any?(tool_user_msg["parts"], fn
               %{"inline_data" => %{"mime_type" => "application/pdf"}} -> true
               _ -> false
             end),
             "Gemini 2.5 must keep the file as a sibling inline_data part (legacy behavior)"

      refute Enum.any?(tool_user_msg["parts"], &Map.has_key?(&1, "text")),
             "tool result text must only appear in functionResponse.response"
    end

    test "encode_body keeps text-only tool results inside functionResponse on Gemini 3+" do
      {:ok, model} = ReqLLM.model("google:gemini-3-pro-preview")

      tool_result = %ReqLLM.Message{
        role: :tool,
        name: "get_weather",
        tool_call_id: "call_1",
        content: [ReqLLM.Message.ContentPart.text("just text")],
        metadata: %{}
      }

      context =
        Context.new([
          Context.user("Weather?"),
          Context.assistant("",
            tool_calls: [
              %ReqLLM.ToolCall{
                id: "call_1",
                type: "function",
                function: %{name: "get_weather", arguments: ~s({"location":"SF"})}
              }
            ]
          ),
          tool_result
        ])

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          operation: :chat
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      tool_user_msg =
        decoded["contents"]
        |> Enum.find(fn entry ->
          entry["role"] == "user" and
            Enum.any?(entry["parts"], &Map.has_key?(&1, "functionResponse"))
        end)

      assert tool_user_msg

      [function_response_part] =
        Enum.filter(tool_user_msg["parts"], &Map.has_key?(&1, "functionResponse"))

      refute Map.has_key?(function_response_part["functionResponse"], "parts"),
             "text-only tool results must not gain a functionResponse.parts field"

      assert function_response_part["functionResponse"]["response"] == %{
               "content" => "just text"
             }

      refute Enum.any?(tool_user_msg["parts"], &Map.has_key?(&1, "text")),
             "tool result text must only appear in functionResponse.response"
    end

    test "encode_body excludes id from functionCall parts" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

      context =
        Context.new([
          Context.user("What's the weather?"),
          Context.assistant("",
            tool_calls: [
              %ReqLLM.ToolCall{
                id: "call_1",
                type: "function",
                function: %{name: "get_weather", arguments: ~s({"location":"SF"})}
              }
            ]
          )
        ])

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          operation: :chat
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      function_call_parts =
        decoded["contents"]
        |> Enum.flat_map(& &1["parts"])
        |> Enum.filter(&Map.has_key?(&1, "functionCall"))

      assert [function_call_part] = function_call_parts
      assert function_call_part["functionCall"]["name"] == "get_weather"
      assert function_call_part["functionCall"]["args"] == %{"location" => "SF"}

      refute Map.has_key?(function_call_part["functionCall"], "id"),
             "functionCall must not include 'id' — Google API rejects unknown fields"
    end
  end
end

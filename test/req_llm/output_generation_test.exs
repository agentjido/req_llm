defmodule ReqLLM.OutputGenerationTest do
  use ExUnit.Case, async: true

  @moduletag contract: :public_api

  alias ReqLLM.Generation
  alias ReqLLM.Output
  alias ReqLLM.Response
  alias ReqLLM.StreamResponse
  alias ReqLLM.ToolCall

  @model %{
    provider: :openai,
    id: "gpt-4-turbo",
    extra: %{wire: %{protocol: "openai_chat"}}
  }

  describe "generate_text/3 output contracts" do
    test "omitted output and Output.text use the unchanged chat path" do
      stub = stub_text_response("Hello")

      assert {:ok, legacy_response} =
               Generation.generate_text(
                 @model,
                 "Hello",
                 req_http_options: [plug: {Req.Test, stub}]
               )

      assert {:ok, explicit_response} =
               Generation.generate_text(
                 @model,
                 "Hello",
                 output: Output.text(),
                 req_http_options: [plug: {Req.Test, stub}]
               )

      assert Response.text(legacy_response) == "Hello"
      assert Response.text(explicit_response) == "Hello"
      assert Response.output(explicit_response, Output.text()) == "Hello"

      assert Map.from_struct(legacy_response) |> Map.keys() |> Enum.sort() ==
               Map.from_struct(explicit_response) |> Map.keys() |> Enum.sort()
    end

    test "object output reuses the existing object operation and response shape" do
      output =
        Output.object(
          [name: [type: :string, required: true]],
          name: "person",
          description: "A generated person"
        )

      stub = stub_tool_response(%{"name" => "Ada"}, self())

      assert {:ok, response} =
               Generation.generate_text(
                 @model,
                 "Generate a person",
                 output: output,
                 openai_structured_output_mode: :tool_strict,
                 req_http_options: [plug: {Req.Test, stub}]
               )

      assert %Response{} = response
      assert response.object == %{"name" => "Ada"}
      assert Response.output(response, output) == %{"name" => "Ada"}
      assert response.usage.total_tokens == 14

      assert [%ToolCall{} = tool_call] = Response.tool_calls(response)
      assert ToolCall.args_map(tool_call) == %{"name" => "Ada"}

      assert_receive {:request_body, body}
      refute Map.has_key?(body, "output")
      structured_tool = Enum.find(body["tools"], &(&1["function"]["name"] == "structured_output"))
      assert structured_tool["function"]["parameters"]["description"] == "A generated person"

      assert structured_tool["function"]["parameters"]["properties"]["name"]["type"] ==
               "string"
    end

    test "prefers the provider-native structured output surface when available" do
      output = Output.object([name: [type: :string, required: true]], name: "person")
      stub = stub_native_object_response(%{"name" => "Ada"}, self())

      assert {:ok, response} =
               ReqLLM.generate_text(
                 "openai:gpt-4o-2024-08-06",
                 "Generate a person",
                 output: output,
                 req_http_options: [plug: {Req.Test, stub}]
               )

      assert Response.output(response, output) == %{"name" => "Ada"}
      assert Response.text(response) == ~s({"name":"Ada"})
      assert Response.tool_calls(response) == []
      assert response.provider_meta["api_type"] == "responses"

      assert_receive {:request_body, body}
      assert body["text"]["format"]["type"] == "json_schema"
      assert body["text"]["format"]["name"] == "person"
      refute Map.has_key?(body, "output")
      refute Map.has_key?(body, "tools")
    end

    test "array output projects the wrapped array while retaining raw arguments" do
      output = Output.array([name: [type: :string, required: true]], name: "people")
      value = [%{"name" => "Ada"}, %{"name" => "Grace"}]
      stub = stub_tool_response(%{"value" => value})

      assert {:ok, response} = generate_structured(output, stub)
      assert Response.output(response, output) == value
      assert response.object == %{"value" => value}

      assert [%ToolCall{} = tool_call] = Response.tool_calls(response)
      assert ToolCall.args_map(tool_call) == %{"value" => value}
    end

    test "choice output projects one string choice" do
      output = Output.choice(["sunny", "rainy", "snowy"])
      stub = stub_tool_response(%{"value" => "sunny"})

      assert {:ok, response} = generate_structured(output, stub)
      assert Response.output(response, output) == "sunny"
      assert response.object == %{"value" => "sunny"}
    end

    test "JSON output projects any JSON value" do
      output = Output.json(description: "Any JSON value")
      value = [1, %{"nested" => true}, nil]
      stub = stub_tool_response(%{"value" => value})

      assert {:ok, response} = generate_structured(output, stub)
      assert Response.output(response, output) == value
      assert response.object == %{"value" => value}
    end

    test "returns descriptor errors before making a request" do
      stub = {__MODULE__, make_ref()}

      Req.Test.stub(stub, fn _conn ->
        raise "HTTP request should not execute for an invalid output descriptor"
      end)

      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               Generation.generate_text(
                 @model,
                 "Hello",
                 output: %{type: :object},
                 req_http_options: [plug: {Req.Test, stub}]
               )

      assert message =~ "ReqLLM.Output descriptor"
    end
  end

  describe "stream_text/3 output contracts" do
    test "exposes unvalidated partial chunks and materializes the final projected value" do
      output = Output.array(name: [type: :string, required: true])
      stub = stub_tool_stream(%{"value" => [%{"name" => "Ada"}]})

      assert {:ok, partial_response} =
               ReqLLM.stream_text(
                 @model,
                 "Generate people",
                 output: output,
                 openai_structured_output_mode: :tool_strict,
                 req_http_options: [plug: {Req.Test, stub}]
               )

      chunks = Enum.to_list(partial_response.stream)

      assert %ReqLLM.StreamChunk{type: :tool_call, name: "structured_output"} =
               chunk = Enum.find(chunks, &(&1.type == :tool_call))

      assert chunk.arguments == %{}
      assert chunk.metadata.invalid_arguments == true

      assert Enum.any?(chunks, fn chunk ->
               chunk.type == :meta and
                 is_binary(get_in(chunk.metadata, [:tool_call_args, :fragment]))
             end)

      assert {:ok, final_stream} =
               ReqLLM.stream_text(
                 @model,
                 "Generate people",
                 output: output,
                 openai_structured_output_mode: :tool_strict,
                 req_http_options: [plug: {Req.Test, stub}]
               )

      assert {:ok, response} = StreamResponse.to_response(final_stream)
      value = Response.output(response, output)
      assert is_list(value)
      assert value != []
      assert Enum.all?(value, &is_binary(&1["name"]))
      assert response.object == %{"value" => value}
      assert [%ToolCall{}] = Response.tool_calls(response)
    end
  end

  defp generate_structured(output, stub) do
    Generation.generate_text(
      @model,
      "Generate structured data",
      output: output,
      openai_structured_output_mode: :tool_strict,
      req_http_options: [plug: {Req.Test, stub}]
    )
  end

  defp stub_text_response(text) do
    stub = {__MODULE__, make_ref()}

    Req.Test.stub(stub, fn conn ->
      Req.Test.json(conn, %{
        "id" => "cmpl_text_123",
        "model" => "gpt-4-turbo",
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => text}, "finish_reason" => "stop"}
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 1, "total_tokens" => 11}
      })
    end)

    stub
  end

  defp stub_tool_response(arguments, test_pid \\ nil) do
    stub = {__MODULE__, make_ref()}

    Req.Test.stub(stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      if test_pid do
        send(test_pid, {:request_body, Jason.decode!(body)})
      end

      Req.Test.json(conn, tool_response(arguments))
    end)

    stub
  end

  defp stub_native_object_response(object, test_pid) do
    stub = {__MODULE__, make_ref()}

    Req.Test.stub(stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "id" => "resp_object_123",
        "model" => "gpt-4o-2024-08-06",
        "status" => "completed",
        "output_text" => Jason.encode!(object),
        "usage" => %{"input_tokens" => 10, "output_tokens" => 4}
      })
    end)

    stub
  end

  defp stub_tool_stream(arguments) do
    stub = {__MODULE__, make_ref()}
    argument_json = Jason.encode!(arguments)

    delta = %{
      "id" => "chatcmpl-stream-123",
      "choices" => [
        %{
          "delta" => %{
            "role" => "assistant",
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => "call_123",
                "type" => "function",
                "function" => %{
                  "name" => "structured_output",
                  "arguments" => argument_json
                }
              }
            ]
          },
          "finish_reason" => nil
        }
      ]
    }

    finish = %{
      "id" => "chatcmpl-stream-123",
      "choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]
    }

    Req.Test.stub(stub, fn conn ->
      body =
        "data: #{Jason.encode!(delta)}\n\n" <>
          "data: #{Jason.encode!(finish)}\n\n" <>
          "data: [DONE]\n\n"

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)

    stub
  end

  defp tool_response(arguments) do
    %{
      "id" => "cmpl_object_123",
      "model" => "gpt-4-turbo",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "tool_calls" => [
              %{
                "id" => "call_123",
                "type" => "function",
                "function" => %{
                  "name" => "structured_output",
                  "arguments" => Jason.encode!(arguments)
                }
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 4, "total_tokens" => 14}
    }
  end
end

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
      assert legacy_response == explicit_response
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

    test "preserves existing native response validation for compiled schemas" do
      output =
        Output.object(
          [
            name: [type: :string, required: true],
            age: [type: :pos_integer, required: true]
          ],
          name: "person"
        )

      stub = stub_native_object_response(%{"name" => "Ada"}, self())

      assert {:ok, response} =
               ReqLLM.generate_text(
                 "openai:gpt-4o-2024-08-06",
                 "Generate a person",
                 output: output,
                 req_http_options: [plug: {Req.Test, stub}]
               )

      assert Response.output(response, output) == nil
      assert response.provider_meta[:object_parse_error] == :validation_failed
      assert_receive {:request_body, _body}
    end

    test "validates compiled array wrappers before projection" do
      output = Output.array([name: [type: :string, required: true]], name: "people")
      stub = stub_native_object_response(%{"value" => [%{"name" => 123}]}, self())

      assert {:ok, response} =
               ReqLLM.generate_text(
                 "openai:gpt-4o-2024-08-06",
                 "Generate people",
                 output: output,
                 req_http_options: [plug: {Req.Test, stub}]
               )

      assert Response.output(response, output) == nil
      assert response.provider_meta[:object_parse_error] == :validation_failed
      assert_receive {:request_body, _body}
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
      output =
        Output.object(
          [
            name: [type: :string, required: true],
            age: [type: :pos_integer, required: true],
            occupation: [type: :string, required: true]
          ],
          name: "person"
        )

      opts = [output: output, max_tokens: 500, fixture: "object_streaming"]

      assert {:ok, partial_response} =
               ReqLLM.stream_text(
                 "openai:gpt-4o-mini",
                 "Generate a software engineer profile",
                 opts
               )

      chunks = Enum.to_list(partial_response.stream)

      content_chunks = Enum.filter(chunks, &(&1.type == :content and is_binary(&1.text)))

      assert length(content_chunks) > 1
      assert Enum.any?(content_chunks, &match?({:error, _reason}, Jason.decode(&1.text)))
      streamed_json = content_chunks |> Enum.map_join(& &1.text) |> Jason.decode!()

      assert {:ok, final_stream} =
               ReqLLM.stream_text(
                 "openai:gpt-4o-mini",
                 "Generate a software engineer profile",
                 opts
               )

      assert {:ok, response} = StreamResponse.to_response(final_stream)
      value = Response.output(response, output)
      assert is_binary(value["name"])
      assert is_integer(value["age"])
      assert is_binary(value["occupation"])
      assert response.object == value
      assert streamed_json == value
      assert response.provider_meta["status"] == "completed"
      assert Response.tool_calls(response) == []
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

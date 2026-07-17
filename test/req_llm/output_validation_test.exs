defmodule ReqLLM.OutputValidationTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Generation
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Output
  alias ReqLLM.Output.Result
  alias ReqLLM.Output.Validation
  alias ReqLLM.Response
  alias ReqLLM.StreamResponse
  alias ReqLLM.ToolCall

  @moduletag contract: :public_api

  @model %{
    provider: :openai,
    id: "gpt-4-turbo",
    extra: %{wire: %{protocol: "openai_chat"}}
  }

  describe "Response.output_result/3" do
    test "validates every descriptor type locally" do
      object = Output.object(name: [type: :string, required: true])
      array = Output.array(name: [type: :string, required: true])
      choice = Output.choice(["sunny", "rainy"])

      assert %Result{valid?: true, value: "hello", errors: []} =
               Response.output_result(response(text: "hello"), Output.text())

      assert %Result{valid?: false, value: %{}, errors: [%{type: :schema_validation}]} =
               Response.output_result(response(object: %{}), object)

      assert %Result{valid?: true, value: [%{"name" => "Ada"}], errors: []} =
               Response.output_result(
                 response(object: %{"value" => [%{"name" => "Ada"}]}),
                 array
               )

      assert %Result{valid?: false, value: "snowy", errors: [%{type: :schema_validation}]} =
               Response.output_result(response(object: %{"value" => "snowy"}), choice)

      assert %Result{valid?: true, value: [1, true, nil], errors: []} =
               Response.output_result(
                 response(object: %{"value" => [1, true, nil]}),
                 Output.json()
               )
    end

    test "keeps retained raw output, parsed value, warnings, and provider metadata separate" do
      output = Output.object(name: [type: :string, required: true])
      raw = ~s({"name":"Ada"})

      result =
        response(
          object: %{"name" => "Ada"},
          tool_arguments: raw,
          provider_meta: %{request_id: "req_123"}
        )
        |> Response.output_result(output)

      assert result.raw == raw
      assert result.value == %{"name" => "Ada"}
      assert result.source == :tool_call
      assert result.valid?
      assert result.errors == []
      assert result.provider_metadata == %{request_id: "req_123"}

      assert "Structured output was extracted from retained tool-call arguments." in result.warnings
    end

    test "makes preserved legacy JSON repair visible" do
      output = Output.object(name: [type: :string, required: true])

      result =
        response(object: %{"name" => "Ada"}, tool_arguments: ~s({"name":"Ada",}))
        |> Response.output_result(output)

      assert result.valid?
      assert result.repairs == [%{type: :json_repair, status: :applied}]
      assert "Legacy light JSON repair was applied." in result.warnings
    end

    test "does not claim repair when malformed raw JSON was not materialized" do
      output = Output.object(name: [type: :string, required: true])

      result =
        response(object: nil, tool_arguments: ~s({"name":"Ada",}))
        |> Response.output_result(output)

      refute result.valid?
      assert result.repairs == []
    end

    test "reports legacy JSON repair and type coercion when both changed the value" do
      output = Output.object(age: [type: :pos_integer, required: true])

      result =
        response(object: %{"age" => 37}, tool_arguments: ~s({"age":"37",}))
        |> Response.output_result(output)

      assert result.valid?

      assert [
               %{type: :json_repair, status: :applied},
               %{type: :legacy_type_coercion, status: :applied}
             ] = result.repairs
    end

    test "does not describe plain text extraction as structured repair" do
      result = Response.output_result(response(text: "hello"), Output.text())

      assert result.source == :text
      assert result.warnings == []
      assert result.repairs == []
    end
  end

  describe "runtime validation policies" do
    test "keeps the default compatible while strict rejects the same invalid final value" do
      output = person_output()
      stub = stub_tool_response(%{"name" => "Ada"})

      assert {:ok, compatible_response} = generate(output, stub)
      assert Response.output(compatible_response, output) == %{"name" => "Ada"}

      assert {:error,
              %ReqLLM.Error.Validation.Error{
                tag: :structured_output_validation_failed,
                context: context
              }} = generate(output, stub, output_validation: :strict)

      assert %Result{valid?: false, raw: raw, errors: errors} = context[:output_result]
      assert Jason.decode!(raw) == %{"name" => "Ada"}
      assert [%{type: :schema_validation}] = errors
    end

    test "warn returns the response with structured diagnostics and call warnings" do
      output = person_output()
      stub = stub_tool_response(%{"name" => "Ada"})

      assert {:ok, response} = generate(output, stub, output_validation: :warn)
      assert response.provider_meta.req_llm_output.policy == :warn
      refute response.provider_meta.req_llm_output.valid?
      assert [_warning | _rest] = response.provider_meta.warnings
      assert [_warning | _rest] = Response.call_metadata(response).warnings

      assert %Result{policy: :warn, valid?: false, errors: [_error | _rest]} =
               Response.output_result(response, output)
    end

    test "turns unknown output keys into diagnostics instead of raising" do
      output = person_output()
      unknown_key = "unexpected_#{System.unique_integer([:positive])}"
      value = %{"name" => "Ada", "age" => 37, unknown_key => true}

      assert {:ok, warned_response} =
               generate(output, stub_tool_response(value), output_validation: :warn)

      assert %Result{valid?: false, errors: [%{type: :schema_validation}]} =
               Response.output_result(warned_response, output)

      assert {:error,
              %ReqLLM.Error.Validation.Error{
                tag: :structured_output_validation_failed,
                context: context
              }} = generate(output, stub_tool_response(value), output_validation: :strict)

      assert %Result{valid?: false, errors: [%{type: :schema_validation}]} =
               context[:output_result]
    end

    test "compatible can record diagnostics without changing success semantics" do
      output = person_output()
      stub = stub_tool_response(%{"name" => "Ada"}, self())

      assert {:ok, response} = generate(output, stub, output_validation: :compatible)
      assert Response.output(response, output) == %{"name" => "Ada"}
      refute response.provider_meta.req_llm_output.valid?
      refute Map.has_key?(response.provider_meta, :warnings)

      assert_receive {:request_body, body}
      refute Map.has_key?(body, "output_validation")
      refute Map.has_key?(body, "output_repair")
    end

    test "applies strict validation to the existing generate_object entrypoint" do
      schema = [name: [type: :string, required: true], age: [type: :pos_integer, required: true]]
      stub = stub_tool_response(%{"name" => "Ada"})

      assert {:error, %ReqLLM.Error.Validation.Error{tag: :structured_output_validation_failed}} =
               Generation.generate_object(
                 @model,
                 "Generate a person",
                 schema,
                 output_validation: :strict,
                 openai_structured_output_mode: :tool_strict,
                 req_http_options: [plug: {Req.Test, stub}]
               )
    end

    test "rejects invalid policy and repair options before an HTTP request" do
      stub = request_forbidden_stub()

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               generate(person_output(), stub, output_validation: :permissive)

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               generate(person_output(), stub, output_repair: :not_a_callback)

      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               Generation.generate_text(
                 @model,
                 "Hello",
                 output: Output.text(),
                 output_repair: fn _result -> {:ok, "repaired"} end,
                 req_http_options: [plug: {Req.Test, stub}]
               )

      assert message =~ "structured output descriptors"
      refute_received :http_request_executed
    end
  end

  describe "bounded local repair" do
    test "does not invoke the callback for an already valid value" do
      output = person_output()
      stub = stub_tool_response(%{"name" => "Ada", "age" => 37})
      test_pid = self()

      repair = fn result ->
        send(test_pid, {:repair_attempt, result})
        {:ok, result.value}
      end

      assert {:ok, response} =
               generate(
                 output,
                 stub,
                 output_validation: :strict,
                 output_repair: repair
               )

      refute_receive {:repair_attempt, _result}
      assert %Result{valid?: true, repairs: []} = Response.output_result(response, output)
    end

    test "invokes one callback once and accepts only a locally valid candidate" do
      output = person_output()
      stub = stub_tool_response(%{"name" => "Ada"})
      test_pid = self()

      repair = fn result ->
        send(test_pid, {:repair_attempt, result})
        {:ok, %{"name" => "Ada", "age" => 37}}
      end

      assert {:ok, response} =
               generate(
                 output,
                 stub,
                 output_validation: :strict,
                 output_repair: repair
               )

      assert Response.output(response, output) == %{"name" => "Ada", "age" => 37}
      assert_receive {:repair_attempt, %Result{valid?: false}}
      refute_receive {:repair_attempt, _result}

      assert %Result{
               valid?: true,
               raw: raw,
               repairs: [%{type: :callback, status: :applied}]
             } = Response.output_result(response, output)

      assert Jason.decode!(raw) == %{"name" => "Ada"}
    end

    test "records a failed callback once and strict still returns an error" do
      output = person_output()
      stub = stub_tool_response(%{"name" => "Ada"})
      test_pid = self()

      repair = fn result ->
        send(test_pid, {:repair_attempt, result})
        {:ok, %{"name" => "Still missing age"}}
      end

      assert {:error, %ReqLLM.Error.Validation.Error{context: context}} =
               generate(
                 output,
                 stub,
                 output_validation: :strict,
                 output_repair: repair
               )

      assert_receive {:repair_attempt, %Result{}}
      refute_receive {:repair_attempt, _result}

      assert %Result{repairs: [%{type: :callback, status: :failed}]} =
               context[:output_result]
    end

    test "records an invalid callback return without raising a case error" do
      output = person_output()
      stub = stub_tool_response(%{"name" => "Ada"})

      assert {:ok, response} =
               generate(
                 output,
                 stub,
                 output_validation: :compatible,
                 output_repair: fn _result -> %{"age" => 37} end
               )

      assert %Result{
               valid?: false,
               repairs: [%{type: :callback, status: :failed, reason: reason}]
             } = Response.output_result(response, output)

      assert reason =~ "expected {:ok, value}"
    end
  end

  describe "stream final-value parity" do
    test "enforces strict validation after a stream is materialized" do
      output = person_output()
      response = response(object: %{"name" => "Ada"}, tool_arguments: ~s({"name":"Ada"}))
      model = %LLMDB.Model{provider: :openai, id: "gpt-4-turbo"}
      stream_response = ReqLLM.Cache.stream_response(response, model, response.context)

      assert {:ok, contract} = Output.compile(output)
      assert {:ok, config, []} = Validation.take_runtime_options(output_validation: :strict)

      assert {:error, %ReqLLM.Error.Validation.Error{tag: buffered_tag}} =
               Validation.finalize_result({:ok, response}, contract, config)

      assert {:ok, strict_stream} =
               Validation.attach_stream_result({:ok, stream_response}, contract, config)

      assert {:error, %ReqLLM.Error.Validation.Error{tag: streamed_tag}} =
               StreamResponse.to_response(strict_stream)

      assert buffered_tag == streamed_tag
    end

    test "valid structured fixture remains valid under strict stream materialization" do
      output =
        Output.object(
          [
            name: [type: :string, required: true],
            age: [type: :pos_integer, required: true],
            occupation: [type: :string, required: true]
          ],
          name: "person"
        )

      assert {:ok, stream_response} =
               ReqLLM.stream_text(
                 "openai:gpt-4o-mini",
                 "Generate a software engineer profile",
                 output: output,
                 output_validation: :strict,
                 max_tokens: 500,
                 fixture: "object_streaming"
               )

      assert {:ok, response} = StreamResponse.to_response(stream_response)

      assert %Result{valid?: true, errors: [], policy: :strict} =
               Response.output_result(response, output)
    end
  end

  defp person_output do
    Output.object(
      [
        name: [type: :string, required: true],
        age: [type: :pos_integer, required: true]
      ],
      name: "person"
    )
  end

  defp generate(output, stub, opts \\ []) do
    Generation.generate_text(
      @model,
      "Generate a person",
      [
        output: output,
        openai_structured_output_mode: :tool_strict,
        req_http_options: [plug: {Req.Test, stub}]
      ] ++ opts
    )
  end

  defp stub_tool_response(arguments, test_pid \\ nil) do
    stub = {__MODULE__, make_ref()}
    encoded_arguments = Jason.encode!(arguments)

    Req.Test.stub(stub, fn conn ->
      conn = maybe_capture_request(conn, test_pid)

      Req.Test.json(conn, %{
        "id" => "cmpl_output_validation",
        "model" => "gpt-4-turbo",
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "id" => "call_output_validation",
                  "type" => "function",
                  "function" => %{
                    "name" => "structured_output",
                    "arguments" => encoded_arguments
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 4, "total_tokens" => 14}
      })
    end)

    stub
  end

  defp maybe_capture_request(conn, nil), do: conn

  defp maybe_capture_request(conn, test_pid) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(test_pid, {:request_body, Jason.decode!(body)})
    conn
  end

  defp request_forbidden_stub do
    stub = {__MODULE__, make_ref()}
    test_pid = self()

    Req.Test.stub(stub, fn _conn ->
      send(test_pid, :http_request_executed)
      raise "HTTP request should not execute"
    end)

    stub
  end

  defp response(opts) do
    object = Keyword.get(opts, :object)
    provider_meta = Keyword.get(opts, :provider_meta, %{})
    message = response_message(opts)

    %Response{
      id: "response_output_validation",
      model: "gpt-4-turbo",
      context: %Context{messages: []},
      message: message,
      object: object,
      stream?: false,
      stream: nil,
      usage: nil,
      finish_reason: :stop,
      provider_meta: provider_meta,
      error: nil
    }
  end

  defp response_message(opts) do
    cond do
      arguments = Keyword.get(opts, :tool_arguments) ->
        %Message{
          role: :assistant,
          content: [],
          tool_calls: [ToolCall.new("call_output_validation", "structured_output", arguments)],
          metadata: %{}
        }

      text = Keyword.get(opts, :text) ->
        %Message{
          role: :assistant,
          content: [ContentPart.text(text)],
          metadata: %{}
        }

      true ->
        %Message{role: :assistant, content: [], metadata: %{}}
    end
  end
end

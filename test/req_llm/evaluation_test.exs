defmodule ReqLLM.EvaluationTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.TypeSafe
  alias ReqLLM.Response

  @questions %{
    department: %{
      type: :choice,
      instructions: "Which team should handle this?",
      criteria: %{billing: "Billing and refunds", support: "Other requests"}
    },
    severity: %{
      type: :score,
      instructions: "How severe is this?",
      criteria: ["low", "medium", "high"]
    },
    urgent: %{type: :boolean, instructions: "Is this urgent?"}
  }

  test "evaluates one structured state and keeps all TypeSafe answer data" do
    Req.Test.stub(__MODULE__.Success, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/systemone"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]

      assert conn.body_params == %{
               "model" => "jev-latest",
               "state" => %{"ticket" => "Please refund me today"},
               "questions" => %{
                 "department" => %{
                   "type" => "choice",
                   "instructions" => "Which team should handle this?",
                   "criteria" => %{
                     "billing" => "Billing and refunds",
                     "support" => "Other requests"
                   }
                 },
                 "severity" => %{
                   "type" => "score",
                   "instructions" => "How severe is this?",
                   "criteria" => ["low", "medium", "high"]
                 },
                 "urgent" => %{"type" => "noul", "instructions" => "Is this urgent?"}
               }
             }

      Req.Test.json(conn, %{
        "model" => "jev-1.13.0",
        "answers" => %{
          "department" => %{
            "type" => "choice",
            "choice" => "billing",
            "probabilities" => %{"billing" => 0.9, "support" => 0.1},
            "confidence" => 0.8
          },
          "severity" => %{
            "type" => "score",
            "score" => 1.2,
            "legend" => %{"0" => "low", "1" => "medium", "2" => "high"},
            "probabilities" => %{"0" => 0.1, "1" => 0.6, "2" => 0.3},
            "confidence" => 0.6
          },
          "urgent" => %{"type" => "noul", "noul" => 0.93}
        },
        "usage" => %{"input_tokens" => 100, "output_tokens" => 20}
      })
    end)

    assert {:ok, %Response{} = result} =
             ReqLLM.evaluate(
               "typesafe:jev-latest",
               %{ticket: "Please refund me today"},
               @questions,
               api_key: "test-key",
               req_http_options: [plug: {Req.Test, __MODULE__.Success}]
             )

    assert result.model == "jev-1.13.0"
    assert String.starts_with?(result.id, "eval-")
    assert result.context.messages == []
    assert result.message == nil
    assert Response.text(result) == nil
    assert Response.object(result) == result.object
    assert result.object["department"]["choice"] == "billing"
    assert result.object["department"]["probabilities"]["billing"] == 0.9
    assert result.object["department"]["confidence"] == 0.8
    assert result.object["severity"]["score"] == 1.2
    assert result.object["severity"]["legend"]["2"] == "high"
    assert result.object["urgent"] == %{"type" => "boolean", "probability" => 0.93}
    assert result.provider_meta.operation == :evaluate

    assert result.provider_meta.raw_response["answers"]["urgent"] == %{
             "type" => "noul",
             "noul" => 0.93
           }

    assert Response.usage(result) == result.usage
    assert result.usage.input_tokens == 100
    assert result.usage.output_tokens == 20

    assert {:ok, %Response{} = decoded} =
             Response.decode_response(result.provider_meta.raw_response, "typesafe:jev-latest")

    assert decoded.object == result.object
  end

  test "resolves Jev as a non-chat model" do
    assert {:ok, model} = ReqLLM.model("typesafe:jev-latest")
    assert model.capabilities.chat == false
    assert model.capabilities.streaming.text == false
    assert {:ok, TypeSafe} = ReqLLM.provider(:typesafe)

    assert {:ok, inline_model} = ReqLLM.model(%{provider: :typesafe, id: "jev-preview"})
    assert inline_model.capabilities.chat == false
    assert inline_model.capabilities.streaming.text == false
  end

  test "rejects invalid state and questions before a request" do
    assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
             ReqLLM.evaluate("typesafe:jev-latest", 123, @questions, api_key: "test-key")

    assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
             ReqLLM.evaluate("typesafe:jev-latest", "text", %{}, api_key: "test-key")
  end

  test "uses a Zoi schema for evaluation options" do
    schema = ReqLLM.Evaluation.schema()
    assert %Zoi.Types.Keyword{} = schema

    assert {:ok, opts} =
             Zoi.parse(schema,
               api_key: "test-key",
               base_url: "https://api.typesafe.ai",
               receive_timeout: 1_000,
               total_timeout: :infinity,
               max_retries: 0,
               req_http_options: [plug: {Req.Test, __MODULE__.Success}],
               fixture: {:typesafe, "basic"},
               telemetry: %{test: true}
             )

    assert opts[:total_timeout] == :infinity
    assert opts[:req_http_options] == [plug: {Req.Test, __MODULE__.Success}]
    assert opts[:telemetry] == %{test: true}
    assert {:ok, [telemetry: [test: true]]} = Zoi.parse(schema, telemetry: [test: true])
  end

  test "rejects invalid evaluation options before a request" do
    invalid_options = [
      [receive_timeout: 0],
      [total_timeout: 0],
      [max_retries: -1],
      [req_http_options: [1]],
      [req_http_options: [{"plug", :invalid}]],
      [fixture: {:typesafe, 123}],
      [telemetry: 123],
      [unexpected_option: true],
      [api_key: "first", api_key: "second"]
    ]

    for opts <- invalid_options do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               ReqLLM.evaluate("typesafe:jev-latest", "text", @questions, opts)
    end

    assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
             ReqLLM.evaluate("typesafe:jev-latest", "text", @questions, [1])
  end

  test "reports unsupported operations without a chat request" do
    assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
             TypeSafe.prepare_request(
               :chat,
               %{provider: :typesafe, id: "jev-latest"},
               "hello",
               api_key: "test-key"
             )

    assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
             ReqLLM.evaluate("cohere:rerank-v3.5", "text", @questions, api_key: "test-key")

    no_http = [plug: fn _conn -> flunk("unexpected HTTP request") end]

    assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
             ReqLLM.generate_text("typesafe:jev-latest", "hello",
               api_key: "test-key",
               req_http_options: no_http
             )

    assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
             ReqLLM.generate_object(
               "typesafe:jev-latest",
               "hello",
               [answer: [type: :string, required: true]],
               api_key: "test-key",
               req_http_options: no_http
             )

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, {:http_streaming_failed, {:provider_build_failed, error}}} =
               ReqLLM.stream_text("typesafe:jev-latest", "hello", api_key: "test-key")

      assert %ReqLLM.Error.Invalid.Parameter{} = error
    end)
  end

  test "returns a response error for malformed provider data" do
    Req.Test.stub(__MODULE__.Malformed, fn conn ->
      Req.Test.json(conn, %{"answers" => %{}})
    end)

    assert {:error, %ReqLLM.Error.API.Request{status: 200}} =
             ReqLLM.evaluate("typesafe:jev-latest", "text", @questions,
               api_key: "test-key",
               req_http_options: [plug: {Req.Test, __MODULE__.Malformed}]
             )
  end
end

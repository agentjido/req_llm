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

  test "resolves each Jev spec from LLMDB as an evaluation-only model" do
    for id <- ["jev-latest", "jev-preview", "jev-1.13.0"] do
      assert {:ok, model} = ReqLLM.model("typesafe:" <> id)
      assert model.provider == :typesafe
      assert model.id == id
      assert LLMDB.Model.spec(model) == "typesafe:" <> id
      assert model.capabilities.evaluate == true
      assert model.capabilities.chat == false
      assert model.capabilities.streaming.text == false
      assert model.execution.evaluate.path == "/v1/systemone"
    end

    assert {:ok, TypeSafe} = ReqLLM.provider(:typesafe)

    assert {:ok, inline_model} = ReqLLM.model(%{provider: :typesafe, id: "jev-preview"})
    assert inline_model.capabilities.chat == false
    assert inline_model.capabilities.streaming.text == false
  end

  test "calls OpenRouter Decisions with choice, score, and boolean questions" do
    Req.Test.stub(__MODULE__.OpenRouterSuccess, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "openrouter.ai"
      assert conn.request_path == "/api/alpha/decisions"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer openrouter-test-key"]

      assert conn.body_params == %{
               "model" => "typesafe/jev-1.13",
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
        "id" => "gen-jev-test",
        "model" => "typesafe/jev-1.13",
        "provider" => "TypeSafe AI",
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
        "usage" => %{"input_tokens" => 100, "output_tokens" => 20, "cost" => 0.0042}
      })
    end)

    assert {:ok, %Response{} = result} =
             ReqLLM.evaluate(
               "openrouter:typesafe/jev-1.13",
               %{ticket: "Please refund me today"},
               @questions,
               api_key: "openrouter-test-key",
               req_http_options: [plug: {Req.Test, __MODULE__.OpenRouterSuccess}]
             )

    assert result.id == "gen-jev-test"
    assert result.model == "typesafe/jev-1.13"
    assert result.object["department"]["choice"] == "billing"
    assert result.object["department"]["probabilities"]["billing"] == 0.9
    assert result.object["severity"]["score"] == 1.2
    assert result.object["severity"]["legend"]["2"] == "high"
    assert result.object["urgent"] == %{"type" => "boolean", "probability" => 0.93}
    assert result.usage.input_tokens == 100
    assert result.usage.output_tokens == 20
    assert result.usage.total_tokens == 120
    assert result.provider_meta.provider == :openrouter
    assert result.provider_meta.raw_response["provider"] == "TypeSafe AI"
    assert result.provider_meta.raw_response["usage"]["cost"] == 0.0042
  end

  test "preserves the moving OpenRouter model ID" do
    Req.Test.stub(__MODULE__.OpenRouterMoving, fn conn ->
      assert conn.request_path == "/api/alpha/decisions"
      assert conn.body_params["model"] == "~typesafe/jev-latest"

      Req.Test.json(conn, %{
        "model" => "typesafe/jev-1.13",
        "answers" => %{"urgent" => %{"type" => "noul", "noul" => 0.75}},
        "usage" => %{"input_tokens" => 3, "output_tokens" => 1}
      })
    end)

    assert {:ok, result} =
             ReqLLM.evaluate(
               "openrouter:~typesafe/jev-latest",
               "urgent request",
               %{urgent: @questions.urgent},
               api_key: "openrouter-test-key",
               req_http_options: [plug: {Req.Test, __MODULE__.OpenRouterMoving}]
             )

    assert result.model == "typesafe/jev-1.13"
    assert result.object["urgent"]["probability"] == 0.75
  end

  test "lists only catalog evaluation specs with a callable adapter" do
    assert ReqLLM.evaluation_models() == [
             "openrouter:typesafe/jev-1.13",
             "openrouter:~typesafe/jev-latest",
             "typesafe:jev-1.13.0",
             "typesafe:jev-latest",
             "typesafe:jev-preview"
           ]

    for spec <- ReqLLM.evaluation_models() do
      assert {:ok, model} = ReqLLM.model(spec)
      assert model.capabilities.evaluate == true
      assert model.execution.evaluate.supported == true
    end
  end

  test "rejects unknown models, non-evaluation models, and missing adapters before HTTP" do
    no_http = [plug: fn _conn -> flunk("unexpected HTTP request") end]
    opts = [req_http_options: no_http]

    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: unknown}} =
             ReqLLM.evaluate("openrouter:unlisted-jev", "text", @questions, opts)

    assert unknown =~ "Unknown evaluation model spec"

    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: unknown_typesafe}} =
             ReqLLM.evaluate("typesafe:unlisted-jev", "text", @questions, opts)

    assert unknown_typesafe =~ "Unknown evaluation model spec"

    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: unsupported}} =
             ReqLLM.evaluate("openrouter:openai/gpt-4", "text", @questions, opts)

    assert unsupported =~ "does not support evaluation"

    spoofed_catalog_model = %{
      provider: :openrouter,
      id: "openai/gpt-4",
      capabilities: %{evaluate: true},
      execution: %{
        evaluate: %{
          supported: true,
          family: "openrouter_decisions",
          wire_protocol: "openrouter_decisions",
          path: "/api/alpha/decisions",
          provider_model_id: "openai/gpt-4"
        }
      }
    }

    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: spoofed_error}} =
             ReqLLM.evaluate(spoofed_catalog_model, "text", @questions, opts)

    assert spoofed_error =~ "does not support evaluation"

    inline_gateway = %{
      provider: :openai,
      id: "unlisted-evaluator",
      capabilities: %{evaluate: true, chat: false},
      execution: %{
        evaluate: %{
          supported: true,
          family: "custom_decisions",
          wire_protocol: "custom_decisions",
          path: "/decisions",
          provider_model_id: "unlisted-evaluator"
        }
      }
    }

    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: missing_adapter}} =
             ReqLLM.evaluate(inline_gateway, "text", @questions, opts)

    assert missing_adapter =~ "No evaluation adapter"
    assert missing_adapter =~ "custom_decisions"

    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: cloudflare_error}} =
             ReqLLM.evaluate("cloudflare_workers_ai:typesafe/jev", "text", @questions, opts)

    assert cloudflare_error =~ "No evaluation adapter"
    assert cloudflare_error =~ "cloudflare_ai_run"

    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: vercel_error}} =
             ReqLLM.evaluate("vercel:typesafe-ai/jev", "text", @questions, opts)

    assert vercel_error =~ "Catalog-only evaluation model"
  end

  test "accepts a full inline spec for an unlisted OpenRouter evaluation model" do
    inline_model = %{
      provider: :openrouter,
      id: "typesafe/jev-next",
      capabilities: %{evaluate: true, chat: false},
      execution: %{
        evaluate: %{
          supported: true,
          family: "openrouter_decisions",
          wire_protocol: "openrouter_decisions",
          path: "/api/alpha/decisions",
          provider_model_id: "typesafe/jev-next"
        }
      }
    }

    Req.Test.stub(__MODULE__.OpenRouterInline, fn conn ->
      assert conn.body_params["model"] == "typesafe/jev-next"

      Req.Test.json(conn, %{
        "model" => "typesafe/jev-next",
        "answers" => %{"urgent" => %{"type" => "noul", "noul" => 0.4}},
        "usage" => %{"input_tokens" => 3, "output_tokens" => 1}
      })
    end)

    for model <- [inline_model, ReqLLM.model!(inline_model)] do
      assert {:ok, result} =
               ReqLLM.evaluate(model, "text", %{urgent: @questions.urgent},
                 api_key: "openrouter-test-key",
                 req_http_options: [plug: {Req.Test, __MODULE__.OpenRouterInline}]
               )

      assert result.object["urgent"]["probability"] == 0.4
    end

    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: unknown}} =
             ReqLLM.evaluate(
               %{provider: :openrouter, id: "typesafe/jev-next"},
               "text",
               @questions,
               req_http_options: [plug: fn _conn -> flunk("unexpected HTTP request") end]
             )

    assert unknown =~ "Unknown evaluation model spec"
  end

  test "returns a response error for malformed OpenRouter Decisions data" do
    Req.Test.stub(__MODULE__.OpenRouterMalformed, fn conn ->
      assert conn.request_path == "/api/alpha/decisions"
      Req.Test.json(conn, %{"answers" => %{}})
    end)

    assert {:error, %ReqLLM.Error.API.Request{status: 200}} =
             ReqLLM.evaluate("openrouter:typesafe/jev-1.13", "text", @questions,
               api_key: "openrouter-test-key",
               req_http_options: [plug: {Req.Test, __MODULE__.OpenRouterMalformed}]
             )
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

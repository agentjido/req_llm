defmodule ReqLLM.Providers.Azure.EvaluationTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Providers.Azure
  alias ReqLLM.Response

  @base_url "https://decision-resource.services.ai.azure.com"
  @model %{
    provider: :azure,
    id: "microsoft-decision-1",
    provider_model_id: "Microsoft-Decision-1",
    aliases: ["Microsoft-Decision-1"],
    catalog_only: true,
    capabilities: %{chat: false, evaluate: true},
    cost: %{input: 0.042, output: 0.0},
    execution: %{
      evaluate: %{
        supported: true,
        family: "typesafe_systemone",
        wire_protocol: "typesafe_systemone",
        path: "/providers/microsoft/v1/systemone",
        provider_model_id: "Microsoft-Decision-1"
      }
    }
  }
  @questions %{
    urgent: %{type: :boolean, instructions: "Is this urgent?"},
    team: %{
      type: :choice,
      instructions: "Who should handle this?",
      criteria: %{engineering: "Software defects", billing: "Payments"}
    },
    severity: %{
      type: :score,
      instructions: "How severe is the incident?",
      criteria: ["low", "medium", "high"]
    }
  }

  setup_all do
    custom = Application.get_env(:llm_db, :custom, %{})
    on_exit(fn -> LLMDB.load(custom: custom) end)

    models = %{@model.id => Map.drop(@model, [:provider, :id])}
    evaluation_catalog = Map.put(custom, :azure, models: models)
    assert {:ok, _} = LLMDB.load(custom: evaluation_catalog)
    %{evaluation_catalog: evaluation_catalog}
  end

  test "discovers the catalog model with its Azure evaluation contract" do
    assert "azure:microsoft-decision-1" in ReqLLM.evaluation_models()
    assert {:ok, model} = ReqLLM.model("azure:Microsoft-Decision-1")
    assert model.id == "microsoft-decision-1"
    assert model.catalog_only
  end

  test "respects catalog filters even when the Azure adapter is installed", %{
    evaluation_catalog: custom
  } do
    on_exit(fn -> LLMDB.load(custom: custom) end)
    assert {:ok, _} = LLMDB.load(custom: custom, allow: [:typesafe])
    refute "azure:microsoft-decision-1" in ReqLLM.evaluation_models()

    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
             ReqLLM.evaluate("azure:microsoft-decision-1", "text", @questions, no_http_options())

    assert message =~ "unavailable under the current catalog filter"
  end

  test "evaluates all question types with deployment routing, API key auth, and usage" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "decision-resource.services.ai.azure.com"
      assert conn.request_path == "/providers/microsoft/v1/systemone"
      assert conn.query_string == ""
      assert Plug.Conn.get_req_header(conn, "api-key") == ["test-key"]
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      assert conn.body_params["model"] == "decision-production"
      assert conn.body_params["state"] == %{"ticket" => "Checkout is down"}
      assert conn.body_params["questions"]["urgent"]["type"] == "noul"
      assert conn.body_params["questions"]["team"]["criteria"]["billing"] == "Payments"
      assert conn.body_params["questions"]["severity"]["criteria"] == ["low", "medium", "high"]
      assert Enum.sort(Map.keys(conn.body_params)) == ["model", "questions", "state"]
      Req.Test.json(conn, response_body())
    end)

    assert {:ok, result} =
             ReqLLM.evaluate(
               "azure:Microsoft-Decision-1",
               %{ticket: "Checkout is down"},
               @questions,
               api_key: "test-key",
               base_url: @base_url <> "/",
               provider_options: [azure: [deployment: "decision-production"]],
               req_http_options: [plug: {Req.Test, __MODULE__}]
             )

    assert result.object["urgent"] == %{"type" => "boolean", "probability" => 0.95}
    assert result.object["team"]["choice"] == "engineering"
    assert result.object["team"]["probabilities"]["engineering"] == 0.9
    assert result.object["team"]["confidence"] == 0.8
    assert result.object["severity"]["score"] == 1.7
    assert result.object["severity"]["legend"]["2"] == "high"
    assert result.provider_meta.provider == :azure
    assert result.provider_meta.operation == :evaluate
    assert result.provider_meta.raw_response == response_body()
    assert result.model == "microsoft-decision-1"
    assert result.message == nil
    assert result.usage.input_tokens == 1000
    assert result.usage.output_tokens == 3
    assert_in_delta result.usage.input_cost, 0.000042, 0.000000001
    assert result.usage.output_cost == 0.0

    assert {:ok, decoded} = Response.decode_response(response_body(), @model)
    assert decoded.object == result.object
    assert decoded.usage.input_tokens == 1000
  end

  test "accepts inline metadata, native noul, map options, and explicit bearer tokens" do
    inline = Map.merge(@model, %{id: "decision-unlisted", base_url: @base_url})

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "api-key") == []
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]
      assert conn.body_params["model"] == "inline-deployment"
      assert conn.body_params["state"] == ["Checkout is down"]
      assert conn.body_params["questions"]["urgent"]["type"] == "noul"
      Req.Test.json(conn, response_body())
    end)

    for model <- [inline, ReqLLM.model!(inline)] do
      assert {:ok, %Response{}} =
               ReqLLM.evaluate(
                 model,
                 ["Checkout is down"],
                 %{
                   urgent: %{type: "noul", instructions: "Is this urgent?"}
                 },
                 api_key: "Bearer test-token",
                 provider_options: %{"deployment" => "inline-deployment"},
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end
  end

  test "uses Azure application credentials and defaults deployment to the model ID" do
    previous = Application.get_env(:req_llm, :azure)
    previous_key = Application.get_env(:req_llm, :azure_api_key)

    on_exit(fn ->
      restore_config(:azure, previous)
      restore_config(:azure_api_key, previous_key)
    end)

    Application.put_env(:req_llm, :azure, base_url: @base_url)
    Application.put_env(:req_llm, :azure_api_key, "configured-key")

    assert {:ok, request} =
             Azure.prepare_request(:evaluate, @model, %{state: "text", questions: @questions}, [])

    assert request.options.base_url == @base_url
    assert request.options.json.model == @model.id
    assert Req.Request.get_header(request, "api-key") == ["configured-key"]
  end

  test "rejects incompatible evaluation contracts before HTTP" do
    for override <- [%{family: "openai_decisions"}, %{path: "/v1/systemone"}, %{supported: false}] do
      model =
        @model
        |> Map.put(:id, "decision-unlisted")
        |> put_in([:execution, :evaluate], Map.merge(@model.execution.evaluate, override))

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               ReqLLM.evaluate(model, "text", @questions, no_http_options())
    end
  end

  test "rejects invalid configuration before HTTP" do
    for options <- [
          [base_url: ""],
          [api_key: ""],
          [api_key: "Bearer "],
          [api_key: "Bearer token\r\ninvalid"],
          [provider_options: [deployment: 123]],
          [provider_options: [deployment: ""]],
          [provider_options: [api_version: "2024-05-01-preview"]]
        ] do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               ReqLLM.evaluate(
                 @model,
                 "text",
                 @questions,
                 Keyword.merge(no_http_options(), options)
               )
    end
  end

  test "preserves Azure HTTP errors and rejects malformed success responses" do
    for status <- [400, 401, 429, 503] do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(status)
        |> Req.Test.json(%{"error" => %{"message" => "Azure evaluation failed"}})
      end)

      assert {:error, error} = evaluate_stub()
      assert error.status == status
      assert error.response_body["error"]["message"] == "Azure evaluation failed"
    end

    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"model" => "microsoft-decision-1"}))
    assert {:error, error} = evaluate_stub()
    assert error.reason =~ "Invalid Azure evaluation response"
  end

  defp evaluate_stub do
    ReqLLM.evaluate(@model, "text", @questions,
      api_key: "test-key",
      base_url: @base_url,
      provider_options: [deployment: "test-deployment"],
      max_retries: 0,
      req_http_options: [plug: {Req.Test, __MODULE__}]
    )
  end

  defp no_http_options do
    [
      api_key: "test-key",
      base_url: @base_url,
      provider_options: [deployment: "test-deployment"],
      req_http_options: [plug: fn _conn -> flunk("unexpected HTTP request") end]
    ]
  end

  defp response_body do
    %{
      "model" => "microsoft-decision-1",
      "answers" => %{
        "urgent" => %{"type" => "noul", "noul" => 0.95},
        "team" => %{
          "type" => "choice",
          "choice" => "engineering",
          "probabilities" => %{"engineering" => 0.9, "billing" => 0.1},
          "confidence" => 0.8
        },
        "severity" => %{
          "type" => "score",
          "score" => 1.7,
          "probabilities" => %{"0" => 0.1, "1" => 0.1, "2" => 0.8},
          "legend" => %{"0" => "low", "1" => "medium", "2" => "high"},
          "confidence" => 0.7
        }
      },
      "usage" => %{"input_tokens" => 1000, "output_tokens" => 3}
    }
  end

  defp restore_config(key, nil), do: Application.delete_env(:req_llm, key)
  defp restore_config(key, value), do: Application.put_env(:req_llm, key, value)
end

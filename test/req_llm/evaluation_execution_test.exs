defmodule ReqLLM.EvaluationExecutionTest do
  use ExUnit.Case, async: false

  alias LLMDB.{Catalog, Model, Provider, Store}
  alias ReqLLM.Providers.CatalogGateway

  defmodule CustomProvider do
    use ReqLLM.Provider, id: :custom_evaluator, default_base_url: "https://wrong.example"

    @impl ReqLLM.Provider
    def evaluation_protocols, do: ["openrouter_decisions"]

    def prepare_request(:evaluate, model, input, opts) do
      CatalogGateway.prepare_request(:evaluate, model, input, opts)
    end
  end

  defmodule GenericProvider do
    use ReqLLM.Provider, id: :generic_evaluator, default_base_url: "https://wrong.example"

    def prepare_request(_, _, _, _), do: raise("generic preparation must not imply support")
  end

  @questions %{
    route: %{type: :choice, choices: ["billing", "support"]},
    score: %{type: :score, min: 0, max: 2},
    urgent: %{type: :boolean}
  }

  setup do
    snapshot = Store.snapshot()
    opts = Store.last_opts()
    ReqLLM.Providers.register!(CustomProvider)
    ReqLLM.Providers.register!(GenericProvider)

    on_exit(fn ->
      ReqLLM.Providers.unregister(:custom_evaluator)
      ReqLLM.Providers.unregister(:generic_evaluator)
      if snapshot, do: Store.put!(snapshot, opts), else: Store.clear!()
    end)

    providers =
      for id <- [:custom_evaluator, :generic_evaluator, :decision_gateway] do
        Provider.new!(%{
          id: id,
          name: to_string(id),
          runtime: %{
            base_url: "https://runtime.example/v1",
            auth: %{type: "bearer", env: ["DECISION_GATEWAY_TEST_KEY"]}
          }
        })
      end

    models = for provider <- providers, do: model(provider.id)

    Store.put!(
      Catalog.build(providers, models, models,
        filters: %{allow: :all, deny: %{}},
        loaded_at: nil,
        digest: "evaluation-execution-test"
      ),
      []
    )

    :ok
  end

  for provider <- [:custom_evaluator, :decision_gateway] do
    test "public evaluate reaches #{provider} with its contract and identity" do
      provider = unquote(provider)

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "gateway.example"
        assert conn.request_path == "/v1/custom/decide"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer gateway-key"]
        assert conn.body_params["model"] == "wire-evaluator"
        assert conn.body_params["state"] == "refund"
        assert conn.body_params["questions"]["urgent"]["type"] == "noul"
        Req.Test.json(conn, response())
      end)

      assert {:ok, result} =
               ReqLLM.evaluate("#{provider}:evaluator", "refund", @questions,
                 api_key: "gateway-key",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )

      assert result.model == "wire-evaluator"
      assert result.provider_meta.provider == provider
      assert result.object["route"]["probabilities"] == %{"billing" => 0.8, "support" => 0.2}
      assert result.object["score"]["score"] == 1.25
      assert result.object["urgent"]["probability"] == 0.7
      assert result.usage.input_tokens == 8
      assert result.usage.output_tokens == 3
    end
  end

  test "discovery uses the same explicit adapter and contract checks" do
    assert ReqLLM.evaluation_models() == [
             "custom_evaluator:evaluator",
             "decision_gateway:evaluator"
           ]

    assert {:error, error} =
             ReqLLM.evaluate("generic_evaluator:evaluator", "refund", @questions, no_http())

    assert Exception.message(error) =~ "No evaluation adapter"
  end

  test "inline maps retain endpoint overrides and do not double the v1 prefix" do
    spec = model(:decision_gateway, "inline") |> Map.from_struct()

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "override.example"
      assert conn.request_path == "/v1/custom/decide"
      Req.Test.json(conn, response())
    end)

    assert {:ok, _} =
             ReqLLM.evaluate(spec, "refund", @questions,
               api_key: "key",
               base_url: "https://override.example/v1/",
               req_http_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "rejects absent, disabled, incompatible and non-HTTP contracts before transport" do
    spec = model(:decision_gateway, "inline")

    invalid = [
      %{spec | capabilities: %{evaluate: false}},
      %{spec | execution: %{}},
      put_in(spec.execution.evaluate.supported, false),
      put_in(spec.execution.evaluate.family, "unknown_decisions"),
      put_in(spec.execution.evaluate.wire_protocol, "openai_decisions"),
      put_in(spec.execution.evaluate[:transport], "websocket"),
      put_in(spec.execution.evaluate.path, "//other.example/decisions")
    ]

    for model <- invalid do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               ReqLLM.evaluate(model, "refund", @questions, no_http())
    end
  end

  test "registered adapters reject protocols they did not declare instead of falling back" do
    spec = model(:custom_evaluator, "inline") |> with_protocol("openai_decisions")

    assert {:error, error} = ReqLLM.evaluate(spec, "text", @questions, no_http())
    assert Exception.message(error) =~ "registered provider does not implement this protocol"
    refute ReqLLM.ProviderDispatch.executable?(spec, :evaluate)
  end

  test "discovery and execution respect catalog filtering and canonical metadata" do
    ReqLLM.Test.CatalogFilter.allow_providers!([:custom_evaluator])
    assert ReqLLM.evaluation_models() == ["custom_evaluator:evaluator"]

    for spec <- ["decision_gateway:evaluator", model(:decision_gateway)] do
      assert {:error, error} = ReqLLM.evaluate(spec, "text", @questions, no_http())
      assert Exception.message(error) =~ "current catalog filter"
    end

    spoofed = model(:generic_evaluator) |> Map.put(:provider_model_id, "spoofed")
    assert {:error, _} = ReqLLM.evaluate(spoofed, "text", @questions, no_http())
  end

  test "requires executable gateway runtime and supported authentication" do
    snapshot = Store.snapshot()

    for override <- [
          %{catalog_only: true},
          %{runtime: nil},
          %{runtime: %{auth: %{type: "api_key"}}},
          %{runtime: %{auth: %{type: "bearer"}, default_query: %{api_version: "1"}}}
        ] do
      providers =
        Enum.map(snapshot.providers, fn provider ->
          if provider.id == :decision_gateway, do: struct(provider, override), else: provider
        end)

      catalog = %{
        snapshot
        | providers: providers,
          providers_by_id: Map.new(providers, &{&1.id, &1})
      }

      Store.put!(catalog, [])
      refute "decision_gateway:evaluator" in ReqLLM.evaluation_models()

      assert {:error, _} =
               ReqLLM.evaluate("decision_gateway:evaluator", "text", @questions, no_http())
    end
  end

  test "uses the gateway's configured credential rather than the protocol provider's key" do
    ReqLLM.Test.Env.isolate!(["DECISION_GATEWAY_TEST_KEY", "OPENROUTER_API_KEY"])
    System.put_env("DECISION_GATEWAY_TEST_KEY", "own-env-key")
    System.put_env("OPENROUTER_API_KEY", "wrong-key")

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer own-env-key"]
      Req.Test.json(conn, response())
    end)

    assert {:ok, _} =
             ReqLLM.evaluate("decision_gateway:evaluator", "text", @questions,
               req_http_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "joins root, versioned and custom prefixes and honors path overrides" do
    for {base_url, path, expected} <- [
          {"https://override.example", "/v1/decisions", "/v1/decisions"},
          {"https://override.example/v1/", "/v1/decisions", "/v1/decisions"},
          {"https://override.example/v1", "/decisions", "/v1/decisions"},
          {"https://override.example/proxy", "/v1/decisions", "/proxy/v1/decisions"},
          {"https://override.example/proxy/v1", "/v1/decisions", "/proxy/v1/decisions"},
          {"https://override.example/proxy/v1", "/proxy/v1/decisions", "/proxy/v1/decisions"}
        ] do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "override.example"
        assert conn.request_path == expected
        Req.Test.json(conn, response())
      end)

      assert {:ok, _} =
               ReqLLM.evaluate("decision_gateway:evaluator", "text", @questions,
                 api_key: "key",
                 base_url: base_url,
                 evaluate_path: path,
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end
  end

  test "supports the System One protocol without a TypeSafe provider identity" do
    spec = model(:decision_gateway, "inline") |> with_protocol("typesafe_systemone")

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.body_params["state"] == %{"ticket" => "refund"}
      assert conn.body_params["questions"]["urgent"]["type"] == "noul"
      Req.Test.json(conn, response())
    end)

    assert {:ok, result} =
             ReqLLM.evaluate(spec, %{ticket: "refund"}, @questions,
               api_key: "key",
               req_http_options: [plug: {Req.Test, __MODULE__}]
             )

    assert result.provider_meta.provider == :decision_gateway
    assert result.object["score"]["score"] == 1.25

    assert {:error, error} =
             ReqLLM.evaluate(spec, ReqLLM.Context.new("text"), @questions, no_http())

    assert Exception.message(error) =~ "requires OpenAI Decisions"
  end

  test "OpenAI Decisions gateways compile images and retain answer distributions and identity" do
    spec = model(:decision_gateway, "inline") |> with_protocol("openai_decisions")

    questions = %{
      score: %{type: :score, instructions: "Severity?", criteria: ["low", "medium", "high"]}
    }

    context =
      ReqLLM.Context.new([
        ReqLLM.Context.user([
          ReqLLM.Message.ContentPart.text("Assess this"),
          ReqLLM.Message.ContentPart.image(<<1, 2, 3>>, "image/png")
        ])
      ])

    probabilities = [
      %{"label" => "low", "value" => 0, "probability" => 0.1},
      %{"label" => "medium", "value" => 1, "probability" => 0.55},
      %{"label" => "high", "value" => 2, "probability" => 0.35}
    ]

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "gateway.example"
      assert conn.body_params["model"] == "wire-evaluator"
      assert conn.body_params["safety_identifier"] == "gateway-user"
      assert [%{"role" => "user", "content" => [_, image]}] = conn.body_params["input"]
      assert image == %{"type" => "input_image", "image_url" => "data:image/png;base64,AQID"}
      assert [%{"name" => "score", "type" => "score"}] = conn.body_params["questions"]

      Req.Test.json(conn, %{
        "model" => "wire-evaluator",
        "answers" => [
          %{
            "name" => "score",
            "type" => "score",
            "score" => 1.25,
            "confidence" => 0.55,
            "probabilities" => probabilities
          }
        ],
        "usage" => %{"input_tokens" => 8, "output_tokens" => 3}
      })
    end)

    assert {:ok, result} =
             ReqLLM.evaluate(spec, context, questions,
               api_key: "key",
               provider_options: [safety_identifier: "gateway-user"],
               req_http_options: [plug: {Req.Test, __MODULE__}]
             )

    assert result.provider_meta.provider == :decision_gateway
    assert result.provider_meta["api_type"] == "decisions"
    assert result.object["score"]["score"] == 1.25
    assert result.object["score"]["probabilities"] == probabilities
  end

  test "OpenAI Decisions gateways validate the request's ordered answer contract" do
    spec = model(:decision_gateway, "inline") |> with_protocol("openai_decisions")
    questions = %{urgent: %{type: :boolean, instructions: "Urgent?"}}

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "model" => "wire-evaluator",
        "answers" => [%{"name" => "wrong-name", "type" => "predicate", "probability" => 0.7}],
        "usage" => %{}
      })
    end)

    assert {:error, %ReqLLM.Error.API.Request{cause: %ReqLLM.Error.API.Response{}}} =
             ReqLLM.evaluate(spec, "text", questions,
               api_key: "key",
               req_http_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "gateway requests retain retries and total timeout enforcement" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
        0 ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.put_status(503)
          |> Req.Test.json(%{"error" => "busy"})

        _ ->
          Req.Test.json(conn, response())
      end
    end)

    assert {:ok, _} =
             ReqLLM.evaluate("decision_gateway:evaluator", "text", @questions,
               api_key: "key",
               max_retries: 1,
               total_timeout: 5_000,
               req_http_options: [plug: {Req.Test, __MODULE__}]
             )

    assert Agent.get(attempts, & &1) == 2

    assert {:error, %ReqLLM.Error.API.Timeout{kind: :total}} =
             ReqLLM.evaluate("decision_gateway:evaluator", "text", @questions,
               api_key: "key",
               total_timeout: 20,
               req_http_options: [plug: fn _conn -> Process.sleep(:infinity) end]
             )
  end

  test "gateway errors and malformed success bodies retain response errors" do
    for {status, body} <- [{401, %{"error" => "unauthorized"}}, {200, %{"answers" => %{}}}] do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end)

      assert {:error, error} =
               ReqLLM.evaluate("decision_gateway:evaluator", "text", @questions,
                 api_key: "key",
                 max_retries: 0,
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )

      assert error.status == status
      assert error.response_body == body
    end
  end

  test "built-in adapters honor inline execution endpoints and wire models" do
    for {provider, protocol} <- [
          {:typesafe, "typesafe_systemone"},
          {:openrouter, "openrouter_decisions"},
          {:openai, "openai_decisions"}
        ] do
      spec = model(provider, "inline") |> with_protocol(protocol)
      questions = %{urgent: %{type: :boolean, instructions: "Urgent?"}}

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "gateway.example"
        assert conn.request_path == "/v1/custom/decide"
        assert conn.body_params["model"] == "wire-evaluator"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer own-key"]

        answers =
          if provider == :openai,
            do: [%{"name" => "urgent", "type" => "predicate", "probability" => 0.7}],
            else: %{"urgent" => %{"type" => "noul", "noul" => 0.7}}

        Req.Test.json(conn, %{"model" => "wire-evaluator", "answers" => answers, "usage" => %{}})
      end)

      assert {:ok, result} =
               ReqLLM.evaluate(spec, "text", questions,
                 api_key: "own-key",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )

      assert result.provider_meta.provider == provider

      assert {:ok, _} =
               ReqLLM.evaluate(spec, "text", questions,
                 api_key: "own-key",
                 base_url: "https://gateway.example/v1/",
                 evaluate_path: "/custom/decide",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end
  end

  test "discovery excludes missing and unsupported contracts even on a registered evaluator" do
    snapshot = Store.snapshot()

    for execution <- [
          %{},
          %{evaluate: %{supported: false}},
          %{
            evaluate: %{
              supported: true,
              family: "custom_decisions",
              wire_protocol: "custom_decisions"
            }
          }
        ] do
      models = Enum.map(snapshot.base_models, &%{&1 | execution: execution})

      catalog =
        Catalog.build(snapshot.providers, models, models,
          filters: %{allow: :all, deny: %{}},
          loaded_at: nil,
          digest: "unsupported-evaluation-contracts"
        )

      Store.put!(catalog, [])
      assert ReqLLM.evaluation_models() == []

      assert {:error, _} =
               ReqLLM.evaluate("custom_evaluator:evaluator", "text", @questions, no_http())
    end
  end

  defp with_protocol(model, protocol) do
    update_in(model.execution.evaluate, fn execution ->
      %{execution | family: protocol, wire_protocol: protocol}
    end)
  end

  defp model(provider, id \\ "evaluator") do
    %Model{
      provider: provider,
      id: id,
      model: id,
      provider_model_id: "wrong-model",
      base_url: "https://wrong-model.example",
      capabilities: %{evaluate: true, chat: false},
      execution: %{
        evaluate: %{
          supported: true,
          family: "openrouter_decisions",
          wire_protocol: "openrouter_decisions",
          base_url: "https://gateway.example/v1",
          path: "/v1/custom/decide",
          provider_model_id: "wire-evaluator"
        }
      },
      catalog_only: false
    }
  end

  defp response do
    %{
      "model" => "wire-evaluator",
      "answers" => %{
        "route" => %{
          "type" => "choice",
          "choice" => "billing",
          "probabilities" => %{"billing" => 0.8, "support" => 0.2}
        },
        "score" => %{"type" => "score", "score" => 1.25},
        "urgent" => %{"type" => "noul", "noul" => 0.7}
      },
      "usage" => %{"input_tokens" => 8, "output_tokens" => 3}
    }
  end

  defp no_http do
    [req_http_options: [plug: fn _ -> flunk("unexpected HTTP request") end]]
  end
end

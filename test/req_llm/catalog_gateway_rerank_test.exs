defmodule ReqLLM.CatalogGatewayRerankTest do
  use ExUnit.Case, async: false

  alias LLMDB.{Catalog, Model, Provider, Store}
  alias ReqLLM.Providers.CatalogGateway

  @moduletag contract: :public_api

  setup_all do
    snapshot = Store.snapshot()
    opts = Store.last_opts()

    ExUnit.Callbacks.on_exit(fn ->
      if snapshot, do: Store.put!(snapshot, opts), else: Store.clear!()
    end)

    provider =
      Provider.new!(%{
        id: :albert,
        name: "Albert API",
        runtime: %{
          base_url: "https://api.albert.etalab.gouv.fr/v1",
          auth: %{type: "bearer", env: ["ALBERT_API_KEY"]}
        }
      })

    model = %Model{
      provider: :albert,
      id: "bge-reranker-v2-m3",
      model: "bge-reranker-v2-m3",
      provider_model_id: "openweight-rerank",
      capabilities: %{chat: false, rerank: true},
      execution: %{
        rerank: %{
          supported: true,
          family: "cohere_rerank_compatible",
          wire_protocol: "cohere_rerank",
          base_url: "https://api.albert.etalab.gouv.fr",
          path: "/v1/rerank"
        }
      },
      catalog_only: false
    }

    catalog =
      Catalog.build([provider], [model], [model],
        filters: %{allow: :all, deny: %{}},
        loaded_at: nil,
        digest: "catalog-gateway-rerank-test"
      )

    Store.put!(catalog, [])
    %{model: model}
  end

  setup do
    ReqLLM.Test.Env.isolate!(["ALBERT_API_KEY"])
    System.put_env("ALBERT_API_KEY", "albert-test-key")
    :ok
  end

  test "uses Albert identity, credentials, route, and Cohere-compatible body", %{model: model} do
    Req.Test.stub(__MODULE__.Albert, fn conn ->
      assert conn.host == "api.albert.etalab.gouv.fr"
      assert conn.request_path == "/v1/rerank"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer albert-test-key"]

      assert conn.body_params == %{
               "model" => "openweight-rerank",
               "query" => "passport renewal",
               "documents" => ["Renew at city hall", "Submit a tax return online"],
               "top_n" => 1
             }

      Req.Test.json(conn, %{
        "id" => "albert-rerank",
        "results" => [%{"index" => 0, "relevance_score" => 0.98}]
      })
    end)

    assert {:ok, response} =
             ReqLLM.rerank(model,
               query: "passport renewal",
               documents: ["Renew at city hall", "Submit a tax return online"],
               top_n: 1,
               req_http_options: [plug: {Req.Test, __MODULE__.Albert}]
             )

    assert response.id == "albert-rerank"
    assert response.model == "openweight-rerank"

    assert response.results == [
             %{index: 0, relevance_score: 0.98, document: "Renew at city hall"}
           ]
  end

  test "explicit base URL and path override execution metadata", %{model: model} do
    Req.Test.stub(__MODULE__.Override, fn conn ->
      assert conn.host == "local.example"
      assert conn.request_path == "/api/custom/rerank"
      Req.Test.json(conn, %{"results" => []})
    end)

    assert {:ok, response} =
             ReqLLM.rerank(model,
               query: "rank",
               documents: ["one"],
               base_url: "https://local.example/api",
               rerank_path: "/custom/rerank",
               req_http_options: [plug: {Req.Test, __MODULE__.Override}]
             )

    assert response.results == []
  end

  test "rejects missing rerank execution metadata before a request", %{model: model} do
    model = %{model | execution: %{}}

    assert {:error, error} =
             ReqLLM.rerank(model, query: "rank", documents: ["one"])

    assert Exception.message(error) =~ "supported rerank execution contract"
    assert Exception.message(error) =~ "cohere_rerank_compatible"
  end

  test "rejects unsupported rerank execution protocols", %{model: model} do
    model =
      put_in(model.execution.rerank, %{
        supported: true,
        family: "other_rerank",
        wire_protocol: "other_rerank",
        path: "/v1/rerank"
      })

    assert {:error, error} =
             ReqLLM.rerank(model, query: "rank", documents: ["one"])

    assert Exception.message(error) =~ "cohere_rerank_compatible"
    assert Exception.message(error) =~ "cohere_rerank"
  end

  test "selects the catalog gateway from rerank metadata", %{model: model} do
    assert ReqLLM.Provider.Adapter.resolve(model, :rerank) == {:ok, CatalogGateway}
  end

  test "converts Cohere-compatible API failures into exceptions" do
    request =
      Req.new()
      |> Req.Request.register_options([:operation])
      |> Req.Request.merge_options(operation: :rerank)

    response = %Req.Response{status: 401, body: %{"message" => "invalid api key"}}

    assert {_request, %ReqLLM.Error.API.Response{} = error} =
             CatalogGateway.decode_response({request, response})

    assert error.status == 401
  end
end

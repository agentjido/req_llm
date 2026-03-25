defmodule ReqLLM.Providers.CohereTest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Cohere

  alias ReqLLM.Providers.Cohere

  defp rerank_model(model_id \\ "rerank-v3.5") do
    %LLMDB.Model{
      id: model_id,
      model: model_id,
      provider_model_id: model_id,
      provider: :cohere,
      family: "rerank",
      capabilities: %{rerank: true}
    }
  end

  describe "provider contract" do
    test "provider identity and configuration" do
      assert Cohere.provider_id() == :cohere
      assert Cohere.base_url() == "https://api.cohere.com"
      assert Cohere.default_env_key() == "COHERE_API_KEY"
    end
  end

  describe "request preparation" do
    test "prepare_request for :rerank creates /v2/rerank request" do
      model = rerank_model()

      {:ok, request} =
        Cohere.prepare_request(
          :rerank,
          model,
          %{query: "capital of the US", documents: ["Nevada", "Washington"]},
          top_n: 1
        )

      assert %Req.Request{} = request
      assert request.url.path == "/v2/rerank"
      assert request.method == :post
      assert request.options[:query] == "capital of the US"
      assert request.options[:documents] == ["Nevada", "Washington"]
      assert request.options[:top_n] == 1
    end

    test "prepare_request rejects unsupported operations" do
      {:error, error} = Cohere.prepare_request(:chat, rerank_model(), %{}, [])

      assert %ReqLLM.Error.Invalid.Parameter{} = error
      assert Exception.message(error) =~ "Supported operations: [:rerank]"
    end
  end

  describe "authentication wiring" do
    test "attach adds Bearer authorization header" do
      attached = Cohere.attach(Req.new(), rerank_model(), [])

      assert String.starts_with?(List.first(attached.headers["authorization"]), "Bearer ")
    end
  end

  describe "body encoding" do
    test "encode_body produces valid Cohere rerank JSON" do
      request =
        Req.new()
        |> Req.Request.register_options([
          :model,
          :query,
          :documents,
          :top_n,
          :max_tokens_per_doc,
          :priority
        ])
        |> Req.Request.merge_options(
          model: "rerank-v3.5",
          query: "capital of the US",
          documents: ["Nevada", "Washington"],
          top_n: 1,
          max_tokens_per_doc: 2048,
          priority: 3
        )

      encoded = Cohere.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body == %{
               "model" => "rerank-v3.5",
               "query" => "capital of the US",
               "documents" => ["Nevada", "Washington"],
               "top_n" => 1,
               "max_tokens_per_doc" => 2048,
               "priority" => 3
             }
    end
  end

  describe "response decoding" do
    test "decode_response parses successful JSON responses" do
      req = Req.new()

      resp = %Req.Response{
        status: 200,
        body: %{
          "id" => "rerank-1",
          "results" => [%{"index" => 1, "relevance_score" => 0.98}]
        }
      }

      {_req, decoded_resp} = Cohere.decode_response({req, resp})

      assert decoded_resp.body["id"] == "rerank-1"
      assert decoded_resp.body["results"] == [%{"index" => 1, "relevance_score" => 0.98}]
    end

    test "decode_response converts API failures into exceptions" do
      req = Req.new()

      resp = %Req.Response{
        status: 401,
        body: %{"message" => "invalid api key"}
      }

      {_req, error} = Cohere.decode_response({req, resp})

      assert %ReqLLM.Error.API.Response{} = error
      assert error.status == 401
    end
  end

  describe "usage extraction" do
    test "extract_usage reads token and billed unit metadata from responses" do
      assert {:ok, usage} =
               Cohere.extract_usage(
                 %{
                   "meta" => %{
                     "tokens" => %{"input_tokens" => 12},
                     "billed_units" => %{"search_units" => 1}
                   }
                 },
                 rerank_model()
               )

      assert usage["input_tokens"] == 12
      assert usage[:search_units] == 1
      assert usage[:billed_units] == %{"search_units" => 1}
    end
  end
end

defmodule ReqLLM.Providers.SuperlinkedTest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Superlinked, async: true

  alias ReqLLM.Providers.Superlinked

  test "declares its provider identity and defaults" do
    assert Superlinked.provider_id() == :superlinked
    assert Superlinked.default_base_url() == "https://api.superlinked.com/v1"
    assert Superlinked.default_env_key() == "SIE_API_KEY"
  end

  test "uses SIE bearer authentication" do
    request = Superlinked.attach(Req.new(), chat_model(), api_key: "sie-test-key")

    assert request.headers["authorization"] == ["Bearer sie-test-key"]
  end

  test "uses OpenAI-compatible chat and embedding paths" do
    assert {:ok, chat_request} =
             Superlinked.prepare_request(:chat, chat_model(), "Hello", api_key: "test-key")

    assert chat_request.url.path == "/chat/completions"
    assert chat_request.options[:base_url] == "https://api.superlinked.com/v1"

    assert {:ok, embedding_request} =
             Superlinked.prepare_request(:embedding, embedding_model(), "Hello",
               api_key: "test-key"
             )

    assert embedding_request.url.path == "/embeddings"
    assert embedding_request.options[:base_url] == "https://api.superlinked.com/v1"
  end

  test "generates text through the OpenAI-compatible endpoint" do
    Req.Test.stub(__MODULE__.ChatHTTP, fn conn ->
      assert conn.request_path == "/v1/chat/completions"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
      assert conn.body_params["model"] == "Qwen/Qwen3.5-4B"
      assert conn.body_params["messages"] == [%{"content" => "Hello", "role" => "user"}]

      Req.Test.json(conn, chat_response())
    end)

    assert {:ok, response} =
             ReqLLM.generate_text(chat_model(), "Hello",
               api_key: "test-key",
               req_http_options: [plug: {Req.Test, __MODULE__.ChatHTTP}]
             )

    assert ReqLLM.Response.text(response) == "Hello from SIE"
  end

  test "encodes tools with the OpenAI-compatible chat request" do
    tool =
      ReqLLM.tool(
        name: "weather",
        description: "Get weather",
        parameter_schema: [city: [type: :string, required: true]],
        callback: fn _args -> {:ok, "sunny"} end
      )

    Req.Test.stub(__MODULE__.ToolsHTTP, fn conn ->
      assert [%{"function" => function, "type" => "function"}] = conn.body_params["tools"]
      assert function["name"] == "weather"
      Req.Test.json(conn, chat_response())
    end)

    assert {:ok, response} =
             ReqLLM.generate_text(chat_model(), "What is the weather?",
               api_key: "test-key",
               tools: [tool],
               req_http_options: [plug: {Req.Test, __MODULE__.ToolsHTTP}]
             )

    assert ReqLLM.Response.text(response) == "Hello from SIE"
  end

  test "embeds text through the OpenAI-compatible endpoint" do
    Req.Test.stub(__MODULE__.EmbeddingHTTP, fn conn ->
      assert conn.request_path == "/v1/embeddings"
      assert conn.body_params["model"] == "Qwen/Qwen3-Embedding-4B"
      assert conn.body_params["input"] == "Hello"

      Req.Test.json(conn, %{
        "data" => [%{"index" => 0, "embedding" => [0.1, 0.2, 0.3]}],
        "usage" => %{"prompt_tokens" => 1, "total_tokens" => 1}
      })
    end)

    assert {:ok, [0.1, 0.2, 0.3]} =
             ReqLLM.embed(embedding_model(), "Hello",
               api_key: "test-key",
               req_http_options: [plug: {Req.Test, __MODULE__.EmbeddingHTTP}]
             )
  end

  test "builds a streaming request for the OpenAI-compatible endpoint" do
    context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

    assert {:ok, request} =
             Superlinked.attach_stream(
               chat_model(),
               context,
               [api_key: "test-key", operation: :chat, stream: true],
               Finch
             )

    assert request.path == "/v1/chat/completions"
    assert {"Authorization", "Bearer test-key"} in request.headers
    assert Jason.decode!(request.body)["stream"] == true
  end

  test "uses the native score path for hosted and custom base URLs" do
    input = %{query: "best city", documents: ["Paris", "Berlin"]}

    assert {:ok, hosted} =
             Superlinked.prepare_request(:rerank, rerank_model(), input, api_key: "test-key")

    assert hosted.url.path == "/score/Qwen%2FQwen3-Reranker-0.6B"
    assert hosted.options[:base_url] == "https://api.superlinked.com/v1"

    assert {:ok, custom} =
             Superlinked.prepare_request(:rerank, rerank_model(), input,
               api_key: "test-key",
               base_url: "http://sie.local:8080/v1/"
             )

    assert custom.options[:base_url] == "http://sie.local:8080/v1/"
  end

  test "reranks documents through the native SIE score contract" do
    Req.Test.stub(__MODULE__.RerankHTTP, fn conn ->
      assert conn.request_path == "/v1/score/Qwen%2FQwen3-Reranker-0.6B"

      assert conn.body_params == %{
               "query" => %{"id" => "query", "text" => "best city"},
               "items" => [
                 %{"id" => "0", "text" => "Paris"},
                 %{"id" => "1", "text" => "Berlin"}
               ]
             }

      Req.Test.json(conn, %{
        "model" => "Qwen/Qwen3-Reranker-0.6B",
        "query_id" => "rerank-sie",
        "scores" => [
          %{"item_id" => "1", "rank" => 0, "score" => 0.99},
          %{"item_id" => "0", "rank" => 1, "score" => 0.98}
        ],
        "usage" => %{"input_tokens" => 12}
      })
    end)

    assert {:ok, response} =
             ReqLLM.rerank(rerank_model(),
               query: "best city",
               documents: ["Paris", "Berlin"],
               top_n: 1,
               api_key: "test-key",
               req_http_options: [plug: {Req.Test, __MODULE__.RerankHTTP}]
             )

    assert response.results == [%{index: 1, relevance_score: 0.99, document: "Berlin"}]
  end

  test "removes max_tokens_per_doc because the native score route does not accept it" do
    input = %{query: "best city", documents: ["Paris", "Berlin"]}

    assert {:ok, request} =
             Superlinked.prepare_request(:rerank, rerank_model(), input,
               api_key: "test-key",
               max_tokens_per_doc: 512,
               on_unsupported: :ignore
             )

    refute Map.has_key?(request.options, :max_tokens_per_doc)
    refute Map.has_key?(Superlinked.build_body(request), :max_tokens_per_doc)
  end

  test "rejects the Cohere priority field before HTTP execution" do
    assert {:error, error} =
             ReqLLM.rerank(rerank_model(),
               query: "best city",
               documents: ["Paris", "Berlin"],
               api_key: "test-key",
               provider_options: [priority: 3]
             )

    assert Exception.message(error) =~ "unknown options"
    assert Exception.message(error) =~ "priority"
  end

  test "retries a provisioning response with Retry-After within the retry limit" do
    attempts = :atomics.new(1, [])

    Req.Test.stub(__MODULE__.ProvisioningHTTP, fn conn ->
      case :atomics.add_get(attempts, 1, 1) do
        1 ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.put_status(503)
          |> Req.Test.json(%{"error" => %{"code" => "PROVISIONING"}})

        2 ->
          Req.Test.json(conn, chat_response())
      end
    end)

    assert {:ok, response} =
             ReqLLM.generate_text(chat_model(), "Hello",
               api_key: "test-key",
               max_retries: 1,
               req_http_options: [plug: {Req.Test, __MODULE__.ProvisioningHTTP}]
             )

    assert ReqLLM.Response.text(response) == "Hello from SIE"
    assert :atomics.get(attempts, 1) == 2
  end

  test "preserves Retry-After when the provisioning retry limit is reached" do
    Req.Test.stub(__MODULE__.ProvisioningErrorHTTP, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "11")
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"error" => %{"code" => "PROVISIONING"}})
    end)

    assert {:error, %ReqLLM.Error.API.Request{} = error} =
             ReqLLM.generate_text(chat_model(), "Hello",
               api_key: "test-key",
               max_retries: 0,
               req_http_options: [plug: {Req.Test, __MODULE__.ProvisioningErrorHTTP}]
             )

    assert error.status == 503

    assert Req.Response.get_header(%Req.Response{headers: error.headers}, "retry-after") == [
             "11"
           ]
  end

  test "does not claim native-only SIE operations" do
    for operation <- [:sparse_embedding, :multivector_embedding, :extract, :ocr] do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Superlinked.prepare_request(operation, chat_model(), "input", api_key: "test-key")
    end
  end

  defp chat_model do
    LLMDB.Model.new!(%{
      id: "Qwen/Qwen3.5-4B",
      provider: :superlinked,
      capabilities: %{chat: true, tools: %{enabled: true}},
      extra: %{wire: %{protocol: "openai_chat"}}
    })
  end

  defp embedding_model do
    LLMDB.Model.new!(%{
      id: "Qwen/Qwen3-Embedding-4B",
      provider: :superlinked,
      capabilities: %{embeddings: true},
      extra: %{wire: %{protocol: "openai_embeddings"}}
    })
  end

  defp rerank_model do
    LLMDB.Model.new!(%{
      id: "Qwen/Qwen3-Reranker-0.6B",
      provider: :superlinked,
      capabilities: %{rerank: true}
    })
  end

  defp chat_response do
    %{
      "id" => "chatcmpl-sie",
      "model" => "Qwen/Qwen3.5-4B",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => "Hello from SIE"},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 3, "total_tokens" => 4}
    }
  end
end

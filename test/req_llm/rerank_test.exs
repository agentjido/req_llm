defmodule ReqLLM.RerankTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Rerank

  defp setup_telemetry do
    test_pid = self()
    ref = System.unique_integer([:positive])
    usage_handler_id = "rerank-usage-handler-#{ref}"
    stop_handler_id = "rerank-stop-handler-#{ref}"

    :telemetry.attach(
      usage_handler_id,
      [:req_llm, :token_usage],
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, name, measurements, metadata})
      end,
      nil
    )

    :telemetry.attach(
      stop_handler_id,
      [:req_llm, :request, :stop],
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(usage_handler_id)
      :telemetry.detach(stop_handler_id)
    end)

    :ok
  end

  describe "validate_model/1" do
    test "accepts inline rerank models outside the catalog" do
      assert {:ok, %LLMDB.Model{provider: :cohere, id: "rerank-v3.5"}} =
               Rerank.validate_model(%{provider: :cohere, id: "rerank-v3.5"})
    end

    test "accepts inline rerank models declared through capabilities" do
      assert {:ok, %LLMDB.Model{provider: :cohere, id: "custom-rerank"}} =
               Rerank.validate_model(%{
                 provider: :cohere,
                 id: "custom-rerank",
                 capabilities: %{rerank: %{enabled: true}}
               })
    end

    test "rejects non-rerank models" do
      assert {:error, error} = Rerank.validate_model("openai:gpt-4o")
      assert Exception.message(error) =~ "does not support reranking operations"
    end
  end

  describe "rerank/2" do
    setup do
      setup_telemetry()

      Req.Test.stub(__MODULE__.SingleBatch, fn conn ->
        body = conn.body_params

        assert conn.request_path == "/v2/rerank"
        assert body["model"] == "rerank-v3.5"
        assert body["query"] == "capital of the United States?"
        assert body["documents"] == ["Carson City", "Washington, D.C.", "Saipan"]
        assert body["top_n"] == 2

        Req.Test.json(conn, %{
          "id" => "rerank-single",
          "results" => [
            %{"index" => 1, "relevance_score" => 0.99},
            %{"index" => 2, "relevance_score" => 0.22}
          ],
          "meta" => %{
            "billed_units" => %{"search_units" => 1},
            "tokens" => %{"input_tokens" => 12},
            "warnings" => ["unit-test"]
          }
        })
      end)

      Req.Test.stub(__MODULE__.Batching, fn conn ->
        body = conn.body_params

        response =
          case body["documents"] do
            ["Doc 1", "Doc 2"] ->
              %{
                "id" => "rerank-batch-1",
                "results" => [
                  %{"index" => 0, "relevance_score" => 0.6},
                  %{"index" => 1, "relevance_score" => 0.4}
                ],
                "meta" => %{"billed_units" => %{"search_units" => 1}}
              }

            ["Doc 3", "Doc 4"] ->
              %{
                "id" => "rerank-batch-2",
                "results" => [
                  %{"index" => 0, "relevance_score" => 0.95},
                  %{"index" => 1, "relevance_score" => 0.85}
                ],
                "meta" => %{
                  "billed_units" => %{"search_units" => 1},
                  "warnings" => ["batch-two"]
                }
              }
          end

        Req.Test.json(conn, response)
      end)

      :ok
    end

    test "rejects non-keyword opts" do
      assert {:error, error} = Rerank.rerank(%{provider: :cohere, id: "rerank-v3.5"}, %{})
      assert Exception.message(error) =~ "expected a keyword list"
    end

    test "rejects empty queries" do
      assert {:error, error} =
               Rerank.rerank(%{provider: :cohere, id: "rerank-v3.5"},
                 query: "",
                 documents: ["Doc"]
               )

      assert Exception.message(error) =~ "query: expected a non-empty string"
    end

    test "rejects invalid documents" do
      assert {:error, error} =
               Rerank.rerank(
                 %{provider: :cohere, id: "rerank-v3.5"},
                 query: "x",
                 documents: ["Doc", 1]
               )

      assert Exception.message(error) =~ "documents: expected a non-empty list of strings"
    end

    test "returns reranked results with original documents attached" do
      {:ok, response} =
        Rerank.rerank(
          %{provider: :cohere, id: "rerank-v3.5"},
          query: "capital of the United States?",
          documents: ["Carson City", "Washington, D.C.", "Saipan"],
          top_n: 2,
          req_http_options: [plug: {Req.Test, __MODULE__.SingleBatch}]
        )

      assert %ReqLLM.RerankResponse{} = response
      assert response.id == "rerank-single"
      assert response.model == "rerank-v3.5"
      assert response.query == "capital of the United States?"

      assert response.results == [
               %{index: 1, relevance_score: 0.99, document: "Washington, D.C."},
               %{index: 2, relevance_score: 0.22, document: "Saipan"}
             ]

      assert response.meta == %{
               billed_units: %{search_units: 1},
               tokens: %{input_tokens: 12},
               warnings: ["unit-test"],
               batch_count: 1
             }
    end

    test "merges batched rankings into a single global result set" do
      {:ok, response} =
        Rerank.rerank(
          %{provider: :cohere, id: "rerank-v3.5"},
          query: "best docs",
          documents: ["Doc 1", "Doc 2", "Doc 3", "Doc 4"],
          batch_size: 2,
          top_n: 2,
          req_http_options: [plug: {Req.Test, __MODULE__.Batching}]
        )

      assert response.id == "rerank-batch-1, rerank-batch-2"

      assert response.results == [
               %{index: 2, relevance_score: 0.95, document: "Doc 3"},
               %{index: 3, relevance_score: 0.85, document: "Doc 4"}
             ]

      assert response.meta == %{
               billed_units: %{search_units: 2},
               warnings: ["batch-two"],
               batch_count: 2
             }
    end

    test "returns request errors for non-success responses" do
      Req.Test.stub(__MODULE__.HTTPError, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => %{"message" => "server error"}})
      end)

      assert {:error, %ReqLLM.Error.API.Request{status: 500, response_body: body}} =
               Rerank.rerank(
                 %{provider: :cohere, id: "rerank-v3.5"},
                 query: "capital of the United States?",
                 documents: ["Carson City", "Washington, D.C.", "Saipan"],
                 req_http_options: [plug: {Req.Test, __MODULE__.HTTPError}]
               )

      assert body == %{"error" => %{"message" => "server error"}}
    end

    test "returns response errors for malformed rerank payloads" do
      Req.Test.stub(__MODULE__.InvalidPayload, fn conn ->
        Req.Test.json(conn, %{"results" => [%{"index" => "bad", "relevance_score" => 0.9}]})
      end)

      assert {:error, %ReqLLM.Error.API.Response{reason: "Invalid rerank response format"}} =
               Rerank.rerank(
                 %{provider: :cohere, id: "rerank-v3.5"},
                 query: "capital of the United States?",
                 documents: ["Carson City", "Washington, D.C.", "Saipan"],
                 req_http_options: [plug: {Req.Test, __MODULE__.InvalidPayload}]
               )
    end

    test "returns response errors when rerank indices do not map to documents" do
      Req.Test.stub(__MODULE__.OutOfRangePayload, fn conn ->
        Req.Test.json(conn, %{"results" => [%{"index" => 9, "relevance_score" => 0.9}]})
      end)

      assert {:error, %ReqLLM.Error.API.Response{reason: "Invalid rerank response format"}} =
               Rerank.rerank(
                 %{provider: :cohere, id: "rerank-v3.5"},
                 query: "capital of the United States?",
                 documents: ["Carson City", "Washington, D.C.", "Saipan"],
                 req_http_options: [plug: {Req.Test, __MODULE__.OutOfRangePayload}]
               )
    end

    test "rejects invalid batch_size values" do
      assert {:error, error} =
               Rerank.rerank(
                 %{provider: :cohere, id: "rerank-v3.5"},
                 query: "x",
                 documents: ["Doc 1"],
                 batch_size: 0
               )

      assert Exception.message(error) =~ "batch_size"
    end

    test "emits usage telemetry for successful rerank requests" do
      assert {:ok, response} =
               Rerank.rerank(
                 %{provider: :cohere, id: "rerank-v3.5"},
                 query: "capital of the United States?",
                 documents: ["Carson City", "Washington, D.C.", "Saipan"],
                 top_n: 2,
                 req_http_options: [plug: {Req.Test, __MODULE__.SingleBatch}]
               )

      assert response.id == "rerank-single"

      assert_receive {:telemetry_event, [:req_llm, :token_usage], measurements, metadata}
      assert measurements.tokens.input_tokens == 12
      assert measurements.tokens.total_tokens == 12
      assert metadata.operation == :rerank
      assert metadata.provider == :cohere

      assert_receive {:telemetry_event, [:req_llm, :request, :stop], _measurements, stop_meta}
      assert stop_meta.operation == :rerank
      assert stop_meta.usage.tokens.input_tokens == 12
      assert stop_meta.usage.tokens.total_tokens == 12
    end
  end

  describe "rerank!/2" do
    test "returns responses on success" do
      Req.Test.stub(__MODULE__.BangSingleBatch, fn conn ->
        Req.Test.json(conn, %{
          "id" => "rerank-single",
          "results" => [%{"index" => 0, "relevance_score" => 0.99}]
        })
      end)

      response =
        Rerank.rerank!(
          %{provider: :cohere, id: "rerank-v3.5"},
          query: "capital",
          documents: ["Washington, D.C."],
          req_http_options: [plug: {Req.Test, __MODULE__.BangSingleBatch}]
        )

      assert response.results == [
               %{index: 0, relevance_score: 0.99, document: "Washington, D.C."}
             ]
    end

    test "raises on errors" do
      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        Rerank.rerank!(%{provider: :cohere, id: "rerank-v3.5"}, query: "", documents: ["Doc"])
      end
    end
  end
end

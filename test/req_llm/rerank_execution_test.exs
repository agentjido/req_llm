defmodule ReqLLM.RerankExecutionTest do
  use ExUnit.Case, async: true

  alias ReqLLM.RerankResponse
  alias ReqLLM.Test.WorkflowHTTP

  @moduletag contract: :public_api
  @model %{provider: :rerank_execution_test, id: "custom-ranker", capabilities: %{rerank: true}}

  defmodule Provider do
    use ReqLLM.Provider,
      id: :rerank_execution_test,
      default_base_url: "https://rerank.example"

    @impl true
    def prepare_request(operation, model, input, opts) do
      Keyword.fetch!(opts, :prepare).(operation, model, input, opts)
    end
  end

  setup_all do
    ReqLLM.Providers.register!(Provider)
    on_exit(fn -> ReqLLM.Providers.unregister(:rerank_execution_test) end)
  end

  test "merges three batches with stable global indices, top_n, usage and callback options" do
    owner = self()
    schema = NimbleOptions.new!(value: [type: :string])
    http_options = %{receive_timeout: 1234}

    prepare = fn :rerank, model, %{query: "rank", documents: documents}, opts ->
      send(owner, {:prepared, model, documents, opts})

      body =
        case documents do
          ["zero", "one"] ->
            %{"id" => "a", "results" => [%{"index" => 1, "relevance_score" => 0.9}]}

          ["two", "three"] ->
            %{"id" => "b", "results" => [%{"index" => 1, "relevance_score" => 0.9}]}

          ["four"] ->
            %{"id" => "c", "results" => [%{"index" => 0, "relevance_score" => 0.95}]}
        end

      response = %Req.Response{
        status: 201,
        body: body,
        private: %{req_llm: %{usage: %{input_cost: 0.25, total_cost: 0.25}}}
      }

      {:ok, request(response)}
    end

    assert {:ok,
            %RerankResponse{
              id: "a, b, c",
              model: "custom-ranker",
              query: "rank",
              results: [
                %{index: 4, document: "four", relevance_score: 0.95},
                %{index: 1, document: "one", relevance_score: 0.9}
              ],
              meta: %{batch_count: 3, input_cost: 0.75, total_cost: 0.75}
            }} =
             ReqLLM.rerank(@model,
               query: "rank",
               documents: ["zero", "one", "two", "three", "four"],
               batch_size: 2,
               top_n: 2,
               prepare: prepare,
               schema: schema,
               req_http_options: http_options,
               duplicate: :first,
               duplicate: :second
             )

    for documents <- [["zero", "one"], ["two", "three"], ["four"]] do
      assert_receive {:prepared, %LLMDB.Model{id: "custom-ranker"}, ^documents, opts}
      refute Keyword.has_key?(opts, :top_n)
      refute Keyword.has_key?(opts, :batch_size)
      refute Keyword.has_key?(opts, :query)
      refute Keyword.has_key?(opts, :documents)
      assert opts[:schema] == schema
      assert opts[:req_http_options] == http_options
      assert Keyword.get_values(opts, :duplicate) == [:first, :second]
    end

    refute_received {:prepared, _, _, _}
  end

  test "keeps top_n on a single batch" do
    prepare = fn :rerank, _model, %{documents: ["one"]}, opts ->
      assert opts[:top_n] == 1
      {:ok, request(%Req.Response{status: 200, body: %{"results" => []}})}
    end

    assert {:ok, %RerankResponse{results: [], meta: %{batch_count: 1}}} =
             ReqLLM.rerank(@model, query: "rank", documents: ["one"], top_n: 1, prepare: prepare)
  end

  test "halts on a failing batch without returning earlier results or sending later batches" do
    owner = self()
    body = %{"error" => "second batch rejected"}

    prepare = fn :rerank, _model, %{documents: documents}, _opts ->
      send(owner, {:batch, documents})

      response =
        case documents do
          ["one"] -> %Req.Response{status: 200, body: %{"results" => []}}
          ["two"] -> %Req.Response{status: 422, body: body}
        end

      {:ok, request(response)}
    end

    assert {:error,
            %ReqLLM.Error.API.Request{
              status: 422,
              reason: "HTTP 422: Rerank request failed",
              response_body: ^body
            } = error} =
             ReqLLM.rerank(@model,
               query: "rank",
               documents: ["one", "two", "three"],
               batch_size: 1,
               prepare: prepare
             )

    assert Exception.message(error) == "API request failed (422): HTTP 422: Rerank request failed"
    assert_receive {:batch, ["one"]}
    assert_receive {:batch, ["two"]}
    refute_received {:batch, _}
  end

  test "passes preparation and transport errors through unchanged" do
    for error <- [{:provider_rejected, :documents}, %Req.TransportError{reason: :closed}] do
      prepare = fn :rerank, _model, _input, _opts ->
        case error do
          %Req.TransportError{} ->
            {:ok, WorkflowHTTP.request(error)}

          _ ->
            {:error, error}
        end
      end

      assert ReqLLM.rerank(@model, query: "rank", documents: ["one"], prepare: prepare) ==
               {:error, error}
    end
  end

  test "shares the original total timeout across batches and preparation" do
    owner = self()

    prepare = fn :rerank, _model, %{documents: documents}, _opts ->
      send(owner, {:prepared_batch, documents})

      case documents do
        ["one"] ->
          {:ok,
           WorkflowHTTP.request(fn request ->
             Process.sleep(50)
             {request, %Req.Response{status: 200, body: %{"results" => []}}}
           end)}

        ["two"] ->
          Process.sleep(50)

          {:ok,
           WorkflowHTTP.request(fn request ->
             send(owner, :unexpected_second_batch_request)
             {request, %Req.Response{status: 200, body: %{"results" => []}}}
           end)}
      end
    end

    assert {:error, %ReqLLM.Error.API.Timeout{kind: :total, timeout: 80}} =
             ReqLLM.rerank(@model,
               query: "rank",
               documents: ["one", "two"],
               batch_size: 1,
               total_timeout: 80,
               prepare: prepare
             )

    assert_receive {:prepared_batch, ["one"]}
    assert_receive {:prepared_batch, ["two"]}
    refute_received :unexpected_second_batch_request
  end

  defp request(response) do
    WorkflowHTTP.request(response)
  end
end

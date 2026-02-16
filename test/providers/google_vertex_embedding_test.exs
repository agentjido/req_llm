defmodule ReqLLM.Providers.GoogleVertex.EmbeddingTest do
  @moduledoc """
  Unit tests for Google Vertex AI embedding support.

  Tests the prepare_request/4, request body building, and response
  normalization for the :predict endpoint used by Vertex AI embeddings.
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Providers.GoogleVertex

  @model_spec "google_vertex:gemini-embedding-001"

  @base_opts [
    access_token: "test-token",
    project_id: "test-project",
    region: "us-central1"
  ]

  describe "prepare_request(:embedding, ...) single text" do
    test "builds correct predict endpoint URL" do
      {:ok, request} =
        GoogleVertex.prepare_request(:embedding, @model_spec, "Hello world", @base_opts)

      url = URI.to_string(request.url)

      assert url =~
               "us-central1-aiplatform.googleapis.com/v1/projects/test-project/locations/us-central1/publishers/google/models/gemini-embedding-001:predict"
    end

    test "formats single text as instances array" do
      {:ok, request} =
        GoogleVertex.prepare_request(:embedding, @model_spec, "Hello world", @base_opts)

      body = request.options[:json]
      assert %{"instances" => [%{"content" => "Hello world"}]} = body
    end

    test "includes outputDimensionality in parameters when dimensions specified" do
      opts = @base_opts ++ [dimensions: 768]

      {:ok, request} =
        GoogleVertex.prepare_request(:embedding, @model_spec, "Hello", opts)

      body = request.options[:json]
      assert %{"parameters" => %{"outputDimensionality" => 768}} = body
    end

    test "includes task_type in instance when specified" do
      opts = @base_opts ++ [task_type: "RETRIEVAL_QUERY"]

      {:ok, request} =
        GoogleVertex.prepare_request(:embedding, @model_spec, "Hello", opts)

      body = request.options[:json]
      assert %{"instances" => [%{"content" => "Hello", "task_type" => "RETRIEVAL_QUERY"}]} = body
    end
  end

  describe "prepare_request(:embedding, ...) batch texts" do
    test "formats multiple texts as instances array" do
      texts = ["Hello", "World", "Test"]

      {:ok, request} =
        GoogleVertex.prepare_request(:embedding, @model_spec, texts, @base_opts)

      body = request.options[:json]

      assert %{
               "instances" => [
                 %{"content" => "Hello"},
                 %{"content" => "World"},
                 %{"content" => "Test"}
               ]
             } = body
    end

    test "applies task_type to all instances in batch" do
      opts = @base_opts ++ [task_type: "RETRIEVAL_DOCUMENT"]

      {:ok, request} =
        GoogleVertex.prepare_request(:embedding, @model_spec, ["A", "B"], opts)

      body = request.options[:json]
      instances = body["instances"]

      Enum.each(instances, fn instance ->
        assert instance["task_type"] == "RETRIEVAL_DOCUMENT"
      end)
    end
  end

  describe "prepare_request(:embedding, ...) with global region" do
    test "uses global base URL" do
      opts = Keyword.put(@base_opts, :region, "global")

      {:ok, request} =
        GoogleVertex.prepare_request(:embedding, @model_spec, "Hello", opts)

      url = URI.to_string(request.url)
      assert url =~ "aiplatform.googleapis.com/v1/projects/test-project/locations/global"
    end
  end

  describe "prepare_request(:embedding, ...) credentials" do
    test "raises without project_id" do
      assert_raise ArgumentError, ~r/project ID required/, fn ->
        GoogleVertex.prepare_request(:embedding, @model_spec, "Hello", access_token: "tok")
      end
    end
  end

  describe "decode_embedding_response/1" do
    test "normalizes single prediction to OpenAI format" do
      body = %{
        "predictions" => [
          %{
            "embeddings" => %{
              "values" => [0.1, -0.2, 0.3],
              "statistics" => %{"token_count" => 2}
            }
          }
        ]
      }

      request = %Req.Request{options: %{operation: :embedding}}
      response = %Req.Response{status: 200, body: body}

      {_req, decoded} = GoogleVertex.decode_embedding_response({request, response})

      assert %{"data" => [%{"index" => 0, "embedding" => [0.1, -0.2, 0.3]}]} = decoded.body
    end

    test "normalizes multiple predictions preserving order" do
      body = %{
        "predictions" => [
          %{"embeddings" => %{"values" => [0.1, 0.2]}},
          %{"embeddings" => %{"values" => [0.3, 0.4]}},
          %{"embeddings" => %{"values" => [0.5, 0.6]}}
        ]
      }

      request = %Req.Request{options: %{operation: :embedding}}
      response = %Req.Response{status: 200, body: body}

      {_req, decoded} = GoogleVertex.decode_embedding_response({request, response})

      assert %{"data" => data} = decoded.body
      assert length(data) == 3
      assert Enum.at(data, 0)["index"] == 0
      assert Enum.at(data, 1)["index"] == 1
      assert Enum.at(data, 2)["index"] == 2
      assert Enum.at(data, 0)["embedding"] == [0.1, 0.2]
      assert Enum.at(data, 2)["embedding"] == [0.5, 0.6]
    end

    test "passes through non-200 responses unchanged" do
      request = %Req.Request{options: %{operation: :embedding}}
      response = %Req.Response{status: 400, body: %{"error" => "bad request"}}

      {_req, decoded} = GoogleVertex.decode_embedding_response({request, response})
      assert decoded.body == %{"error" => "bad request"}
    end
  end
end

defmodule ReqLLM.Providers.AmazonBedrock.CohereTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.AmazonBedrock.Cohere

  describe "format_embedding_request/3" do
    test "formats single text input" do
      {:ok, result} = Cohere.format_embedding_request("cohere.embed-v4:0", "Hello world", [])

      assert result["texts"] == ["Hello world"]
      assert result["input_type"] == "search_document"
      assert result["embedding_types"] == ["float"]
    end

    test "formats list of texts" do
      texts = ["Hello", "World"]
      {:ok, result} = Cohere.format_embedding_request("cohere.embed-v4:0", texts, [])

      assert result["texts"] == ["Hello", "World"]
    end

    test "uses custom input_type from provider_options" do
      opts = [provider_options: [input_type: "search_query"]]
      {:ok, result} = Cohere.format_embedding_request("cohere.embed-v4:0", "query", opts)

      assert result["input_type"] == "search_query"
    end

    test "uses custom embedding_types from provider_options" do
      opts = [provider_options: [embedding_types: ["float", "int8"]]]
      {:ok, result} = Cohere.format_embedding_request("cohere.embed-v4:0", "text", opts)

      assert result["embedding_types"] == ["float", "int8"]
    end

    test "includes dimensions when specified" do
      opts = [dimensions: 512]
      {:ok, result} = Cohere.format_embedding_request("cohere.embed-v4:0", "text", opts)

      assert result["output_dimension"] == 512
    end

    test "includes truncate when specified" do
      opts = [provider_options: [truncate: "LEFT"]]
      {:ok, result} = Cohere.format_embedding_request("cohere.embed-v4:0", "text", opts)

      assert result["truncate"] == "LEFT"
    end

    test "includes max_tokens when specified" do
      opts = [provider_options: [max_tokens: 1024]]
      {:ok, result} = Cohere.format_embedding_request("cohere.embed-v4:0", "text", opts)

      assert result["max_tokens"] == 1024
    end

    test "formats image-only input" do
      opts = [provider_options: [images: ["data:image/png;base64,abc123"]]]
      {:ok, result} = Cohere.format_embedding_request("cohere.embed-v4:0", [], opts)

      assert result["images"] == ["data:image/png;base64,abc123"]
      refute Map.has_key?(result, "texts")
    end

    test "formats mixed content input" do
      inputs = [
        %{
          content: [
            %{type: "text", text: "A cat"},
            %{type: "image_url", image_url: "data:image/png;base64,xyz"}
          ]
        }
      ]

      opts = [provider_options: [inputs: inputs]]
      {:ok, result} = Cohere.format_embedding_request("cohere.embed-v4:0", [], opts)

      assert [%{"content" => content}] = result["inputs"]
      assert [%{"type" => "text", "text" => "A cat"}, %{"type" => "image_url"}] = content
    end

    test "returns error for invalid dimension" do
      opts = [dimensions: 999]
      {:error, error} = Cohere.format_embedding_request("cohere.embed-v4:0", "text", opts)

      assert error.__struct__ == ReqLLM.Error.Validation.Error
      assert error.tag == :invalid_embedding_request
    end

    test "returns error for invalid input_type" do
      opts = [provider_options: [input_type: "invalid"]]
      {:error, error} = Cohere.format_embedding_request("cohere.embed-v4:0", "text", opts)

      assert error.__struct__ == ReqLLM.Error.Validation.Error
    end
  end

  describe "parse_embedding_response/1" do
    test "parses response with float embeddings nested" do
      response = %{
        "embeddings" => %{"float" => [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]]},
        "texts" => ["Hello", "World"]
      }

      {:ok, result} = Cohere.parse_embedding_response(response)

      assert result["data"] == [
               %{"index" => 0, "embedding" => [0.1, 0.2, 0.3]},
               %{"index" => 1, "embedding" => [0.4, 0.5, 0.6]}
             ]
    end

    test "parses response with flat embeddings list" do
      response = %{
        "embeddings" => [[0.1, 0.2], [0.3, 0.4]]
      }

      {:ok, result} = Cohere.parse_embedding_response(response)

      assert result["data"] == [
               %{"index" => 0, "embedding" => [0.1, 0.2]},
               %{"index" => 1, "embedding" => [0.3, 0.4]}
             ]
    end

    test "returns error for invalid response format" do
      response = %{"unexpected" => "format"}
      {:error, error} = Cohere.parse_embedding_response(response)

      assert error.__struct__ == ReqLLM.Error.API.Response
    end

    test "returns error for non-map response" do
      {:error, error} = Cohere.parse_embedding_response("not a map")

      assert error.__struct__ == ReqLLM.Error.API.Response
      assert error.reason =~ "Expected map response"
    end
  end

  describe "schema accessors" do
    test "embedding_request_schema returns Zoi schema" do
      schema = Cohere.embedding_request_schema()
      assert is_struct(schema)
    end

    test "embedding_response_schema returns Zoi schema" do
      schema = Cohere.embedding_response_schema()
      assert is_struct(schema)
    end
  end
end

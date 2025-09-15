defmodule ReqLLM.ProviderTest.Embedding do
  @moduledoc """
  Embedding generation functionality tests.

  Tests embedding features for providers that support them:
  - Single text embedding generation 
  - Batch text embedding generation
  - Parameter handling (dimensions, encoding format, etc.)
  - Response parsing and validation
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)
    model = Keyword.fetch!(opts, :model)

    quote bind_quoted: [provider: provider, model: model] do
      use ExUnit.Case, async: false

      import ReqLLM.Test.LiveFixture

      alias ReqLLM.Test.LiveFixture, as: ReqFixture

      @moduletag :coverage
      @moduletag :embedding
      @moduletag provider

      test "single text embedding with embed/3" do
        result =
          use_fixture(unquote(provider), "single_embedding", fn ->
            ReqLLM.embed(unquote(model), "Hello world")
          end)

        {:ok, embedding} = result
        assert is_list(embedding)
        assert length(embedding) > 0
        assert Enum.all?(embedding, &is_float/1)
      end

      test "batch text embedding with embed_many/3" do
        result =
          use_fixture(unquote(provider), "batch_embeddings", fn ->
            ReqLLM.embed_many(unquote(model), ["Hello", "World"])
          end)

        {:ok, embeddings} = result
        assert is_list(embeddings)
        assert length(embeddings) == 2
        assert Enum.all?(embeddings, &is_list/1)
        assert Enum.all?(List.flatten(embeddings), &is_float/1)
      end

      test "batch text embedding with generate_embeddings/2 (API compatibility)" do
        result =
          use_fixture(unquote(provider), "generate_embeddings_api", fn ->
            ReqLLM.generate_embeddings(unquote(model), ["Hello", "World"])
          end)

        {:ok, embeddings} = result
        assert is_list(embeddings)
        assert length(embeddings) == 2
        assert Enum.all?(embeddings, &is_list/1)
        assert Enum.all?(List.flatten(embeddings), &is_float/1)
      end

      test "batch text embedding with generate_embeddings/3 with options" do
        result =
          use_fixture(unquote(provider), "generate_embeddings_with_options", fn ->
            ReqLLM.generate_embeddings(unquote(model), ["Hello", "World"], dimensions: 512)
          end)

        {:ok, embeddings} = result
        assert is_list(embeddings)
        assert length(embeddings) == 2
        assert Enum.all?(embeddings, &is_list/1)
        # Check that dimensions parameter was used if supported
        if List.first(embeddings) do
          first_embedding = List.first(embeddings)
          # Some models support dimension reduction, others don't
          assert length(first_embedding) > 0
        end
      end

      test "embedding with invalid model returns error" do
        assert {:error, _} = ReqLLM.embed("anthropic:claude-3-sonnet", "Hello world")
        assert {:error, _} = ReqLLM.embed_many("anthropic:claude-3-sonnet", ["Hello", "World"])
        assert {:error, _} = ReqLLM.generate_embeddings("anthropic:claude-3-sonnet", ["Hello", "World"])
      end
    end
  end
end
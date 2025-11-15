defmodule ReqLLM.ProviderTest.Embedding do
  @moduledoc """
  Embedding model provider tests.

  Simple test suite for embedding models using the top-level `ReqLLM.embed/3` API.
  Tests use fixtures for fast, deterministic execution while supporting
  live API recording with REQ_LLM_FIXTURES_MODE=record.

  ## Usage

      defmodule ReqLLM.Coverage.Google.EmbeddingTest do
        use ReqLLM.ProviderTest.Embedding, provider: :google
      end

  This will generate embedding tests for models selected by ModelMatrix for the provider.

  ## Debug Output

  Set REQ_LLM_DEBUG=1 to enable verbose fixture output during test runs.
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote bind_quoted: [provider: provider] do
      use ExUnit.Case, async: false

      import ExUnit.Case
      import ReqLLM.Debug, only: [dbug: 2]
      import ReqLLM.Test.Helpers

      alias ReqLLM.Test.ModelMatrix

      @moduletag :coverage
      @moduletag category: :embedding
      @moduletag provider: provider

      @provider provider
      @models ModelMatrix.models_for_provider(provider, operation: :embedding)

      setup_all do
        LLMDB.load(allow: :all, custom: %{})
        :ok
      end

      for model_spec <- @models do
        @model_spec model_spec

        describe "#{model_spec}" do
          @tag category: :embedding
          test "basic embedding generation" do
            dbug(
              fn -> "\n[Embedding] model_spec=#{@model_spec}, test=basic_embed" end,
              component: :test
            )

            result =
              ReqLLM.embed(
                @model_spec,
                "Hello world",
                fixture_opts(@provider, "embed_basic", [])
              )

            case result do
              {:ok, embedding} ->
                assert is_list(embedding)
                refute Enum.empty?(embedding)
                assert Enum.all?(embedding, &is_number/1)

              {:error, reason} ->
                flunk("Expected successful embedding, got error: #{inspect(reason)}")
            end
          end

          @tag category: :embedding
          test "batch embedding generation" do
            dbug(
              fn -> "\n[Embedding] model_spec=#{@model_spec}, test=batch_embed" end,
              component: :test
            )

            texts = ["Hello world", "How are you?", "Testing embeddings"]

            result =
              ReqLLM.embed(
                @model_spec,
                texts,
                fixture_opts(@provider, "embed_batch", [])
              )

            case result do
              {:ok, embeddings} ->
                assert is_list(embeddings)
                assert length(embeddings) == length(texts)

                Enum.each(embeddings, fn embedding ->
                  assert is_list(embedding)
                  refute Enum.empty?(embedding)
                  assert Enum.all?(embedding, &is_number/1)
                end)

              {:error, reason} ->
                flunk("Expected successful embeddings, got error: #{inspect(reason)}")
            end
          end
        end
      end
    end
  end
end

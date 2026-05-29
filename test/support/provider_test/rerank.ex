defmodule ReqLLM.ProviderTest.Rerank do
  @moduledoc """
  Rerank provider coverage tests.

  Exercises the top-level `ReqLLM.rerank/2` API with fixture-backed recording
  and replay.
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote bind_quoted: [provider: provider] do
      use ExUnit.Case, async: false

      import ExUnit.Case
      import ReqLLM.Test.Helpers

      alias ReqLLM.Test.ModelMatrix

      @moduletag :coverage
      @moduletag category: :rerank
      @moduletag provider: provider
      @moduletag timeout: 120_000

      @provider provider
      @models ModelMatrix.models_for_provider(provider, operation: :rerank)

      setup_all do
        LLMDB.load(allow: :all, custom: Application.get_env(:llm_db, :custom, %{}))
        :ok
      end

      for model_spec <- @models do
        @model_spec model_spec

        describe "#{model_spec}" do
          @tag category: :rerank
          @tag scenario: :rerank_basic
          @tag model: model_spec |> String.split(":", parts: 2) |> List.last()
          test "basic rerank" do
            {:ok, response} =
              ReqLLM.rerank(
                @model_spec,
                fixture_opts(@provider, "rerank_basic",
                  query: "capital of the United States",
                  documents: ["Carson City", "Washington, D.C.", "Saipan"],
                  top_n: 2
                )
              )

            assert %ReqLLM.RerankResponse{} = response
            refute Enum.empty?(response.results)
            assert Enum.all?(response.results, &is_number(&1.relevance_score))
            assert Enum.any?(response.results, &(&1.document == "Washington, D.C."))
          end
        end
      end
    end
  end
end

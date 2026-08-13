defmodule ReqLLM.ProviderTest.Video do
  @moduledoc """
  Video generation provider coverage tests.

  The suite accepts an explicit `:models` option because video generation
  support currently targets provider-hosted models that may not be listed
  under the provider's catalog entry yet.

  Video generation is asynchronous: the coverage test submits a task, waits
  for it to complete, and asserts the returned download URL.
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)
    models = Keyword.get(opts, :models, [])

    quote bind_quoted: [provider: provider, models: models] do
      use ExUnit.Case, async: false

      import ExUnit.Case
      import ReqLLM.Test.Helpers

      @moduletag :coverage
      @moduletag category: :video
      @moduletag provider: provider
      @moduletag timeout: 300_000

      @provider provider
      @models models

      setup_all do
        LLMDB.load(allow: :all, custom: Application.get_env(:llm_db, :custom, %{}))
        :ok
      end

      for model_spec <- @models do
        @model_spec model_spec

        describe "#{inspect(model_spec)}" do
          @tag category: :video
          @tag ReqLLM.Test.CompatibilityScenario.tag!(:video_basic)
          test "basic video generation" do
            {:ok, task} =
              ReqLLM.Video.generate_video(
                @model_spec,
                [prompt: "A red ball bouncing on a beach at sunset"],
                duration: 4,
                resolution: "768P",
                ratio: "16:9"
              )

            assert is_binary(task.task_id)

            {:ok, completed} =
              ReqLLM.Video.wait_video(@model_spec, task.task_id, timeout: 240_000)

            assert completed.status == :succeeded
            assert is_binary(completed.url)
          end
        end
      end
    end
  end
end

defmodule ReqLLM.ProviderTest.ImageGeneration do
  @moduledoc """
  Image generation provider coverage tests.

  Exercises the top-level `ReqLLM.generate_image/3` API with fixture-backed
  recording and replay.
  """

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote bind_quoted: [provider: provider] do
      use ExUnit.Case, async: false

      import ExUnit.Case
      import ReqLLM.Test.Helpers

      alias ReqLLM.Test.ModelMatrix

      @moduletag :coverage
      @moduletag category: :image
      @moduletag provider: provider
      @moduletag timeout: 180_000

      @provider provider
      @models ModelMatrix.models_for_provider(provider, operation: :image)

      setup_all do
        LLMDB.load(allow: :all, custom: Application.get_env(:llm_db, :custom, %{}))
        :ok
      end

      for model_spec <- @models do
        @model_spec model_spec

        describe "#{model_spec}" do
          @tag category: :image
          @tag scenario: :image_basic
          @tag model: model_spec |> String.split(":", parts: 2) |> List.last()
          test "basic image generation" do
            {:ok, response} =
              ReqLLM.generate_image(
                @model_spec,
                ReqLLM.ProviderTest.ImageGeneration.prompt(@provider),
                fixture_opts(@provider, "image_basic", [])
              )

            images = ReqLLM.Response.images(response)

            refute Enum.empty?(images)

            Enum.each(images, fn part ->
              assert part.type in [:image, :image_url]

              case part.type do
                :image ->
                  assert is_binary(part.data) and byte_size(part.data) > 0
                  assert is_binary(part.media_type) and part.media_type != ""

                :image_url ->
                  assert is_binary(part.url) and part.url =~ ~r/^https?:\/\//
              end
            end)
          end
        end
      end
    end
  end

  @doc false
  def prompt(:google), do: "A simple blue square on a white background"
  def prompt(:xai), do: "A simple green square on a white background"
  def prompt(_provider), do: "A simple red square on a white background"
end

defmodule ReqLLM.Coverage.OpenAI.ImageGenerationTest do
  use ExUnit.Case, async: true

  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: "openai"
  @moduletag timeout: 180_000

  @model_spec "openai:gpt-image-1.5"
  @source_image_path Path.expand("../../../priv/examples/test.jpg", __DIR__)

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  @tag scenario: :image_basic
  @tag model: "gpt-image-1.5"
  test "generate_image/3 returns a Response with one image part and usage data" do
    {:ok, response} =
      ReqLLM.generate_image(
        @model_spec,
        "A simple red square",
        fixture_opts("image_basic")
      )

    [part] = ReqLLM.Response.images(response)
    assert part.type == :image
    assert is_binary(part.media_type) and part.media_type != ""
    assert is_binary(part.data) and byte_size(part.data) > 0
    assert response.usage.image_usage.generated.count == 1
    assert response.usage.cost.images > 0
  end

  @tag scenario: :image_edit
  @tag model: "gpt-image-1.5"
  test "generate_image/3 edits a source image and returns a Response with image data" do
    source_image = File.read!(@source_image_path)

    {:ok, response} =
      ReqLLM.generate_image(
        @model_spec,
        "Use this image as a reference and add a small blue circle in the center",
        fixture_opts("image_edit",
          source_image: source_image,
          source_image_media_type: "image/jpeg"
        )
      )

    [part] = ReqLLM.Response.images(response)
    assert part.type == :image
    assert is_binary(part.media_type) and part.media_type != ""
    assert is_binary(part.data) and byte_size(part.data) > 0
    assert response.usage.image_usage.generated.count == 1
    assert response.usage.cost.images > 0
  end
end

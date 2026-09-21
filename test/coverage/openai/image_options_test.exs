defmodule ReqLLM.Coverage.OpenAI.ImageOptionsTest do
  @moduledoc """
  OpenAI gpt-image option coverage tests.

  Proves against the live Images API that the gpt-image-only options reach the
  wire and take effect: a `background: :transparent` request comes back as a PNG
  with an alpha channel and the response echoes the resolved options.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag category: :image
  @moduletag provider: "openai"
  @moduletag timeout: 180_000

  @model_spec "openai:gpt-image-1.5"

  @png_signature <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
  @png_color_types_with_alpha [4, 6]

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:image_transparent_background)
  @tag model: "gpt-image-1.5"
  test "a transparent background produces a PNG with an alpha channel" do
    opts =
      fixture_opts(ReqLLM.Test.CompatibilityScenario.fixture!(:image_transparent_background),
        background: :transparent,
        quality: :low,
        size: "1024x1024"
      )

    {:ok, response} =
      ReqLLM.generate_image(
        @model_spec,
        "A single red circle sticker, isolated on a fully transparent background",
        opts
      )

    [part] = ReqLLM.Response.images(response)

    assert part.type == :image
    assert part.media_type == "image/png"

    assert <<@png_signature, _length::32, "IHDR", _width::32, _height::32, _bit_depth, color_type,
             _rest::binary>> = part.data

    assert color_type in @png_color_types_with_alpha

    meta = response.provider_meta["openai"]
    assert meta["background"] == "transparent"
    assert meta["output_format"] == "png"
    assert meta["quality"] == "low"
    assert meta["size"] == "1024x1024"
  end
end

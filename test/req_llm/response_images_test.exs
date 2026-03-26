defmodule ReqLLM.ResponseImagesTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response

  test "images/1 extracts image and image_url content parts" do
    message = %Message{
      role: :assistant,
      content: [
        ContentPart.text("hi"),
        ContentPart.image(<<1, 2, 3>>, "image/png"),
        ContentPart.image_url("https://example.com/image.png")
      ]
    }

    response = %Response{
      id: "resp_1",
      model: "test",
      context: %Context{messages: [message]},
      message: message,
      object: nil,
      stream?: false,
      stream: nil,
      usage: nil,
      finish_reason: :stop,
      provider_meta: %{},
      error: nil
    }

    parts = Response.images(response)
    assert Enum.count(parts) == 2
    assert Response.image_data(response) == <<1, 2, 3>>
    assert Response.image_url(response) == "https://example.com/image.png"
  end
end

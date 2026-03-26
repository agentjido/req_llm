defmodule ReqLLM.Providers.OpenAIImagesTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Providers.OpenAI.ImagesAPI
  alias ReqLLM.Response

  test "encode_body/1 builds OpenAI images request JSON" do
    request =
      Req.new(url: ImagesAPI.path())
      |> Req.Request.register_options([
        :model,
        :prompt,
        :n,
        :size,
        :response_format,
        :output_format,
        :context
      ])
      |> Req.Request.merge_options(
        model: "gpt-image-1",
        prompt: "A lighthouse in a storm",
        n: 1,
        size: "1024x1024",
        response_format: :binary,
        output_format: :png,
        context: %Context{messages: []}
      )

    encoded = ImagesAPI.encode_body(request)
    body = Jason.decode!(encoded.body)

    assert body["model"] == "gpt-image-1"
    assert body["prompt"] == "A lighthouse in a storm"
    assert body["n"] == 1
    assert body["size"] == "1024x1024"
    assert Map.has_key?(body, "response_format") == false
  end

  test "encode_body/1 includes response_format for dall-e models" do
    request =
      Req.new(url: ImagesAPI.path())
      |> Req.Request.register_options([:model, :prompt, :n, :response_format, :context])
      |> Req.Request.merge_options(
        model: "dall-e-3",
        prompt: "A lighthouse in a storm",
        n: 1,
        response_format: :binary,
        context: %Context{messages: []}
      )

    encoded = ImagesAPI.encode_body(request)
    body = Jason.decode!(encoded.body)

    assert body["model"] == "dall-e-3"
    assert body["response_format"] == "b64_json"
  end

  test "decode_response/1 converts b64_json to ContentPart.image with revised_prompt metadata" do
    req =
      Req.new(url: ImagesAPI.path())
      |> Req.Request.register_options([:model, :output_format, :context])
      |> Req.Request.merge_options(
        model: "gpt-image-1",
        output_format: :png,
        context: %Context{messages: []}
      )

    resp = %Req.Response{
      status: 200,
      headers: [],
      body: %{
        "created" => 1_234,
        "data" => [
          %{"b64_json" => Base.encode64("abc"), "revised_prompt" => "revised"}
        ]
      }
    }

    {_req, updated} = ImagesAPI.decode_response({req, resp})

    assert %Response{} = updated.body
    assert Response.image_data(updated.body) == "abc"

    [part] = Response.images(updated.body)
    assert part.type == :image
    assert part.metadata["revised_prompt"] == nil
    assert part.metadata[:revised_prompt] == "revised"
  end
end

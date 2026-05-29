defmodule ReqLLM.Providers.OpenAIImagesTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Providers.OpenAI
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
    body = ReqLLM.Test.Helpers.json_body(encoded)

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
    body = ReqLLM.Test.Helpers.json_body(encoded)

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

  test "prepare_request/4 keeps prompt-only image generation on generations JSON endpoint" do
    model = %LLMDB.Model{id: "gpt-image-1.5", provider: :openai}

    assert {:ok, request} =
             OpenAI.prepare_request(:image, model, "A lighthouse in a storm", api_key: "test-key")

    assert request.url.path == "/images/generations"
    assert Map.get(request.options, :form_multipart) == nil
    assert Req.Request.get_header(request, "content-type") == ["application/json"]
  end

  test "prepare_request/4 sends source_image requests to edits multipart endpoint" do
    model = %LLMDB.Model{id: "gpt-image-1.5", provider: :openai}
    source_image = <<1, 2, 3>>

    assert {:ok, request} =
             OpenAI.prepare_request(:image, model, "Make this watercolor",
               api_key: "test-key",
               source_image: source_image,
               source_image_media_type: "image/jpeg",
               size: {1024, 1536},
               quality: "high",
               output_format: :webp,
               user: "user-123"
             )

    assert request.url.path == "/images/edits"
    assert Req.Request.get_header(request, "content-type") == []

    form_parts = request.options.form_multipart
    assert form_parts[:model] == "gpt-image-1.5"
    assert form_parts[:prompt] == "Make this watercolor"
    assert form_parts[:size] == "1024x1536"
    assert form_parts[:quality] == "high"
    assert form_parts[:output_format] == "webp"
    assert form_parts[:user] == "user-123"

    assert {^source_image, image_opts} = form_parts[:image]
    assert image_opts[:filename] == "source_image.jpg"
    assert image_opts[:content_type] == "image/jpeg"
  end

  test "prepare_request/4 includes mask multipart part when provided" do
    model = %LLMDB.Model{id: "gpt-image-1.5", provider: :openai}
    source_image = <<1, 2, 3>>
    mask = <<4, 5, 6>>

    assert {:ok, request} =
             OpenAI.prepare_request(:image, model, "Replace the background",
               api_key: "test-key",
               source_image: source_image,
               mask: mask,
               mask_media_type: "image/png"
             )

    assert {^mask, mask_opts} = request.options.form_multipart[:mask]
    assert mask_opts[:filename] == "mask.png"
    assert mask_opts[:content_type] == "image/png"
  end

  test "prepare_request/4 includes requested output_format for edit requests" do
    model = %LLMDB.Model{id: "chatgpt-image-latest", provider: :openai}

    assert {:ok, request} =
             OpenAI.prepare_request(:image, model, "Make this watercolor",
               api_key: "test-key",
               source_image: <<1, 2, 3>>,
               output_format: :png
             )

    form_parts = request.options.form_multipart
    assert form_parts[:output_format] == "png"
    refute Keyword.has_key?(form_parts, :response_format)
  end

  test "decode_response/1 decodes edit b64_json responses" do
    req =
      Req.new(url: ImagesAPI.path(:edit))
      |> Req.Request.register_options([:model, :output_format, :context])
      |> Req.Request.merge_options(
        model: "gpt-image-1.5",
        output_format: :png,
        context: %Context{messages: []}
      )

    resp = %Req.Response{
      status: 200,
      headers: [],
      body: %{"data" => [%{"b64_json" => Base.encode64("edit-bytes")}]}
    }

    {_req, updated} = ImagesAPI.decode_response({req, resp})

    assert %Response{} = updated.body
    assert Response.image_data(updated.body) == "edit-bytes"
  end
end

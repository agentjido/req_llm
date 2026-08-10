defmodule ReqLLM.Providers.OpenAIImagesTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias ReqLLM.Context
  alias ReqLLM.Images.OpenAICompatible
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

  test "OpenAI adapter keeps the multipart edit helper" do
    opts = [model: "gpt-image-1", prompt: "Edit this", source_image: "image-bytes"]

    assert ImagesAPI.edit_image_form_multipart(opts) ==
             OpenAICompatible.edit_image_form_multipart(opts)
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

  describe "validate_options/1" do
    test "rejects malformed aspect ratios" do
      for ratio <- ["16-9", "16:", "0:1", "-1:2", "", "sixteen:nine", 169] do
        assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
                 OpenAICompatible.validate_options(aspect_ratio: ratio)
      end
    end

    test "rejects a malformed aspect_ratio even when an explicit size is present" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               OpenAICompatible.validate_options(
                 aspect_ratio: "sixteen by nine",
                 size: "1024x1024"
               )

      assert message =~ "aspect_ratio"
    end

    test "accepts a well-formed aspect_ratio, leaving resolution to translate_options/2" do
      assert :ok = OpenAICompatible.validate_options(aspect_ratio: "16:9")
      assert :ok = OpenAICompatible.validate_options(aspect_ratio: "16:9", size: "1024x1024")
    end

    test "rejects a mask without a source_image" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               OpenAICompatible.validate_options(mask: <<1, 2, 3>>)

      assert message =~ "source_image"
    end

    test "accepts a mask alongside a source_image" do
      assert :ok = OpenAICompatible.validate_options(mask: <<1, 2, 3>>, source_image: <<4, 5, 6>>)
    end

    test "accepts options with nothing to reject" do
      assert :ok = OpenAICompatible.validate_options([])
      assert :ok = OpenAICompatible.validate_options(size: "1024x1024", quality: :hd)
    end
  end

  describe "translate_options/2" do
    test "drops seed and negative_prompt with a warning" do
      {opts, warnings} =
        OpenAICompatible.translate_options([seed: 42, negative_prompt: "blurry"], "gpt-image-1")

      refute Keyword.has_key?(opts, :seed)
      refute Keyword.has_key?(opts, :negative_prompt)
      assert Enum.any?(warnings, &(&1 =~ ":seed"))
      assert Enum.any?(warnings, &(&1 =~ ":negative_prompt"))
    end

    test "leaves explicitly nil unsupported options alone" do
      assert {[seed: nil, negative_prompt: nil], []} =
               OpenAICompatible.translate_options(
                 [seed: nil, negative_prompt: nil],
                 "gpt-image-1"
               )
    end

    test "translates the DALL-E quality names for gpt-image models" do
      for {input, expected} <- [
            {:standard, "medium"},
            {"standard", "medium"},
            {:hd, "high"},
            {"hd", "high"}
          ] do
        {opts, warnings} = OpenAICompatible.translate_options([quality: input], "gpt-image-1")

        assert Keyword.get(opts, :quality) == expected
        assert [warning] = warnings
        assert warning =~ ":quality"
      end
    end

    test "leaves native gpt-image and DALL-E quality names untouched" do
      assert {[quality: "high"], []} =
               OpenAICompatible.translate_options([quality: "high"], "gpt-image-1")

      assert {[quality: :hd], []} = OpenAICompatible.translate_options([quality: :hd], "dall-e-3")
    end

    test "drops :style outside DALL-E 3" do
      {opts, [warning]} = OpenAICompatible.translate_options([style: "vivid"], "gpt-image-1")

      refute Keyword.has_key?(opts, :style)
      assert warning =~ ":style"

      assert {[style: :vivid], []} =
               OpenAICompatible.translate_options([style: :vivid], "dall-e-3")
    end

    test "resolves aspect_ratio to the gpt-image sizes" do
      for {ratio, expected} <- [
            {"1:1", "1024x1024"},
            {"4:3", "1536x1024"},
            {"16:9", "1536x1024"},
            {"3:4", "1024x1536"},
            {"9:16", "1024x1536"}
          ] do
        {opts, []} = OpenAICompatible.translate_options([aspect_ratio: ratio], "gpt-image-1")

        assert Keyword.get(opts, :size) == expected
        refute Keyword.has_key?(opts, :aspect_ratio)
      end
    end

    test "resolves aspect_ratio to the wider DALL-E 3 sizes" do
      {opts, []} = OpenAICompatible.translate_options([aspect_ratio: "16:9"], "dall-e-3")
      assert Keyword.get(opts, :size) == "1792x1024"

      {opts, []} = OpenAICompatible.translate_options([aspect_ratio: "9:16"], "dall-e-3")
      assert Keyword.get(opts, :size) == "1024x1792"
    end

    test "resolves to the nearest offered ratio, not just the orientation" do
      {opts, [warning]} = OpenAICompatible.translate_options([aspect_ratio: "5:4"], "dall-e-3")

      assert Keyword.get(opts, :size) == "1024x1024"
      assert warning =~ "nearest size"
      refute warning =~ "offer no landscape"
    end

    test "unknown model ids fall back to the gpt-image sizes" do
      {opts, []} = OpenAICompatible.translate_options([aspect_ratio: "16:9"], "gpt-image-9-ultra")
      assert Keyword.get(opts, :size) == "1536x1024"

      {opts, []} = OpenAICompatible.translate_options([aspect_ratio: "16:9"], "something-new")
      assert Keyword.get(opts, :size) == "1536x1024"
    end

    test "an explicit size wins and aspect_ratio is still stripped" do
      {opts, []} =
        OpenAICompatible.translate_options(
          [size: {1024, 1536}, aspect_ratio: "16:9"],
          "gpt-image-1"
        )

      assert Keyword.get(opts, :size) == {1024, 1536}
      refute Keyword.has_key?(opts, :aspect_ratio)
    end

    test "leaves options without an aspect_ratio untouched" do
      assert {[size: "1024x1024"], []} =
               OpenAICompatible.translate_options([size: "1024x1024"], "gpt-image-1")
    end

    test "warns when the model family cannot match the requested orientation" do
      {opts, [warning]} = OpenAICompatible.translate_options([aspect_ratio: "16:9"], "dall-e-2")

      assert Keyword.get(opts, :size) == "1024x1024"
      assert warning =~ "no landscape size"
    end

    test "leaves a malformed aspect_ratio alone, since validate_options/1 rejects it first" do
      assert {[aspect_ratio: "wide"], []} =
               OpenAICompatible.translate_options([aspect_ratio: "wide"], "gpt-image-1")
    end
  end

  describe "request_option_keys/0" do
    test "covers every wire option plus the derived prompt" do
      keys = OpenAICompatible.request_option_keys()

      assert MapSet.new(keys) ==
               MapSet.new([
                 :prompt,
                 :n,
                 :size,
                 :aspect_ratio,
                 :output_format,
                 :response_format,
                 :quality,
                 :style,
                 :seed,
                 :negative_prompt,
                 :source_image,
                 :source_image_media_type,
                 :mask,
                 :mask_media_type,
                 :user
               ])
    end

    test "excludes plumbing options that request builders register themselves" do
      keys = OpenAICompatible.request_option_keys()

      for key <- [
            :provider_options,
            :req_http_options,
            :telemetry,
            :receive_timeout,
            :total_timeout,
            :max_retries,
            :on_unsupported,
            :fixture
          ] do
        refute key in keys, "#{inspect(key)} is plumbing and must not be a request option"
      end
    end
  end

  test "prepare_request/4 resolves aspect_ratio into size for image edits too" do
    model = %LLMDB.Model{id: "gpt-image-1.5", provider: :openai}

    assert {:ok, request} =
             OpenAI.prepare_request(:image, model, "Make the sky stormy",
               api_key: "test-key",
               source_image: <<1, 2, 3>>,
               aspect_ratio: "9:16"
             )

    assert request.options[:form_multipart][:size] == "1024x1536"
    refute Keyword.has_key?(request.options[:form_multipart], :aspect_ratio)
  end

  test "prepare_request/4 drops seed with a warning instead of sending it" do
    model = %LLMDB.Model{id: "gpt-image-1.5", provider: :openai}

    assert {:ok, request} =
             OpenAI.prepare_request(:image, model, "A lighthouse",
               api_key: "test-key",
               seed: 7
             )

    assert request.options[:seed] == nil
  end

  test "prepare_request/4 with on_unsupported: :error makes dropped options a hard error" do
    model = %LLMDB.Model{id: "gpt-image-1.5", provider: :openai}

    assert {:error, %ReqLLM.Error.Validation.Error{reason: reason}} =
             OpenAI.prepare_request(:image, model, "A lighthouse",
               api_key: "test-key",
               seed: 7,
               on_unsupported: :error
             )

    assert reason =~ ":seed"
  end

  test "prepare_request/4 rejects a mask without a source_image" do
    model = %LLMDB.Model{id: "gpt-image-1.5", provider: :openai}

    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
             OpenAI.prepare_request(:image, model, "Remove the sky",
               api_key: "test-key",
               mask: <<1, 2, 3>>
             )

    assert message =~ "source_image"
  end

  test "decode_response/1 carries the body's token usage alongside image usage" do
    req =
      Req.new(url: ImagesAPI.path())
      |> Req.Request.register_options([:model, :output_format, :size, :quality, :context])
      |> Req.Request.merge_options(
        model: "gpt-image-1",
        output_format: :png,
        size: "1024x1024",
        quality: "low",
        context: %Context{messages: []}
      )

    resp = %Req.Response{
      status: 200,
      headers: [],
      body: %{
        "created" => 1_234,
        "data" => [%{"b64_json" => Base.encode64("abc")}],
        "usage" => %{
          "input_tokens" => 14,
          "output_tokens" => 229,
          "total_tokens" => 243,
          "input_tokens_details" => %{"image_tokens" => 0, "text_tokens" => 14}
        }
      }
    }

    {_req, updated} = ImagesAPI.decode_response({req, resp})

    usage = updated.body.usage
    assert usage.input_tokens == 14
    assert usage.output_tokens == 229
    assert usage.total_tokens == 243
    assert %{generated: %{count: 1, size_class: "1024x1024:low"}} = usage.image_usage
  end

  test "decode_response/1 bills the size class the response reports, not the one requested" do
    req =
      Req.new(url: ImagesAPI.path())
      |> Req.Request.register_options([:model, :output_format, :size, :quality, :context])
      |> Req.Request.merge_options(
        model: "gpt-image-1.5",
        output_format: :png,
        size: "auto",
        quality: "auto",
        context: %Context{messages: []}
      )

    resp = %Req.Response{
      status: 200,
      headers: [],
      body: %{
        "created" => 1_234,
        "data" => [%{"b64_json" => Base.encode64("abc")}],
        "size" => "1536x1024",
        "quality" => "high",
        "usage" => %{"input_tokens" => 14, "output_tokens" => 229, "total_tokens" => 243}
      }
    }

    {_req, updated} = ImagesAPI.decode_response({req, resp})

    assert %{generated: %{count: 1, size_class: "1536x1024:high"}} =
             updated.body.usage.image_usage
  end

  test "decode_response/1 falls back to requested size class when the body omits it" do
    req =
      Req.new(url: ImagesAPI.path())
      |> Req.Request.register_options([:model, :output_format, :size, :quality, :context])
      |> Req.Request.merge_options(
        model: "gpt-image-1.5",
        output_format: :png,
        size: "1024x1536",
        quality: "high",
        context: %Context{messages: []}
      )

    resp = %Req.Response{
      status: 200,
      headers: [],
      body: %{
        "created" => 1_234,
        "data" => [%{"b64_json" => Base.encode64("abc")}],
        "size" => "auto"
      }
    }

    {_req, updated} = ImagesAPI.decode_response({req, resp})

    assert %{generated: %{count: 1, size_class: "1024x1536:high"}} =
             updated.body.usage.image_usage
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

  test "prepare_request/4 rejects a nil source_image instead of building an edit request" do
    model = %LLMDB.Model{id: "gpt-image-1.5", provider: :openai}

    assert {:error, error} =
             OpenAI.prepare_request(:image, model, "A lighthouse in a storm",
               api_key: "test-key",
               source_image: nil
             )

    assert Exception.message(error) =~ "source_image"
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

  test "decode_response/1 treats any 2xx status as success" do
    req =
      Req.new(url: ImagesAPI.path())
      |> Req.Request.register_options([:model, :output_format, :context])
      |> Req.Request.merge_options(
        model: "gpt-image-1",
        output_format: :png,
        context: %Context{messages: []}
      )

    resp = %Req.Response{
      status: 202,
      headers: [],
      body: %{"data" => [%{"b64_json" => Base.encode64("abc")}]}
    }

    {_req, updated} = ImagesAPI.decode_response({req, resp})

    assert %Response{} = updated.body
    assert Response.image_data(updated.body) == "abc"
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

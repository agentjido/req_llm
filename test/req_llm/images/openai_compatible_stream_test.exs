defmodule ReqLLM.Images.OpenAICompatibleStreamTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Images.OpenAICompatible
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.StreamChunk

  @png_bytes <<137, 80, 78, 71, 13, 10, 26, 10>>
  @b64 Base.encode64(@png_bytes)
  @model %LLMDB.Model{id: "gpt-image-1.5", provider: :openai}

  defp partial_event(index, extra \\ %{}) do
    %{
      data:
        Map.merge(
          %{
            "type" => "image_generation.partial_image",
            "b64_json" => @b64,
            "partial_image_index" => index,
            "created_at" => 1_700_000_000,
            "size" => "1024x1024",
            "quality" => "medium",
            "background" => "transparent",
            "output_format" => "png"
          },
          extra
        )
    }
  end

  defp completed_event(extra \\ %{}) do
    %{
      data:
        Map.merge(
          %{
            "type" => "image_generation.completed",
            "b64_json" => @b64,
            "created_at" => 1_700_000_000,
            "size" => "1024x1024",
            "quality" => "medium",
            "background" => "transparent",
            "output_format" => "png",
            "usage" => %{
              "total_tokens" => 120,
              "input_tokens" => 20,
              "output_tokens" => 100,
              "input_tokens_details" => %{"text_tokens" => 20, "image_tokens" => 0}
            }
          },
          extra
        )
    }
  end

  describe "decode_stream_event/2 partial frames" do
    test "decodes a partial image into a stream-only content part" do
      assert [%StreamChunk{type: :content_part} = chunk] =
               OpenAICompatible.decode_stream_event(partial_event(0), @model)

      assert chunk.metadata == %{partial?: true, partial_image_index: 0, stream_only?: true}

      assert %ContentPart{type: :image, data: @png_bytes, media_type: "image/png"} =
               chunk.content_part

      assert chunk.content_part.metadata == %{
               partial?: true,
               partial_image_index: 0,
               size: "1024x1024",
               quality: "medium",
               background: "transparent",
               output_format: "png"
             }
    end

    test "uses the echoed output format for the media type" do
      [chunk] =
        OpenAICompatible.decode_stream_event(
          partial_event(1, %{"output_format" => "jpeg"}),
          @model
        )

      assert chunk.content_part.media_type == "image/jpeg"
      assert chunk.metadata.partial_image_index == 1
    end

    test "ignores non-binary echoed fields" do
      [chunk] =
        OpenAICompatible.decode_stream_event(partial_event(0, %{"quality" => nil}), @model)

      refute Map.has_key?(chunk.content_part.metadata, :quality)
    end
  end

  describe "decode_stream_event/2 completion" do
    test "emits the final image followed by a terminal meta with usage" do
      assert [%StreamChunk{type: :content_part} = image, %StreamChunk{type: :meta} = meta] =
               OpenAICompatible.decode_stream_event(completed_event(), @model)

      assert image.metadata == %{partial?: false}
      assert image.content_part.metadata.partial? == false
      assert image.content_part.data == @png_bytes

      assert meta.metadata.terminal? == true
      assert meta.metadata.finish_reason == :stop

      assert meta.metadata.usage.image_usage == %{
               generated: %{count: 1, size_class: "1024x1024:medium"}
             }

      assert meta.metadata.usage.input_tokens == 20
      assert meta.metadata.usage.output_tokens == 100
      assert meta.metadata.usage.total_tokens == 120
    end

    test "keys provider_meta by the serving provider and drops the image bytes" do
      [_image, meta] =
        OpenAICompatible.decode_stream_event(
          completed_event(),
          %LLMDB.Model{id: "gpt-image-2", provider: :azure}
        )

      assert %{"azure" => provider_meta} = meta.metadata.provider_meta
      refute Map.has_key?(provider_meta, "b64_json")
      assert provider_meta["type"] == "image_generation.completed"
      assert provider_meta["size"] == "1024x1024"
    end

    test "falls back to the request-agnostic defaults when size and quality are auto" do
      [_image, meta] =
        OpenAICompatible.decode_stream_event(
          completed_event(%{"size" => "auto", "quality" => "auto", "usage" => nil}),
          @model
        )

      assert meta.metadata.usage == %{
               image_usage: %{generated: %{count: 1, size_class: "1024x1024:medium"}}
             }
    end
  end

  describe "decode_stream_event/2 errors and unknown events" do
    test "typed error events become a terminal error meta" do
      assert [%StreamChunk{type: :meta, metadata: metadata}] =
               OpenAICompatible.decode_stream_event(
                 %{data: %{"type" => "error", "message" => "moderation blocked"}},
                 @model
               )

      assert metadata == %{terminal?: true, finish_reason: :error, error: "moderation blocked"}
    end

    test "typed error events with a nested error map use its message" do
      [chunk] =
        OpenAICompatible.decode_stream_event(
          %{data: %{"type" => "error", "error" => %{"message" => "quota exceeded"}}},
          @model
        )

      assert chunk.metadata.error == "quota exceeded"
    end

    test "typed error events without a message fall back to the code" do
      [chunk] =
        OpenAICompatible.decode_stream_event(
          %{data: %{"type" => "error", "code" => "server_error"}},
          @model
        )

      assert chunk.metadata.error == "server_error"
    end

    test "untyped error envelopes become a terminal error meta" do
      [chunk] =
        OpenAICompatible.decode_stream_event(
          %{data: %{"error" => %{"message" => "bad request"}}},
          @model
        )

      assert chunk.metadata == %{terminal?: true, finish_reason: :error, error: "bad request"}
    end

    test "unknown events decode to nothing" do
      assert OpenAICompatible.decode_stream_event(%{data: %{"type" => "ping"}}, @model) == []
      assert OpenAICompatible.decode_stream_event(%{data: "[DONE]"}, @model) == []

      assert OpenAICompatible.decode_stream_event(
               %{data: %{"type" => "image_generation.completed"}},
               @model
             ) == []
    end
  end

  describe "image_model?/1" do
    test "matches the gpt-image family by catalog metadata" do
      assert OpenAICompatible.image_model?(%LLMDB.Model{
               id: "custom-deploy",
               provider: :azure,
               extra: %{family: "gpt-image"}
             })
    end

    test "matches image model ids by prefix" do
      assert OpenAICompatible.image_model?("gpt-image-1.5")
      assert OpenAICompatible.image_model?("dall-e-3")
      assert OpenAICompatible.image_model?("chatgpt-image-latest")
      assert OpenAICompatible.image_model?(%LLMDB.Model{id: "gpt-image-2", provider: :openai})

      assert OpenAICompatible.image_model?(%LLMDB.Model{
               id: "alias",
               provider: :openai,
               provider_model_id: "gpt-image-1"
             })
    end

    test "rejects chat models and nil" do
      refute OpenAICompatible.image_model?("gpt-4o")
      refute OpenAICompatible.image_model?("gpt-5.4")
      refute OpenAICompatible.image_model?(%LLMDB.Model{id: "gpt-4o", provider: :openai})
      refute OpenAICompatible.image_model?(nil)
    end
  end

  describe "build_generation_body/1 streaming fields" do
    test "omits stream fields when not streaming" do
      body =
        OpenAICompatible.build_generation_body(
          model: "gpt-image-1.5",
          prompt: "A red square",
          partial_images: 2
        )

      refute Map.has_key?(body, "stream")
      refute Map.has_key?(body, "partial_images")

      body =
        OpenAICompatible.build_generation_body(
          model: "gpt-image-1.5",
          prompt: "A red square",
          stream: false,
          partial_images: 2
        )

      refute Map.has_key?(body, "stream")
      refute Map.has_key?(body, "partial_images")
    end

    test "emits stream and partial_images when streaming" do
      body =
        OpenAICompatible.build_generation_body(
          model: "gpt-image-1.5",
          prompt: "A red square",
          stream: true,
          partial_images: 2
        )

      assert body["stream"] == true
      assert body["partial_images"] == 2
    end

    test "emits stream without partial_images when unset" do
      body =
        OpenAICompatible.build_generation_body(
          model: "gpt-image-1.5",
          prompt: "A red square",
          stream: true
        )

      assert body["stream"] == true
      refute Map.has_key?(body, "partial_images")
    end
  end

  describe "validate_stream_options/1" do
    test "accepts generation options" do
      assert :ok = OpenAICompatible.validate_stream_options(partial_images: 2, n: 1)
      assert :ok = OpenAICompatible.validate_stream_options([])
    end

    test "rejects edits" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               OpenAICompatible.validate_stream_options(source_image: @png_bytes)

      assert message =~ "streaming image edits are not supported"
    end

    test "rejects n greater than one" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               OpenAICompatible.validate_stream_options(n: 2)

      assert message =~ "n: streaming generates a single image"
    end
  end

  describe "prompt_from_context/1" do
    test "extracts the last user text" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("A red square")])
      assert {:ok, "A red square"} = OpenAICompatible.prompt_from_context(context)
    end

    test "rejects a context without user text" do
      context = ReqLLM.Context.new([ReqLLM.Context.system("Be helpful")])

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               OpenAICompatible.prompt_from_context(context)
    end
  end
end

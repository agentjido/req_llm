defmodule ReqLLM.Providers.GoogleImagesTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Providers.Google
  alias ReqLLM.Response

  test "encode_body/1 builds generateContent image request JSON" do
    # Context with a user message containing the prompt
    context = %Context{
      messages: [
        %ReqLLM.Message{role: :user, content: "A cat in space"}
      ]
    }

    request =
      Req.new(url: "/models/gemini-2.0-flash-exp-image-generation:generateContent")
      |> Req.Request.register_options([
        :operation,
        :model,
        :n,
        :aspect_ratio,
        :output_format,
        :context,
        :image_n_provided
      ])
      |> Req.Request.merge_options(
        operation: :image,
        model: "gemini-2.0-flash-exp-image-generation",
        n: 2,
        aspect_ratio: "1:1",
        output_format: :png,
        context: context,
        image_n_provided: true
      )

    encoded = Google.encode_body(request)
    body = Jason.decode!(encoded.body)

    assert get_in(body, ["generationConfig", "responseModalities"]) == nil
    assert get_in(body, ["generationConfig", "imageConfig", "aspectRatio"]) == "1:1"
    assert get_in(body, ["generationConfig", "candidateCount"]) == 2

    assert get_in(body, ["contents", Access.at(0), "parts", Access.at(0), "text"]) ==
             "A cat in space"

    # Role is kept intentionally - experiments show it improves multi-image generation success
    assert get_in(body, ["contents", Access.at(0), "role"]) == "user"
  end

  test "prepare_request/4 uses predict endpoint for Imagen models" do
    {:ok, model} = ReqLLM.model("google:imagen-4.0-generate-001")

    {:ok, request} =
      Google.prepare_request(
        :image,
        model,
        "A cat in space",
        n: 2,
        size: "1024x1024",
        output_format: :jpeg
      )

    assert request.url.path == "/models/imagen-4.0-generate-001:predict"

    encoded = Google.encode_body(request)
    body = Jason.decode!(encoded.body)

    assert body["instances"] == [%{"prompt" => "A cat in space"}]
    assert get_in(body, ["parameters", "sampleCount"]) == 2
    assert get_in(body, ["parameters", "aspectRatio"]) == "1:1"
    assert get_in(body, ["parameters", "sampleImageSize"]) == "1K"
    assert get_in(body, ["parameters", "outputOptions", "mimeType"]) == "image/jpeg"
  end

  test "prepare_request/3 rejects n for gemini image models" do
    {:ok, model} = ReqLLM.model("google:gemini-2.5-flash-image")

    assert {:error, _} =
             Google.prepare_request(
               :image,
               model,
               "A prompt",
               n: 2
             )
  end

  test "encode_body/1 omits generationConfig when no image options are set" do
    context = %Context{
      messages: [
        %ReqLLM.Message{role: :user, content: "A cat in space"}
      ]
    }

    request =
      Req.new(url: "/models/gemini-2.0-flash-exp-image-generation:generateContent")
      |> Req.Request.register_options([
        :operation,
        :model,
        :context
      ])
      |> Req.Request.merge_options(
        operation: :image,
        model: "gemini-2.0-flash-exp-image-generation",
        context: context
      )

    encoded = Google.encode_body(request)
    body = Jason.decode!(encoded.body)

    assert is_nil(body["generationConfig"])
  end

  test "prepare_request/4 normalizes image response modalities to Gemini enums" do
    {:ok, model} = ReqLLM.model("google:gemini-2.5-flash-image")

    {:ok, request} =
      Google.prepare_request(
        :image,
        model,
        "Generate an image",
        response_modalities: ["Image"]
      )

    encoded = Google.encode_body(request)
    body = Jason.decode!(encoded.body)

    assert request.options[:response_modalities] == ["IMAGE"]
    assert get_in(body, ["generationConfig", "responseModalities"]) == ["IMAGE"]
  end

  test "prepare_request/4 normalizes multiple image response modalities" do
    {:ok, model} = ReqLLM.model("google:gemini-2.5-flash-image")

    {:ok, request} =
      Google.prepare_request(
        :image,
        model,
        "Describe and draw something",
        response_modalities: ["Text", "Image"]
      )

    encoded = Google.encode_body(request)
    body = Jason.decode!(encoded.body)

    assert request.options[:response_modalities] == ["TEXT", "IMAGE"]
    assert get_in(body, ["generationConfig", "responseModalities"]) == ["TEXT", "IMAGE"]
  end

  test "decode_response/1 converts inlineData to ContentPart.image" do
    req =
      Req.new(url: "/models/gemini-2.0-flash-exp-image-generation:generateContent")
      |> Req.Request.register_options([:operation, :model, :context])
      |> Req.Request.merge_options(
        operation: :image,
        model: "gemini-2.0-flash-exp-image-generation",
        context: %Context{messages: []}
      )

    resp = %Req.Response{
      status: 200,
      headers: [],
      body: %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "inlineData" => %{
                    "mimeType" => "image/png",
                    "data" => Base.encode64("xyz")
                  }
                }
              ]
            }
          },
          %{
            "content" => %{
              "parts" => [
                %{
                  "inlineData" => %{
                    "mimeType" => "image/png",
                    "data" => Base.encode64("abc")
                  }
                }
              ]
            }
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 1,
          "candidatesTokenCount" => 1,
          "totalTokenCount" => 2
        }
      }
    }

    {_req, updated} = Google.decode_response({req, resp})

    assert %Response{} = updated.body
    assert Response.image_data(updated.body) == "xyz"
    assert Enum.map(Response.images(updated.body), & &1.data) == ["xyz", "abc"]
    assert Response.usage(updated.body)[:total_tokens] == 2
  end

  test "decode_response/1 converts Imagen predictions to ContentPart.image" do
    req =
      Req.new(url: "/models/imagen-4.0-generate-001:predict")
      |> Req.Request.register_options([:operation, :model, :context])
      |> Req.Request.merge_options(
        operation: :image,
        model: "imagen-4.0-generate-001",
        context: %Context{messages: []}
      )

    resp = %Req.Response{
      status: 200,
      headers: [],
      body: %{
        "predictions" => [
          %{
            "mimeType" => "image/png",
            "bytesBase64Encoded" => Base.encode64("xyz")
          },
          %{
            "mimeType" => "image/jpeg",
            "bytesBase64Encoded" => Base.encode64("abc")
          }
        ],
        "positivePromptSafetyAttributes" => %{
          "categories" => ["Violence"],
          "scores" => [0.1]
        }
      }
    }

    {_req, updated} = Google.decode_response({req, resp})

    assert %Response{} = updated.body
    assert Response.image_data(updated.body) == "xyz"
    assert Enum.map(Response.images(updated.body), & &1.data) == ["xyz", "abc"]

    assert get_in(updated.body.provider_meta, ["google", "positivePromptSafetyAttributes"]) == %{
             "categories" => ["Violence"],
             "scores" => [0.1]
           }
  end
end

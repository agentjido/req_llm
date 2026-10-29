defmodule ReqLLM.Providers.Google.AttachmentsTest do
  @moduledoc """
  Google file, image, and video content encoding and URI handling.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Google, async: true

  alias ReqLLM.Providers.Google

  describe "file attachment support" do
    test "encode_body handles :file ContentPart with inline_data format" do
      file_content = "test file content"

      file_part = %ReqLLM.Message.ContentPart{
        type: :file,
        data: file_content,
        media_type: "application/pdf"
      }

      message_with_file = %ReqLLM.Message{
        role: :user,
        content: [file_part]
      }

      context = %ReqLLM.Context{messages: [message_with_file]}

      mock_request = %Req.Request{
        options: [
          context: context,
          id: "gemini-1.5-flash",
          stream: false
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [user_msg] = decoded["contents"]
      parts = user_msg["parts"]

      assert length(parts) == 1, "Expected 1 part, got: #{inspect(parts)}"
      [part] = parts

      assert Map.has_key?(part, "inline_data")
      assert part["inline_data"]["mime_type"] == "application/pdf"
      assert Base.decode64!(part["inline_data"]["data"]) == file_content
    end

    test "encode_body consumes explicitly owned Google file references" do
      file_part =
        ReqLLM.Message.ContentPart.owned_file_id(
          "https://generativelanguage.googleapis.com/v1beta/files/report",
          :google,
          media_type: "application/pdf",
          purpose: :analysis,
          status: :active
        )

      context = %ReqLLM.Context{
        messages: [%ReqLLM.Message{role: :user, content: [file_part]}]
      }

      request = %Req.Request{
        options: [context: context, id: "gemini-1.5-flash", stream: false]
      }

      decoded = request |> Google.encode_body() |> ReqLLM.Test.Helpers.json_body()

      assert [%{"parts" => [part]}] = decoded["contents"]

      assert part == %{
               "fileData" => %{
                 "fileUri" => "https://generativelanguage.googleapis.com/v1beta/files/report",
                 "mimeType" => "application/pdf"
               }
             }

      refute Jason.encode!(decoded) =~ "req_llm"
    end

    test "encode_body handles video ContentPart with inline_data format" do
      video_content = "fake video bytes"

      video_part = %ReqLLM.Message.ContentPart{
        type: :file,
        data: video_content,
        media_type: "video/mp4"
      }

      message_with_video = %ReqLLM.Message{
        role: :user,
        content: [video_part]
      }

      context = %ReqLLM.Context{messages: [message_with_video]}

      mock_request = %Req.Request{
        options: [
          context: context,
          id: "gemini-1.5-flash",
          stream: false
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [user_msg] = decoded["contents"]
      [part] = user_msg["parts"]

      assert Map.has_key?(part, "inline_data")
      assert part["inline_data"]["mime_type"] == "video/mp4"
      assert Base.decode64!(part["inline_data"]["data"]) == video_content
    end

    test "encode_body handles image ContentPart with inline_data format" do
      image_content = <<137, 80, 78, 71, 13, 10, 26, 10>>

      image_part = %ReqLLM.Message.ContentPart{
        type: :image,
        data: image_content,
        media_type: "image/png"
      }

      message_with_image = %ReqLLM.Message{
        role: :user,
        content: [image_part]
      }

      context = %ReqLLM.Context{messages: [message_with_image]}

      mock_request = %Req.Request{
        options: [
          context: context,
          id: "gemini-1.5-flash",
          stream: false
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [user_msg] = decoded["contents"]
      [part] = user_msg["parts"]

      assert Map.has_key?(part, "inline_data")
      assert part["inline_data"]["mime_type"] == "image/png"
      assert Base.decode64!(part["inline_data"]["data"]) == image_content
    end
  end

  describe "image_url file URI support" do
    test "encode_body converts HTTPS image_url to fileData format" do
      url = "https://example.com/images/photo.jpg"

      image_url_part = ReqLLM.Message.ContentPart.image_url(url)

      message = %ReqLLM.Message{
        role: :user,
        content: [image_url_part]
      }

      context = %ReqLLM.Context{messages: [message]}

      mock_request = %Req.Request{
        options: [
          context: context,
          id: "gemini-1.5-flash",
          stream: false
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [user_msg] = decoded["contents"]
      [part] = user_msg["parts"]

      assert Map.has_key?(part, "fileData")
      assert part["fileData"]["fileUri"] == url
      assert part["fileData"]["mimeType"] == "image/jpeg"
    end

    test "encode_body converts HTTP image_url to fileData format" do
      url = "http://example.com/images/photo.png"

      image_url_part = ReqLLM.Message.ContentPart.image_url(url)

      message = %ReqLLM.Message{
        role: :user,
        content: [image_url_part]
      }

      context = %ReqLLM.Context{messages: [message]}

      mock_request = %Req.Request{
        options: [
          context: context,
          id: "gemini-1.5-flash",
          stream: false
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [user_msg] = decoded["contents"]
      [part] = user_msg["parts"]

      assert Map.has_key?(part, "fileData")
      assert part["fileData"]["fileUri"] == url
      assert part["fileData"]["mimeType"] == "image/png"
    end

    test "encode_body converts OpenAI-format video_url to fileData format" do
      url = "https://example.com/videos/clip.mp4"

      mock_request = %Req.Request{
        options: [
          messages: [
            %{
              "role" => "user",
              "content" => [
                %{"type" => "text", "text" => "What happens in this video?"},
                %{"type" => "video_url", "video_url" => %{"url" => url}}
              ]
            }
          ],
          id: "gemini-1.5-flash",
          stream: false
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [user_msg] = decoded["contents"]
      [_text_part, part] = user_msg["parts"]

      assert Map.has_key?(part, "fileData")
      assert part["fileData"]["fileUri"] == url
      assert part["fileData"]["mimeType"] == "video/mp4"
    end

    test "encode_body converts GCS URI to fileData format" do
      url = "gs://my-bucket/path/to/document.pdf"

      image_url_part = ReqLLM.Message.ContentPart.image_url(url)

      message = %ReqLLM.Message{
        role: :user,
        content: [image_url_part]
      }

      context = %ReqLLM.Context{messages: [message]}

      mock_request = %Req.Request{
        options: [
          context: context,
          id: "gemini-1.5-flash",
          stream: false
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [user_msg] = decoded["contents"]
      [part] = user_msg["parts"]

      assert Map.has_key?(part, "fileData")
      assert part["fileData"]["fileUri"] == url
      assert part["fileData"]["mimeType"] == "application/pdf"
    end

    test "encode_body infers mime type from URL extension" do
      test_cases = [
        {"https://example.com/file.jpg", "image/jpeg"},
        {"https://example.com/file.jpeg", "image/jpeg"},
        {"https://example.com/file.png", "image/png"},
        {"https://example.com/file.gif", "image/gif"},
        {"https://example.com/file.webp", "image/webp"},
        {"https://example.com/file.pdf", "application/pdf"},
        {"https://example.com/file.mp3", "audio/mpeg"},
        {"https://example.com/file.mp4", "video/mp4"},
        {"https://example.com/file.m4a", "audio/mp4"},
        {"https://example.com/file.wav", "audio/wav"}
      ]

      for {url, expected_mime} <- test_cases do
        image_url_part = ReqLLM.Message.ContentPart.image_url(url)

        message = %ReqLLM.Message{
          role: :user,
          content: [image_url_part]
        }

        context = %ReqLLM.Context{messages: [message]}

        mock_request = %Req.Request{
          options: [
            context: context,
            id: "gemini-1.5-flash",
            stream: false
          ]
        }

        updated_request = Google.encode_body(mock_request)
        decoded = ReqLLM.Test.Helpers.json_body(updated_request)

        [user_msg] = decoded["contents"]
        [part] = user_msg["parts"]

        assert part["fileData"]["mimeType"] == expected_mime,
               "Expected #{expected_mime} for #{url}, got #{part["fileData"]["mimeType"]}"
      end
    end

    test "encode_body omits mimeType for URLs with unrecognizable extensions" do
      url = "https://example.com/file.unknown"
      image_url_part = ReqLLM.Message.ContentPart.image_url(url)

      message = %ReqLLM.Message{role: :user, content: [image_url_part]}
      context = %ReqLLM.Context{messages: [message]}

      mock_request = %Req.Request{
        options: [context: context, id: "gemini-1.5-flash", stream: false]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [user_msg] = decoded["contents"]
      [part] = user_msg["parts"]

      assert part["fileData"]["fileUri"] == url

      refute Map.has_key?(part["fileData"], "mimeType"),
             "mimeType should be omitted for unrecognizable extensions"
    end

    test "encode_body omits mimeType for YouTube URLs" do
      url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
      image_url_part = ReqLLM.Message.ContentPart.image_url(url)

      message = %ReqLLM.Message{role: :user, content: [image_url_part]}
      context = %ReqLLM.Context{messages: [message]}

      mock_request = %Req.Request{
        options: [context: context, id: "gemini-1.5-flash", stream: false]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [user_msg] = decoded["contents"]
      [part] = user_msg["parts"]

      assert part["fileData"]["fileUri"] == url

      refute Map.has_key?(part["fileData"], "mimeType"),
             "mimeType should be omitted for YouTube URLs so Gemini can infer it"
    end

    test "encode_body strips query params when inferring mime type from URL" do
      url = "https://example.com/image.jpg?token=abc123&size=large"

      image_url_part = ReqLLM.Message.ContentPart.image_url(url)

      message = %ReqLLM.Message{
        role: :user,
        content: [image_url_part]
      }

      context = %ReqLLM.Context{messages: [message]}

      mock_request = %Req.Request{
        options: [
          context: context,
          id: "gemini-1.5-flash",
          stream: false
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [user_msg] = decoded["contents"]
      [part] = user_msg["parts"]

      assert part["fileData"]["mimeType"] == "image/jpeg"
      # URL should be preserved with query params
      assert part["fileData"]["fileUri"] == url
    end

    test "encode_body handles data URI format in image_url" do
      base64_data = Base.encode64("fake image data")
      url = "data:image/png;base64,#{base64_data}"

      image_url_part = ReqLLM.Message.ContentPart.image_url(url)

      message = %ReqLLM.Message{
        role: :user,
        content: [image_url_part]
      }

      context = %ReqLLM.Context{messages: [message]}

      mock_request = %Req.Request{
        options: [
          context: context,
          id: "gemini-1.5-flash",
          stream: false
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [user_msg] = decoded["contents"]
      [part] = user_msg["parts"]

      # Data URIs should use inline_data format, not fileData
      assert Map.has_key?(part, "inline_data")
      assert part["inline_data"]["mime_type"] == "image/png"
      assert part["inline_data"]["data"] == base64_data
    end

    test "encode_body returns error text for unsupported URL schemes" do
      url = "ftp://example.com/file.jpg"

      image_url_part = ReqLLM.Message.ContentPart.image_url(url)

      message = %ReqLLM.Message{
        role: :user,
        content: [image_url_part]
      }

      context = %ReqLLM.Context{messages: [message]}

      mock_request = %Req.Request{
        options: [
          context: context,
          id: "gemini-1.5-flash",
          stream: false
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [user_msg] = decoded["contents"]
      [part] = user_msg["parts"]

      # Should fall back to text with error message
      assert Map.has_key?(part, "text")
      assert part["text"] =~ "Unsupported URL scheme"
    end

    test "encode_body handles malformed data URI gracefully" do
      # Data URI without the comma separator
      url = "data:image/png;base64"

      image_url_part = ReqLLM.Message.ContentPart.image_url(url)

      message = %ReqLLM.Message{
        role: :user,
        content: [image_url_part]
      }

      context = %ReqLLM.Context{messages: [message]}

      mock_request = %Req.Request{
        options: [
          context: context,
          id: "gemini-1.5-flash",
          stream: false
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [user_msg] = decoded["contents"]
      [part] = user_msg["parts"]

      assert Map.has_key?(part, "text")
      assert part["text"] =~ "Malformed data URI"
    end
  end
end

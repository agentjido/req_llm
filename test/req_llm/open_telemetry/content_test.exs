defmodule ReqLLM.OpenTelemetry.ContentTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.OpenTelemetry.Content

  defp decode_all(entries), do: Enum.map(entries, &Jason.decode!/1)

  describe "event attributes" do
    test "returns structured values without JSON encoding" do
      messages = [
        %Message{role: :system, content: [%ContentPart{type: :text, text: "be helpful"}]},
        %Message{role: :user, content: [%ContentPart{type: :text, text: "hello"}]}
      ]

      attrs = Content.request_event_attributes(%{request_payload: %{messages: messages}})

      assert attrs["gen_ai.system_instructions"] == [
               %{"type" => "text", "content" => "be helpful"}
             ]

      assert attrs["gen_ai.input.messages"] == [
               %{
                 "role" => "user",
                 "parts" => [%{"type" => "text", "content" => "hello"}]
               }
             ]
    end
  end

  describe "input_messages/1 — content part rendering" do
    test "renders :text parts as %{type: text, content: ...}" do
      messages = [
        %Message{role: :user, content: [%ContentPart{type: :text, text: "hello"}]}
      ]

      assert [%{"role" => "user", "parts" => parts}] =
               %{request_payload: %{messages: messages}}
               |> Content.input_messages()
               |> decode_all()

      assert parts == [%{"type" => "text", "content" => "hello"}]
    end

    test "renders :image_url parts with modality image" do
      messages = [
        %Message{
          role: :user,
          content: [%ContentPart{type: :image_url, url: "https://example.com/cat.png"}]
        }
      ]

      assert [%{"parts" => parts}] =
               %{request_payload: %{messages: messages}}
               |> Content.input_messages()
               |> decode_all()

      assert parts == [
               %{"type" => "uri", "uri" => "https://example.com/cat.png", "modality" => "image"}
             ]
    end

    test "renders :video_url parts with modality video" do
      messages = [
        %Message{
          role: :user,
          content: [%ContentPart{type: :video_url, url: "https://example.com/clip.mp4"}]
        }
      ]

      assert [%{"parts" => parts}] =
               %{request_payload: %{messages: messages}}
               |> Content.input_messages()
               |> decode_all()

      assert parts == [
               %{"type" => "uri", "uri" => "https://example.com/clip.mp4", "modality" => "video"}
             ]
    end

    test "renders sanitized :image parts as metadata-only descriptors (never raw bytes)" do
      sanitized_part = %{type: :image, media_type: "image/png", bytes: 12_345}

      messages = [%Message{role: :user, content: [sanitized_part]}]

      assert [%{"parts" => parts}] =
               %{request_payload: %{messages: messages}}
               |> Content.input_messages()
               |> decode_all()

      assert parts == [
               %{
                 "type" => "image",
                 "modality" => "image",
                 "media_type" => "image/png",
                 "bytes" => 12_345
               }
             ]
    end

    test "renders sanitized :file parts with file_id, filename, media_type, bytes" do
      sanitized_part = %{
        type: :file,
        file_id: "file_abc",
        filename: "report.pdf",
        media_type: "application/pdf",
        bytes: 98_765
      }

      messages = [%Message{role: :user, content: [sanitized_part]}]

      assert [%{"parts" => parts}] =
               %{request_payload: %{messages: messages}}
               |> Content.input_messages()
               |> decode_all()

      assert parts == [
               %{
                 "type" => "file",
                 "file_id" => "file_abc",
                 "filename" => "report.pdf",
                 "media_type" => "application/pdf",
                 "bytes" => 98_765
               }
             ]
    end

    test "raw :image ContentPart with binary data does not leak the data" do
      raw_part = %ContentPart{
        type: :image,
        data: "RAW_BINARY_PAYLOAD_THAT_MUST_NOT_LEAK",
        media_type: "image/png"
      }

      messages = [%Message{role: :user, content: [raw_part]}]

      assert [%{"parts" => parts}] =
               %{request_payload: %{messages: messages}}
               |> Content.input_messages()
               |> decode_all()

      assert [part] = parts
      assert part["type"] == "image"
      assert part["modality"] == "image"
      assert part["media_type"] == "image/png"
      refute Map.has_key?(part, "data")
      refute part |> Map.values() |> Enum.any?(&(&1 == "RAW_BINARY_PAYLOAD_THAT_MUST_NOT_LEAK"))
    end

    test "raw :file ContentPart with binary data does not leak the data" do
      raw_part = %ContentPart{
        type: :file,
        data: "RAW_FILE_BYTES_NEVER_TO_BE_EMITTED",
        filename: "secret.bin",
        media_type: "application/octet-stream"
      }

      messages = [%Message{role: :user, content: [raw_part]}]

      assert [%{"parts" => parts}] =
               %{request_payload: %{messages: messages}}
               |> Content.input_messages()
               |> decode_all()

      assert [part] = parts
      assert part["type"] == "file"
      assert part["filename"] == "secret.bin"
      refute Map.has_key?(part, "data")
      refute part |> Map.values() |> Enum.any?(&(&1 == "RAW_FILE_BYTES_NEVER_TO_BE_EMITTED"))
    end

    test "drops :thinking parts even if text is present" do
      messages = [
        %Message{
          role: :assistant,
          content: [
            %ContentPart{type: :thinking, text: "secret reasoning"},
            %ContentPart{type: :text, text: "the answer"}
          ]
        }
      ]

      assert [%{"parts" => parts}] =
               %{request_payload: %{messages: messages}}
               |> Content.input_messages()
               |> decode_all()

      assert parts == [%{"type" => "text", "content" => "the answer"}]
    end

    test "drops messages that have no renderable parts" do
      messages = [
        %Message{
          role: :assistant,
          content: [%ContentPart{type: :thinking, text: "only thoughts"}]
        }
      ]

      assert Content.input_messages(%{request_payload: %{messages: messages}}) == []
    end
  end

  describe "system_instructions/1" do
    test "extracts text-only parts from system messages" do
      messages = [
        %Message{role: :system, content: [%ContentPart{type: :text, text: "you are helpful"}]},
        %Message{role: :user, content: [%ContentPart{type: :text, text: "hi"}]}
      ]

      assert %{request_payload: %{messages: messages}}
             |> Content.system_instructions()
             |> decode_all() == [
               %{"type" => "text", "content" => "you are helpful"}
             ]
    end

    test "concatenates text parts across multiple system messages" do
      messages = [
        %Message{role: :system, content: [%ContentPart{type: :text, text: "rule one"}]},
        %Message{role: :system, content: [%ContentPart{type: :text, text: "rule two"}]}
      ]

      assert %{request_payload: %{messages: messages}}
             |> Content.system_instructions()
             |> decode_all() == [
               %{"type" => "text", "content" => "rule one"},
               %{"type" => "text", "content" => "rule two"}
             ]
    end

    test "drops non-text parts (and reasoning) from system instructions" do
      messages = [
        %Message{
          role: :system,
          content: [
            %ContentPart{type: :text, text: "be helpful"},
            %ContentPart{type: :image_url, url: "https://example.com/x.png"},
            %ContentPart{type: :thinking, text: "secret"}
          ]
        }
      ]

      assert %{request_payload: %{messages: messages}}
             |> Content.system_instructions()
             |> decode_all() == [
               %{"type" => "text", "content" => "be helpful"}
             ]
    end
  end

  describe "tool_definitions/1" do
    test "preserves strict: false (regression test for MapAccess `||` boolean trap)" do
      tools = [
        %{name: "a", description: "a", strict: false, parameter_schema: %{}},
        %{name: "b", description: "b", strict: true, parameter_schema: %{}}
      ]

      assert [tool_a, tool_b] =
               %{request_payload: %{tools: tools}}
               |> Content.tool_definitions()
               |> decode_all()

      assert tool_a["strict"] == false
      assert tool_b["strict"] == true
    end

    test "skips tools without a usable name" do
      tools = [
        %{description: "no name"},
        %{name: "", description: "empty"},
        %{name: "ok", description: "fine", parameter_schema: %{}}
      ]

      assert [tool] =
               %{request_payload: %{tools: tools}}
               |> Content.tool_definitions()
               |> decode_all()

      assert tool["name"] == "ok"
    end

    test "captures builtin tools that have :type but no :name" do
      tools = [
        %{type: "web_search_preview", search_context_size: "medium"},
        %{type: :file_search}
      ]

      assert [%{"type" => "web_search_preview"}, %{"type" => "file_search"}] =
               %{request_payload: %{tools: tools}}
               |> Content.tool_definitions()
               |> decode_all()
    end
  end
end

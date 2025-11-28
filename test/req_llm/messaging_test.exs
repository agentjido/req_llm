defmodule ReqLLM.MessagingTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  describe "ContentPart" do
    test "creates content parts" do
      assert %ContentPart{type: :text, text: "Hello"} = ContentPart.text("Hello")
      assert %ContentPart{type: :thinking, text: "Think..."} = ContentPart.thinking("Think...")

      assert %ContentPart{type: :image_url, url: "http://ex.com/img.jpg"} =
               ContentPart.image_url("http://ex.com/img.jpg")

      data = <<1, 2, 3>>

      assert %ContentPart{type: :image, data: ^data, media_type: "image/png"} =
               ContentPart.image(data, "image/png")

      assert %ContentPart{type: :file, data: ^data, filename: "doc.txt", media_type: "text/plain"} =
               ContentPart.file(data, "doc.txt", "text/plain")
    end

    test "inspect protocol shows compact representation" do
      assert inspect(ContentPart.text("Hello")) =~ "#ContentPart<:text \"Hello\">"

      assert inspect(ContentPart.text("Very long text that should be truncated")) =~
               "Very long text that should be ...\">"

      assert inspect(ContentPart.image(<<1, 2, 3>>, "image/png")) =~
               "#ContentPart<:image image/png (3 bytes)>"
    end

    test "supports metadata" do
      part = ContentPart.text("Hello", %{source: "user"})
      assert part.metadata == %{source: "user"}
    end
  end

  describe "Message" do
    test "creates messages with roles" do
      content = [ContentPart.text("Hello")]

      for role <- [:user, :assistant, :system, :tool] do
        assert %Message{role: ^role, content: ^content} = %Message{role: role, content: content}
      end
    end

    test "validates messages" do
      valid_message = %Message{role: :user, content: [ContentPart.text("Hi")]}
      assert Message.valid?(valid_message)

      invalid_message = %{role: :user, content: "not a list"}
      refute Message.valid?(invalid_message)
    end

    test "inspect protocol shows content types" do
      assert inspect(%Message{role: :user, content: [ContentPart.text("Hi")]}) =~
               "#Message<:user text>"

      assert inspect(%Message{
               role: :assistant,
               content: [ContentPart.text("Hi"), ContentPart.thinking("Think")]
             }) =~ "#Message<:assistant text,thinking>"

      assert inspect(%Message{role: :system, content: []}) =~ "#Message<:system >"
    end

    test "supports optional fields" do
      message = %Message{
        role: :assistant,
        content: [ContentPart.text("Hi")],
        name: "bot",
        tool_call_id: "123",
        tool_calls: [%{id: "123"}],
        metadata: %{id: "gpt-4"}
      }

      assert message.name == "bot"
      assert message.tool_call_id == "123"
      assert message.tool_calls == [%{id: "123"}]
      assert message.metadata == %{id: "gpt-4"}
    end
  end
end

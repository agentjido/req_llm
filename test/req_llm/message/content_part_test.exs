defmodule ReqLLM.Message.ContentPartTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Message.ContentPart

  describe "text/1 and text/2" do
    test "creates text content part" do
      part = ContentPart.text("hello world")

      assert %ContentPart{type: :text, text: "hello world", metadata: %{}} = part
      assert part.url == nil
      assert part.data == nil
    end

    test "creates text with metadata" do
      metadata = %{lang: "en", source: "user"}
      part = ContentPart.text("hello", metadata)

      assert %ContentPart{type: :text, text: "hello", metadata: ^metadata} = part
    end
  end

  describe "thinking/1 and thinking/2" do
    test "creates thinking content part" do
      part = ContentPart.thinking("thinking step")

      assert %ContentPart{type: :thinking, text: "thinking step", metadata: %{}} = part
    end

    test "creates thinking with metadata" do
      metadata = %{step: 1}
      part = ContentPart.thinking("first thought", metadata)

      assert %ContentPart{type: :thinking, text: "first thought", metadata: ^metadata} = part
    end
  end

  describe "image_url/1" do
    test "creates image URL content part" do
      url = "https://example.com/image.jpg"
      part = ContentPart.image_url(url)

      assert %ContentPart{type: :image_url, url: ^url} = part
      assert part.data == nil
      assert part.media_type == nil
    end
  end

  describe "image/2" do
    setup do
      %{
        png_data: <<137, 80, 78, 71, 13, 10, 26, 10>>,
        jpeg_data: <<255, 216, 255, 224>>
      }
    end

    test "creates image content part with default media type", %{png_data: data} do
      part = ContentPart.image(data)

      assert %ContentPart{type: :image, data: ^data, media_type: "image/png"} = part
      assert part.url == nil
      assert part.filename == nil
    end

    test "creates image with custom media type", %{jpeg_data: data} do
      part = ContentPart.image(data, "image/jpeg")

      assert %ContentPart{type: :image, data: ^data, media_type: "image/jpeg"} = part
    end
  end

  describe "file/3" do
    setup do
      %{
        file_data: "file contents here",
        filename: "test.txt"
      }
    end

    test "creates file content part with default media type", %{file_data: data, filename: name} do
      part = ContentPart.file(data, name)

      assert %ContentPart{
               type: :file,
               data: ^data,
               filename: ^name,
               media_type: "application/octet-stream"
             } = part
    end

    test "creates file with custom media type", %{file_data: data, filename: name} do
      part = ContentPart.file(data, name, "text/plain")

      assert %ContentPart{
               type: :file,
               data: ^data,
               filename: ^name,
               media_type: "text/plain"
             } = part
    end
  end

  describe "struct validation and edge cases" do
    test "requires type field" do
      assert_raise ArgumentError, fn ->
        struct!(ContentPart, %{})
      end
    end

    test "accepts valid content types" do
      valid_types = [:text, :image_url, :image, :file, :thinking]

      for type <- valid_types do
        part = struct!(ContentPart, %{type: type})
        assert part.type == type
      end
    end

    test "valid?/1 returns true for valid content parts" do
      part = ContentPart.text("hello")
      assert ContentPart.valid?(part)

      part = ContentPart.image_url("https://example.com/pic.jpg")
      assert ContentPart.valid?(part)
    end

    test "valid?/1 returns false for invalid content parts" do
      invalid_part = %{type: :text, text: "not a content part"}
      refute ContentPart.valid?(invalid_part)

      refute ContentPart.valid?(nil)
      refute ContentPart.valid?(%{})
    end

    test "has proper default values" do
      part = struct!(ContentPart, %{type: :text})

      assert part.text == nil
      assert part.url == nil
      assert part.data == nil
      assert part.media_type == nil
      assert part.filename == nil
      assert part.metadata == %{}
    end
  end

  describe "Inspect implementation" do
    test "inspects text content part" do
      part = ContentPart.text("Hello world")
      output = inspect(part)

      assert output =~ "#ContentPart<"
      assert output =~ "text"
      assert output =~ "Hello world"
    end

    test "inspects thinking content part" do
      part = ContentPart.thinking("I think...")
      output = inspect(part)

      assert output =~ "#ContentPart<"
      assert output =~ "thinking"
      assert output =~ "I think..."
    end

    test "truncates long text content" do
      long_text = String.duplicate("a", 50)
      part = ContentPart.text(long_text)
      output = inspect(part)

      truncated_part = String.slice(long_text, 0, 30)
      assert output =~ "#{truncated_part}..."
      assert String.length(truncated_part) == 30
      refute String.length(output) > 100
    end

    test "inspects image_url content part" do
      part = ContentPart.image_url("https://example.com/pic.jpg")
      output = inspect(part)

      assert output =~ "#ContentPart<"
      assert output =~ "image_url"
      assert output =~ "url: https://example.com/pic.jpg"
    end

    test "inspects image content part" do
      data = <<1, 2, 3, 4, 5>>
      part = ContentPart.image(data, "image/jpeg")
      output = inspect(part)

      assert output =~ "#ContentPart<"
      assert output =~ "image"
      assert output =~ "image/jpeg (5 bytes)"
    end

    test "inspects file content part" do
      data = "file content"
      part = ContentPart.file(data, "test.txt", "text/plain")
      output = inspect(part)

      assert output =~ "#ContentPart<"
      assert output =~ "file"
      assert output =~ "text/plain (12 bytes)"
    end

    test "inspects file content part with nil data" do
      part = struct!(ContentPart, %{type: :file, data: nil, media_type: "text/plain"})
      output = inspect(part)

      assert output =~ "text/plain (0 bytes)"
    end

    test "handles nil text in inspect" do
      part = struct!(ContentPart, %{type: :text, text: nil})
      output = inspect(part)

      assert output =~ "nil"
    end
  end

  describe "serialization" do
    test "round-trip JSON encoding/decoding for all constructors" do
      parts = [
        ContentPart.text("hello"),
        ContentPart.thinking("thinking"),
        ContentPart.image_url("https://example.com/pic.jpg"),
        ContentPart.image(<<1, 2, 3>>, "image/png"),
        ContentPart.file("data", "file.txt", "text/plain")
      ]

      for part <- parts do
        json = Jason.encode!(part)
        decoded = Jason.decode!(json, keys: :atoms)
        assert String.to_atom(decoded.type) == part.type
      end
    end
  end
end

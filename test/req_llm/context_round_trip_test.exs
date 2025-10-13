defmodule ReqLLM.ContextRoundTripTest do
  use ExUnit.Case, async: true

  import ReqLLM.Context

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  defp message_from_json(data) do
    struct(Message,
      role: String.to_existing_atom(data["role"]),
      content:
        Enum.map(data["content"] || [], fn part_data ->
          decoded_data =
            if part_data["data"], do: Base.decode64!(part_data["data"]), else: part_data["data"]

          struct(ContentPart, %{
            type: String.to_existing_atom(part_data["type"]),
            text: part_data["text"],
            url: part_data["url"],
            data: decoded_data,
            media_type: part_data["media_type"],
            filename: part_data["filename"],
            metadata: part_data["metadata"] || %{}
          })
        end),
      name: data["name"],
      tool_call_id: data["tool_call_id"],
      tool_calls: data["tool_calls"],
      metadata: data["metadata"] || %{}
    )
  end

  defp context_from_json(json) do
    decoded = Jason.decode!(json)
    struct(Context, %{messages: Enum.map(decoded["messages"], &message_from_json/1)})
  end

  describe "round-trip: text messages" do
    test "simple user message" do
      original = Context.new([user("Hello, world!")])

      json = Jason.encode!(original)
      restored = context_from_json(json)

      assert length(restored.messages) == 1
      [message] = restored.messages
      assert message.role == :user
      [part] = message.content
      assert part.text == "Hello, world!"
    end

    test "multi-message conversation" do
      original =
        Context.new([
          user("What is 2+2?"),
          assistant("2+2 equals 4"),
          user("Thanks!")
        ])

      json = Jason.encode!(original)
      restored = context_from_json(json)

      assert length(restored.messages) == 3
      assert Enum.at(restored.messages, 0).role == :user
      assert Enum.at(restored.messages, 1).role == :assistant
      assert Enum.at(restored.messages, 2).role == :user
    end
  end

  describe "round-trip: tool calls" do
    test "assistant message with tool calls" do
      tool_call = %{
        id: "call_123",
        type: "function",
        function: %{
          name: "get_weather",
          arguments: ~s({"location":"NYC"})
        }
      }

      original =
        Context.new([
          user("What's the weather?"),
          %Message{
            role: :assistant,
            content: [],
            tool_calls: [tool_call]
          }
        ])

      json = Jason.encode!(original)
      restored = context_from_json(json)

      assert length(restored.messages) == 2
      assistant_msg = Enum.at(restored.messages, 1)
      assert assistant_msg.role == :assistant
      assert length(assistant_msg.tool_calls) == 1
      [restored_call] = assistant_msg.tool_calls
      assert restored_call["id"] == "call_123"
      assert restored_call["type"] == "function"
      assert restored_call["function"]["name"] == "get_weather"
      assert restored_call["function"]["arguments"] == ~s({"location":"NYC"})
    end

    test "tool result message" do
      original =
        Context.new([
          %Message{
            role: :tool,
            content: [ContentPart.text("Temperature: 72F")],
            tool_call_id: "call_123"
          }
        ])

      json = Jason.encode!(original)
      restored = context_from_json(json)

      assert length(restored.messages) == 1
      [tool_msg] = restored.messages
      assert tool_msg.role == :tool
      [part] = tool_msg.content
      assert part.text == "Temperature: 72F"
      assert tool_msg.tool_call_id == "call_123"
    end
  end

  describe "round-trip: binary data" do
    test "image with binary data" do
      binary_data = <<137, 80, 78, 71, 13, 10, 26, 10>>

      image_part = ContentPart.image(binary_data, "image/png")

      original =
        Context.new([
          %Message{
            role: :user,
            content: [
              ContentPart.text("What's in this image?"),
              image_part
            ]
          }
        ])

      json = Jason.encode!(original)
      restored = context_from_json(json)

      assert length(restored.messages) == 1
      [message] = restored.messages
      assert length(message.content) == 2
      [_text_part, restored_image] = message.content
      assert restored_image.type == :image
      assert restored_image.media_type == "image/png"
      assert restored_image.data == binary_data
    end

    test "verify base64 round-trip integrity" do
      original_binary = :crypto.strong_rand_bytes(256)

      image_part = ContentPart.image(original_binary, "image/jpeg")

      original = Context.new([user([image_part])])

      json = Jason.encode!(original)
      restored = context_from_json(json)

      [message] = restored.messages
      [image] = message.content
      assert image.data == original_binary
      assert image.media_type == "image/jpeg"
    end
  end

  describe "LLM response resubmission" do
    test "serialize/deserialize/append workflow" do
      context = Context.new([user("What is the capital of France?")])

      json = Jason.encode!(context)
      restored = context_from_json(json)

      updated =
        restored
        |> Context.append(assistant("The capital of France is Paris."))
        |> Context.append(user("And what is its population?"))

      assert length(updated.messages) == 3
      assert Enum.at(updated.messages, 0).role == :user
      assert Enum.at(updated.messages, 1).role == :assistant
      assert Enum.at(updated.messages, 2).role == :user
    end

    test "preserves tool call context across serialization" do
      tool_call = %{
        id: "call_456",
        type: "function",
        function: %{name: "calculate", arguments: ~s({"x":5,"y":3})}
      }

      original =
        Context.new([
          user("Calculate 5 + 3"),
          %Message{
            role: :assistant,
            content: [],
            tool_calls: [tool_call]
          }
        ])

      json = Jason.encode!(original)
      restored = context_from_json(json)

      updated =
        restored
        |> Context.append(%Message{
          role: :tool,
          content: [ContentPart.text("8")],
          tool_call_id: "call_456"
        })
        |> Context.append(assistant("The result is 8."))

      assert length(updated.messages) == 4
      assert Enum.at(updated.messages, 1).tool_calls != nil
      assert Enum.at(updated.messages, 2).tool_call_id == "call_456"
    end
  end

  describe "Context.validate/1 tool message validation" do
    test "rejects tool message without tool_call_id" do
      invalid_context =
        Context.new([
          %Message{
            role: :tool,
            content: [ContentPart.text("Result data")]
          }
        ])

      assert {:error, _} = Context.validate(invalid_context)
    end

    test "accepts tool message with tool_call_id" do
      valid_context =
        Context.new([
          %Message{
            role: :tool,
            content: [ContentPart.text("Result data")],
            tool_call_id: "call_789"
          }
        ])

      assert {:ok, ^valid_context} = Context.validate(valid_context)
    end

    test "validates multiple tool messages" do
      context =
        Context.new([
          %Message{
            role: :tool,
            content: [ContentPart.text("Result 1")],
            tool_call_id: "call_1"
          },
          %Message{
            role: :tool,
            content: [ContentPart.text("Result 2")],
            tool_call_id: "call_2"
          }
        ])

      assert {:ok, ^context} = Context.validate(context)
    end

    test "rejects if any tool message lacks tool_call_id" do
      invalid_context =
        Context.new([
          %Message{
            role: :tool,
            content: [ContentPart.text("Result 1")],
            tool_call_id: "call_1"
          },
          %Message{
            role: :tool,
            content: [ContentPart.text("Result 2")]
          }
        ])

      assert {:error, _} = Context.validate(invalid_context)
    end
  end
end

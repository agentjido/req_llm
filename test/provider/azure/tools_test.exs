defmodule ReqLLM.Providers.Azure.ToolsTest do
  @moduledoc """
  Tests for Azure provider tool calling and multi-modal support.

  Covers:
  - Multi-modal (image) content handling for both OpenAI and Claude formatters
  - Tool result message formatting
  - Tool result round-trip conversations
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Azure

  describe "multi-modal (image) support" do
    test "OpenAI formatter handles image content parts" do
      image_part = %ReqLLM.Message.ContentPart{
        type: :image_url,
        url: "https://example.com/image.jpg"
      }

      text_part = %ReqLLM.Message.ContentPart{
        type: :text,
        text: "What is in this image?"
      }

      message = %ReqLLM.Message{
        role: :user,
        content: [text_part, image_part]
      }

      context = ReqLLM.Context.new([message])

      body = Azure.OpenAI.format_request("gpt-4o", context, stream: false)

      assert body["messages"]
      user_message = hd(body["messages"])
      assert user_message["role"] == "user"
      assert is_list(user_message["content"])
    end

    test "Claude formatter handles image content parts" do
      image_part = %ReqLLM.Message.ContentPart{
        type: :image_url,
        url: "https://example.com/image.jpg"
      }

      text_part = %ReqLLM.Message.ContentPart{
        type: :text,
        text: "What is in this image?"
      }

      message = %ReqLLM.Message{
        role: :user,
        content: [text_part, image_part]
      }

      context = ReqLLM.Context.new([message])

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, stream: false)

      assert body.messages
      user_message = hd(body.messages)
      assert user_message.role == "user"
      assert is_list(user_message.content)
    end

    test "routes vision-capable models correctly" do
      model = %LLMDB.Model{
        id: "gpt-4o",
        provider: :azure,
        capabilities: %{chat: true, vision: true}
      }

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Describe this image",
          base_url: "https://my-resource.openai.azure.com/openai",
          deployment: "gpt-4o-vision"
        )

      url = URI.to_string(request.url)
      assert url =~ "/chat/completions"
    end

    test "OpenAI formatter includes stream option with multi-modal content" do
      image_part = %ReqLLM.Message.ContentPart{
        type: :image_url,
        url: "https://example.com/image.jpg"
      }

      text_part = %ReqLLM.Message.ContentPart{
        type: :text,
        text: "What is in this image?"
      }

      message = %ReqLLM.Message{
        role: :user,
        content: [text_part, image_part]
      }

      context = ReqLLM.Context.new([message])

      body = Azure.OpenAI.format_request("gpt-4o", context, stream: true)

      assert body["stream"] == true
      assert body["stream_options"] == %{"include_usage" => true}
      assert is_list(body["messages"])
    end

    test "Claude formatter includes stream option with multi-modal content" do
      image_part = %ReqLLM.Message.ContentPart{
        type: :image_url,
        url: "https://example.com/image.jpg"
      }

      text_part = %ReqLLM.Message.ContentPart{
        type: :text,
        text: "What is in this image?"
      }

      message = %ReqLLM.Message{
        role: :user,
        content: [text_part, image_part]
      }

      context = ReqLLM.Context.new([message])

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, stream: true)

      assert body.stream == true
      assert is_list(body.messages)
    end
  end

  describe "tool result messages in context" do
    test "OpenAI: formats tool result message in context" do
      tool_result_msg = ReqLLM.Context.tool_result("call_123", "get_weather", "Sunny, 72F")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("What's the weather?"),
          tool_result_msg
        ])

      body = Azure.OpenAI.format_request("gpt-4o", context, stream: false)

      assert length(body["messages"]) == 2
      tool_msg = Enum.at(body["messages"], 1)
      assert tool_msg["role"] == "tool"
      assert tool_msg["tool_call_id"] == "call_123"
    end

    test "Claude: formats tool result message in context" do
      tool_result_msg = ReqLLM.Context.tool_result("toolu_123", "get_weather", "Sunny, 72F")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("What's the weather?"),
          tool_result_msg
        ])

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, stream: false)

      assert body.messages != []
      user_msg = Enum.find(body.messages, &(&1.role == "user" && is_list(&1.content)))
      assert user_msg, "Expected a user message with list content containing tool_result"

      tool_result = Enum.find(user_msg.content, &(&1[:type] == "tool_result"))
      assert tool_result, "Expected tool_result in user message content"
      assert tool_result[:tool_use_id] == "toolu_123"
    end
  end

  describe "tool result round-trip conversations" do
    test "OpenAI: multi-turn with tool call and result" do
      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather",
          parameter_schema: [location: [type: :string, required: true]],
          callback: fn _ -> {:ok, %{}} end
        )

      assistant_msg =
        ReqLLM.Context.assistant("",
          tool_calls: [
            %{id: "call_abc123", name: "get_weather", arguments: %{"location" => "NYC"}}
          ]
        )

      tool_result = ReqLLM.Context.tool_result("call_abc123", "get_weather", "Sunny, 72F")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("What's the weather in NYC?"),
          assistant_msg,
          tool_result
        ])

      body = Azure.OpenAI.format_request("gpt-4o", context, tools: [tool], stream: false)

      messages = body["messages"]
      assert length(messages) >= 2

      roles = Enum.map(messages, & &1["role"])
      assert "user" in roles
      assert "tool" in roles or "assistant" in roles
    end

    test "OpenAI: multiple tool results in sequence" do
      tool_result_1 = ReqLLM.Context.tool_result("call_1", "get_weather", "Sunny")
      tool_result_2 = ReqLLM.Context.tool_result("call_2", "get_time", "10:00 AM")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("Get weather and time"),
          tool_result_1,
          tool_result_2
        ])

      body = Azure.OpenAI.format_request("gpt-4o", context, stream: false)

      messages = body["messages"]
      tool_msgs = Enum.filter(messages, &(&1["role"] == "tool"))
      assert length(tool_msgs) == 2
    end

    test "Claude: multi-turn with tool use and result" do
      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather",
          parameter_schema: [location: [type: :string, required: true]],
          callback: fn _ -> {:ok, %{}} end
        )

      assistant_msg =
        ReqLLM.Context.assistant("",
          tool_calls: [
            %{id: "toolu_abc123", name: "get_weather", arguments: %{"location" => "NYC"}}
          ]
        )

      tool_result = ReqLLM.Context.tool_result("toolu_abc123", "get_weather", "Sunny, 72F")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("What's the weather in NYC?"),
          assistant_msg,
          tool_result
        ])

      body =
        Azure.Anthropic.format_request("claude-3-sonnet", context, tools: [tool], stream: false)

      assert is_list(body.messages)
      assert length(body.messages) >= 2
    end

    test "Claude: tool result content is preserved" do
      tool_result = ReqLLM.Context.tool_result("toolu_test", "my_tool", "Result data here")

      context = ReqLLM.Context.new([tool_result])

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, stream: false)

      user_msg = Enum.find(body.messages, fn m -> m.role == "user" && is_list(m.content) end)
      assert user_msg, "Expected a user message with list content containing tool_result"

      tool_result_content = Enum.find(user_msg.content, &(&1[:type] == "tool_result"))
      assert tool_result_content, "Expected tool_result in user message content"
      assert tool_result_content[:content] == "Result data here"
    end
  end
end

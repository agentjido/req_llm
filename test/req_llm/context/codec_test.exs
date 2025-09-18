defmodule ReqLLM.Context.CodecTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Context.Codec
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Model
  alias ReqLLM.Tool

  # Test helpers for consistent test data creation
  defp create_message(role, content, opts \\ []) do
    content_parts =
      case content do
        text when is_binary(text) -> [%ContentPart{type: :text, text: text}]
        parts when is_list(parts) -> parts
        part -> [part]
      end

    %Message{
      role: role,
      content: content_parts,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp create_tool_call_part(name, input, id) do
    %ContentPart{
      type: :tool_call,
      tool_name: name,
      input: input,
      tool_call_id: id
    }
  end

  defp create_weather_tool do
    {:ok, tool} =
      Tool.new(
        name: "get_weather",
        description: "Get current weather",
        parameter_schema: [location: [type: :string, required: true]],
        callback: fn _ -> {:ok, "sunny"} end
      )

    tool
  end

  describe "protocol implementations" do
    test "ReqLLM.Context delegates to Map implementation" do
      message = create_message(:user, "Hello")
      context = Context.new([message])
      model = %Model{provider: :openai, model: "gpt-4"}

      result = Codec.encode_request(context, model)

      assert result == %{
               model: "gpt-4",
               messages: [%{role: "user", content: "Hello"}]
             }
    end

    test "Any implementation returns error for unsupported types" do
      test_cases = [
        {:unknown_type, %Model{provider: :test, model: "test"}},
        {:some_atom, "test-model"},
        {42, "test-model"}
      ]

      for {input, model} <- test_cases do
        assert Codec.encode_request(input, model) == {:error, :not_implemented}
      end
    end
  end

  describe "basic message encoding" do
    test "encodes single and multiple messages with different roles" do
      messages = [
        create_message(:system, "You are helpful"),
        create_message(:user, "Hello"),
        create_message(:assistant, "Hi there!"),
        create_message(:tool, "Result")
      ]

      context = Context.new(messages)
      model = %Model{provider: :openai, model: "gpt-4"}

      result = Codec.encode_request(context, model)

      assert result == %{
               model: "gpt-4",
               messages: [
                 %{role: "system", content: "You are helpful"},
                 %{role: "user", content: "Hello"},
                 %{role: "assistant", content: "Hi there!"},
                 %{role: "tool", content: "Result"}
               ]
             }
    end

    test "handles different content formats" do
      test_cases = [
        # Binary string content
        {"Simple text", "Simple text"},
        # Single text part (flattened)
        {[%ContentPart{type: :text, text: "Single part"}], "Single part"},
        # Multiple parts (not flattened)
        {[
           %ContentPart{type: :text, text: "Part 1"},
           create_tool_call_part("test", %{}, "123")
         ],
         [
           %{type: "text", text: "Part 1"},
           %{id: "123", type: "function", function: %{name: "test", arguments: "{}"}}
         ]}
      ]

      for {input_content, expected_content} <- test_cases do
        message = %Message{role: :user, content: input_content, metadata: %{}}
        context = %{messages: [message]}
        model = %Model{provider: :openai, model: "gpt-4"}

        result = Codec.encode_request(context, model)
        assert result.messages == [%{role: "user", content: expected_content}]
      end
    end

    test "filters unsupported content parts and handles single text after filtering" do
      # Test case 1: Multiple parts after filtering
      mixed_content = [
        %ContentPart{type: :text, text: "Keep this"},
        # Returns nil, gets filtered
        %ContentPart{type: :image_url, url: "filtered.jpg"},
        create_tool_call_part("keep_tool", %{arg: "value"}, "456")
      ]

      message = create_message(:user, mixed_content)
      context = %{messages: [message]}
      model = %Model{provider: :openai, model: "gpt-4"}

      result = Codec.encode_request(context, model)

      expected_content = [
        %{type: "text", text: "Keep this"},
        %{
          id: "456",
          type: "function",
          function: %{name: "keep_tool", arguments: ~s({"arg":"value"})}
        }
      ]

      assert result.messages == [%{role: "user", content: expected_content}]

      # Test case 2: Single text part after filtering (hits line 90)
      filtered_to_single = [
        %ContentPart{type: :text, text: "Only this remains"},
        # Returns nil, gets filtered
        %ContentPart{type: :image_url, url: "filtered.jpg"}
      ]

      message2 = create_message(:user, filtered_to_single)
      context2 = %{messages: [message2]}

      result2 = Codec.encode_request(context2, model)
      assert result2.messages == [%{role: "user", content: "Only this remains"}]
    end
  end

  describe "model name extraction" do
    test "extracts model name from different input types" do
      context = %{messages: []}

      test_cases = [
        {%Model{provider: :openai, model: "gpt-4"}, "gpt-4"},
        {"gpt-3.5-turbo", "gpt-3.5-turbo"},
        {%{name: "some-model"}, "unknown"},
        {:invalid, "unknown"}
      ]

      for {model_input, expected} <- test_cases do
        result = Codec.encode_request(context, model_input)
        assert result.model == expected
      end
    end
  end

  describe "tool handling" do
    test "encodes tools when present and omits when empty/missing" do
      weather_tool = create_weather_tool()
      message = create_message(:user, "What's the weather?")

      test_cases = [
        # With tools
        {%{messages: [message], tools: [weather_tool]}, true},
        # Empty tools list
        {%{messages: [message], tools: []}, false},
        # No tools key
        {%{messages: [message]}, false}
      ]

      model = %Model{provider: :openai, model: "gpt-4"}

      for {context, should_have_tools} <- test_cases do
        result = Codec.encode_request(context, model)

        if should_have_tools do
          assert Map.has_key?(result, :tools)
          assert [tool_spec] = result.tools
          assert tool_spec["type"] == "function"
          assert tool_spec["function"]["name"] == "get_weather"
          assert tool_spec["function"]["description"] == "Get current weather"
          assert is_map(tool_spec["function"]["parameters"])
        else
          refute Map.has_key?(result, :tools)
        end

        # Common assertions
        assert result.model == "gpt-4"
        assert result.messages == [%{role: "user", content: "What's the weather?"}]
      end
    end

    test "encodes tool calls in messages" do
      tool_call_part = create_tool_call_part("get_weather", %{location: "New York"}, "call_123")
      message = create_message(:assistant, [tool_call_part])

      context = Context.new([message])
      model = %Model{provider: :openai, model: "gpt-4"}

      result = Codec.encode_request(context, model)

      expected = %{
        model: "gpt-4",
        messages: [
          %{
            role: "assistant",
            content: [
              %{
                id: "call_123",
                type: "function",
                function: %{
                  name: "get_weather",
                  arguments: ~s({"location":"New York"})
                }
              }
            ]
          }
        ]
      }

      assert result == expected
    end
  end

  describe "edge cases" do
    test "handles empty contexts and malformed JSON encoding" do
      # Empty messages
      empty_result =
        Codec.encode_request(%{messages: []}, %Model{provider: :openai, model: "gpt-4"})

      assert empty_result == %{model: "gpt-4", messages: []}

      # Tool call with atoms (Jason can handle this)
      bad_input = %{circular: :cannot_encode_atoms_safely}
      tool_call = create_tool_call_part("test_tool", bad_input, "call_456")
      message = create_message(:assistant, [tool_call])

      context = %{messages: [message]}
      model = %Model{provider: :openai, model: "gpt-4"}

      result = Codec.encode_request(context, model)

      assert %{
               messages: [
                 %{
                   role: "assistant",
                   content: [
                     %{
                       function: %{arguments: json_string}
                     }
                   ]
                 }
               ]
             } = result

      assert is_binary(json_string)
    end
  end
end

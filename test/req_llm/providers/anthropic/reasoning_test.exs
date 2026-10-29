defmodule ReqLLM.Providers.Anthropic.ReasoningTest do
  @moduledoc """
  Tests Anthropic thinking options, reasoning details, and thinking block replay.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Anthropic, async: true

  alias ReqLLM.Providers.Anthropic

  describe "request preparation & pipeline wiring" do
    test "prepare_request encodes Claude Opus 4.8 adaptive reasoning" do
      {:ok, request} =
        Anthropic.prepare_request(:chat, "anthropic:claude-opus-4-8", "Hello world",
          api_key: "test-key",
          max_tokens: 100,
          reasoning_effort: :low,
          temperature: 0.0
        )

      decoded = request |> Anthropic.encode_body() |> ReqLLM.Test.Helpers.json_body()

      assert decoded["model"] == "claude-opus-4-8"
      assert decoded["thinking"] == %{"type" => "adaptive", "display" => "summarized"}
      assert decoded["output_config"] == %{"effort" => "low"}
      refute Map.has_key?(decoded, "temperature")
    end
  end

  describe "body encoding & context translation" do
    test "encode_request preserves assistant thinking content parts" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      context =
        ReqLLM.Context.new([
          %ReqLLM.Message{
            role: :assistant,
            content: [
              ReqLLM.Message.ContentPart.thinking("private", %{"signature" => "sig_123"}),
              ReqLLM.Message.ContentPart.thinking("", %{"redacted" => true, "data" => "opaque"})
            ]
          }
        ])

      request = ReqLLM.Providers.Anthropic.Context.encode_request(context, model)
      [message] = request[:messages]

      assert message[:content] == [
               %{type: "thinking", thinking: "private", signature: "sig_123"},
               %{type: "redacted_thinking", data: "opaque"}
             ]
    end

    test "encode_request encodes encrypted Anthropic reasoning details as redacted thinking" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      detail = %ReqLLM.Message.ReasoningDetails{
        provider: :anthropic,
        encrypted?: true,
        provider_data: %{"data" => "opaque"}
      }

      context =
        ReqLLM.Context.new([
          %ReqLLM.Message{role: :assistant, content: [], reasoning_details: [detail]}
        ])

      request = ReqLLM.Providers.Anthropic.Context.encode_request(context, model)
      [message] = request[:messages]

      assert message[:content] == [%{type: "redacted_thinking", data: "opaque"}]
    end
  end

  describe "option translation" do
    test "translate_options preserves supported Claude Opus 4.8 effort levels" do
      {:ok, model} = ReqLLM.model("anthropic:claude-opus-4-8")

      for effort <- [:xhigh, :max] do
        {translated_opts, warnings} =
          Anthropic.translate_options(:chat, model,
            reasoning_effort: effort,
            temperature: 0.0,
            top_p: 0.5,
            max_tokens: 100
          )

        assert [temperature_warning, top_p_warning] = warnings
        assert temperature_warning =~ "does not accept :temperature"
        assert top_p_warning =~ "does not accept :top_p"

        assert Keyword.get(translated_opts, :thinking) == %{
                 type: "adaptive",
                 display: "summarized"
               }

        assert Keyword.get(translated_opts, :output_config) == %{effort: Atom.to_string(effort)}
        refute Keyword.has_key?(translated_opts, :top_p)
        refute Keyword.has_key?(translated_opts, :temperature)
      end
    end

    test "translate_options defaults direct adaptive thinking display to summarized" do
      {:ok, model} = ReqLLM.model("anthropic:claude-opus-4-8")

      cases = [
        {%{type: "adaptive"}, %{type: "adaptive", display: "summarized"}},
        {%{"type" => "adaptive"}, %{"type" => "adaptive", "display" => "summarized"}}
      ]

      for {thinking, expected} <- cases do
        {translated_opts, [warning]} =
          Anthropic.translate_options(:chat, model,
            thinking: thinking,
            temperature: 0.0,
            max_tokens: 100
          )

        assert warning =~ "does not accept :temperature"
        assert Keyword.get(translated_opts, :thinking) == expected
        refute Keyword.has_key?(translated_opts, :temperature)
      end
    end

    test "translate_options removes Claude Opus 4.8 sampling params without reasoning" do
      {:ok, model} = ReqLLM.model("anthropic:claude-opus-4-8")

      {translated_opts, warnings} =
        Anthropic.translate_options(:chat, model,
          max_tokens: 100,
          temperature: 0.0,
          top_p: 0.5,
          top_k: 10,
          anthropic_top_k: 10
        )

      assert length(warnings) == 4

      for key <- [":temperature", ":top_p", ":top_k", ":anthropic_top_k"] do
        assert Enum.any?(warnings, &(&1 =~ "does not accept #{key},"))
      end

      assert Keyword.get(translated_opts, :max_tokens) == 100
      refute Keyword.has_key?(translated_opts, :temperature)
      refute Keyword.has_key?(translated_opts, :top_p)
      refute Keyword.has_key?(translated_opts, :top_k)
      refute Keyword.has_key?(translated_opts, :anthropic_top_k)
      refute Keyword.has_key?(translated_opts, :thinking)
      refute Keyword.has_key?(translated_opts, :output_config)
    end

    test "translate_options removes output_config when forced tool choice disables thinking" do
      {:ok, model} = ReqLLM.model("anthropic:claude-opus-4-8")

      {translated_opts, []} =
        Anthropic.translate_options(:chat, model,
          reasoning_effort: :low,
          tool_choice: %{type: "tool", name: "add"}
        )

      assert Keyword.get(translated_opts, :tool_choice) == %{type: "tool", name: "add"}
      refute Keyword.has_key?(translated_opts, :thinking)
      refute Keyword.has_key?(translated_opts, :output_config)
    end
  end

  describe "turning thinking off" do
    test "reasoning_effort :none sends each model's thinking-off type" do
      cases = [
        {"anthropic:claude-sonnet-5-5", %{type: "between_tools"}},
        {"anthropic:claude-opus-5", %{type: "disabled"}},
        {"anthropic:claude-haiku-5-5", %{type: "disabled"}},
        {"anthropic:claude-opus-4-8", %{type: "disabled"}}
      ]

      for {spec, expected} <- cases do
        {:ok, model} = ReqLLM.model(spec)

        {translated_opts, []} =
          Anthropic.translate_options(:chat, model, reasoning_effort: :none, max_tokens: 100)

        assert Keyword.get(translated_opts, :thinking) == expected, spec
        refute Keyword.has_key?(translated_opts, :output_config), spec
      end
    end

    test "reasoning_effort :none leaves budget-thinking models without a thinking field" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-6")

      {translated_opts, []} =
        Anthropic.translate_options(:chat, model, reasoning_effort: :none, max_tokens: 100)

      refute Keyword.has_key?(translated_opts, :thinking)
    end

    test "reasoning_effort :none warns when the model cannot turn thinking off" do
      {:ok, model} = ReqLLM.model("anthropic:claude-opus-5-5")

      {translated_opts, [warning]} =
        Anthropic.translate_options(:chat, model, reasoning_effort: :none, max_tokens: 100)

      refute Keyword.has_key?(translated_opts, :thinking)
      assert warning =~ "cannot turn thinking off, so reasoning_effort: :none was not applied"
    end

    test "an explicit thinking-off config becomes the type the model accepts" do
      cases = [
        {"anthropic:claude-sonnet-5-5", %{type: "disabled"}, %{type: "between_tools"}},
        {"anthropic:claude-sonnet-5-5", %{"type" => "between_tools", "display" => "summarized"},
         %{type: "between_tools"}},
        {"anthropic:claude-opus-5", %{type: "between_tools"}, %{type: "disabled"}}
      ]

      for {spec, thinking, expected} <- cases do
        {:ok, model} = ReqLLM.model(spec)

        {translated_opts, []} =
          Anthropic.translate_options(:chat, model, thinking: thinking, max_tokens: 100)

        assert Keyword.get(translated_opts, :thinking) == expected, spec
      end
    end

    test "an explicit thinking-off config is passed through and warned about when the model cannot turn thinking off" do
      {:ok, model} = ReqLLM.model("anthropic:claude-opus-5-5")

      {translated_opts, [warning]} =
        Anthropic.translate_options(:chat, model, thinking: %{type: "disabled"}, max_tokens: 100)

      assert Keyword.get(translated_opts, :thinking) == %{type: "disabled"}
      assert warning =~ "cannot turn thinking off and does not accept thinking type \"disabled\""
    end

    test "forced tool choice keeps thinking off and the tool choice" do
      {:ok, model} = ReqLLM.model("anthropic:claude-opus-4-8")

      for tool_choice <- [%{type: "tool", name: "add"}, %{type: "any"}] do
        {translated_opts, []} =
          Anthropic.translate_options(:chat, model,
            reasoning_effort: :none,
            tool_choice: tool_choice
          )

        assert Keyword.get(translated_opts, :thinking) == %{type: "disabled"}
        assert Keyword.get(translated_opts, :tool_choice) == tool_choice
      end
    end
  end

  describe "sampling parameter warnings" do
    test "accepted sampling parameters produce no warning" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-6")

      {translated_opts, []} =
        Anthropic.translate_options(:chat, model, temperature: 0.0, max_tokens: 100)

      assert Keyword.get(translated_opts, :temperature) == 0.0
    end

    test "top_p dropped alongside temperature is reported" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-6")

      {translated_opts, [warning]} =
        Anthropic.translate_options(:chat, model, temperature: 0.2, top_p: 0.9)

      assert Keyword.get(translated_opts, :temperature) == 0.2
      refute Keyword.has_key?(translated_opts, :top_p)
      assert warning =~ ":top_p was dropped because :temperature is also set"
    end

    test "budget thinking reports dropped and adjusted sampling parameters" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-6")

      {translated_opts, warnings} =
        Anthropic.translate_options(:chat, model,
          reasoning_effort: :low,
          temperature: 0.5,
          top_p: 0.8,
          top_k: 10,
          anthropic_top_k: 11,
          max_tokens: 8000
        )

      assert %{type: "enabled"} = Keyword.get(translated_opts, :thinking)
      assert Keyword.get(translated_opts, :top_p) == 0.95

      assert Enum.any?(
               warnings,
               &(&1 =~ ":temperature is not compatible with extended thinking")
             )

      assert Enum.any?(warnings, &(&1 =~ ":top_k is not compatible with extended thinking"))

      assert Enum.any?(
               warnings,
               &(&1 =~ ":anthropic_top_k is not compatible with extended thinking")
             )

      assert Enum.any?(warnings, &(&1 =~ ":top_p was changed from 0.8 to 0.95"))
      refute Keyword.has_key?(translated_opts, :anthropic_top_k)
    end

    test "dropped sampling parameters are logged by default and raise with on_unsupported: :error" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-5-5")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          opts = ReqLLM.Provider.Options.process!(Anthropic, :chat, model, temperature: 0.0)
          refute Keyword.has_key?(opts, :temperature)
        end)

      assert log =~ "does not accept :temperature"

      assert_raise ReqLLM.Error.Validation.Error, ~r/does not accept :temperature/, fn ->
        ReqLLM.Provider.Options.process!(Anthropic, :chat, model,
          temperature: 0.0,
          on_unsupported: :error
        )
      end
    end
  end

  describe "map_reasoning_effort_to_budget/1" do
    test "translate_options maps reasoning_effort to thinking budget_tokens" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      test_cases = [
        {:none, nil},
        {:minimal, 512},
        {:low, 1_024},
        {:medium, 2_048},
        {:high, 4_096},
        {:xhigh, 8_192},
        {:max, 8_192}
      ]

      for {effort, expected_budget} <- test_cases do
        opts = [reasoning_effort: effort]
        {translated_opts, _warnings} = Anthropic.translate_options(:chat, model, opts)

        thinking = Keyword.get(translated_opts, :thinking)

        if expected_budget == nil do
          assert thinking == nil,
                 "Expected reasoning_effort #{inspect(effort)} to not set thinking option"
        else
          assert thinking != nil,
                 "Expected reasoning_effort #{inspect(effort)} to set thinking option"

          assert thinking.budget_tokens == expected_budget,
                 "Expected reasoning_effort #{inspect(effort)} to map to budget #{expected_budget}"
        end
      end
    end
  end

  describe "thinking blocks (reasoning details)" do
    test "decode_response extracts thinking blocks into reasoning_details" do
      response_with_thinking = %{
        "id" => "msg_01ABC123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-5-20250929",
        "content" => [
          %{
            "type" => "thinking",
            "thinking" => "Let me analyze this step by step...",
            "signature" => "EqQBtest123"
          },
          %{"type" => "text", "text" => "The answer is 42."}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
      }

      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      {:ok, response} =
        ReqLLM.Providers.Anthropic.Response.decode_response(response_with_thinking, model)

      assert response.message != nil
      assert response.message.reasoning_details != nil
      assert length(response.message.reasoning_details) == 1

      [detail] = response.message.reasoning_details
      assert detail.text == "Let me analyze this step by step..."
      assert detail.signature == "EqQBtest123"
      assert detail.encrypted? == true
      assert detail.provider == :anthropic
      assert detail.format == "anthropic-thinking-v1"
      assert detail.index == 0
      assert detail.provider_data == %{"type" => "thinking"}
    end

    test "decode_response handles response without thinking blocks" do
      response_without_thinking = %{
        "id" => "msg_01ABC123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-5-20250929",
        "content" => [
          %{"type" => "text", "text" => "Just a regular response."}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 5, "output_tokens" => 10}
      }

      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      {:ok, response} =
        ReqLLM.Providers.Anthropic.Response.decode_response(response_without_thinking, model)

      assert response.message != nil
      assert response.message.reasoning_details == nil
    end

    test "decode_response handles multiple thinking blocks" do
      response_with_multiple_thinking = %{
        "id" => "msg_01ABC123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-5-20250929",
        "content" => [
          %{"type" => "thinking", "thinking" => "First thought...", "signature" => "sig1"},
          %{"type" => "thinking", "thinking" => "Second thought...", "signature" => "sig2"},
          %{"type" => "text", "text" => "My conclusion."}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 30}
      }

      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      {:ok, response} =
        ReqLLM.Providers.Anthropic.Response.decode_response(
          response_with_multiple_thinking,
          model
        )

      assert length(response.message.reasoning_details) == 2

      [first, second] = response.message.reasoning_details
      assert first.text == "First thought..."
      assert first.index == 0
      assert second.text == "Second thought..."
      assert second.index == 1
    end

    test "encode_message includes thinking blocks for assistant with reasoning_details" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      reasoning_detail = %ReqLLM.Message.ReasoningDetails{
        text: "My thinking process...",
        signature: "EqQBsignature123",
        encrypted?: false,
        provider: :anthropic,
        format: "anthropic-thinking-v1",
        index: 0,
        provider_data: %{"type" => "thinking"}
      }

      assistant_message = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "The answer is 42."}],
        reasoning_details: [reasoning_detail],
        metadata: %{}
      }

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("What is the meaning of life?"),
          assistant_message
        ])

      encoded = ReqLLM.Providers.Anthropic.Context.encode_request(context, model)
      messages = encoded[:messages]

      assistant_msg = Enum.find(messages, fn m -> m[:role] == "assistant" end)
      assert assistant_msg != nil
      assert is_list(assistant_msg[:content])

      content_blocks = assistant_msg[:content]
      thinking_block = Enum.find(content_blocks, fn b -> b[:type] == "thinking" end)
      text_block = Enum.find(content_blocks, fn b -> b[:type] == "text" end)

      assert thinking_block != nil
      assert thinking_block[:thinking] == "My thinking process..."
      assert thinking_block[:signature] == "EqQBsignature123"

      assert text_block != nil
      assert text_block[:text] == "The answer is 42."

      thinking_index = Enum.find_index(content_blocks, fn b -> b[:type] == "thinking" end)
      text_index = Enum.find_index(content_blocks, fn b -> b[:type] == "text" end)
      assert thinking_index < text_index
    end

    test "encode_message skips non-Anthropic reasoning details with warning" do
      import ExUnit.CaptureLog

      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      non_anthropic_detail = %ReqLLM.Message.ReasoningDetails{
        text: "OpenAI reasoning...",
        signature: nil,
        encrypted?: false,
        provider: :openai,
        format: "openai-reasoning-v1",
        index: 0,
        provider_data: %{}
      }

      assistant_message = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Response text."}],
        reasoning_details: [non_anthropic_detail],
        metadata: %{}
      }

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("Question?"),
          assistant_message
        ])

      log =
        capture_log(fn ->
          encoded = ReqLLM.Providers.Anthropic.Context.encode_request(context, model)
          messages = encoded[:messages]
          assistant_msg = Enum.find(messages, fn m -> m[:role] == "assistant" end)
          content_blocks = assistant_msg[:content]

          thinking_blocks =
            Enum.filter(content_blocks, fn b ->
              is_map(b) and b[:type] == "thinking"
            end)

          assert thinking_blocks == []
        end)

      assert log =~ "Skipping non-Anthropic reasoning detail"
      assert log =~ ":openai"
    end

    test "encode_message with reasoning_details and tool_calls preserves order" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      reasoning_detail = %ReqLLM.Message.ReasoningDetails{
        text: "Let me think about which tool to use...",
        signature: "sig123",
        encrypted?: false,
        provider: :anthropic,
        format: "anthropic-thinking-v1",
        index: 0,
        provider_data: %{"type" => "thinking"}
      }

      tool_call = %ReqLLM.ToolCall{
        id: "call_123",
        type: "function",
        function: %{name: "get_weather", arguments: ~s({"location":"NYC"})}
      }

      assistant_message = %ReqLLM.Message{
        role: :assistant,
        content: [
          %ReqLLM.Message.ContentPart{
            type: :thinking,
            text: "Let me think about which tool to use..."
          },
          %ReqLLM.Message.ContentPart{type: :text, text: "I'll check the weather."}
        ],
        tool_calls: [tool_call],
        reasoning_details: [reasoning_detail],
        metadata: %{}
      }

      context = %ReqLLM.Context{
        messages: [
          ReqLLM.Context.user("What's the weather in NYC?"),
          assistant_message
        ]
      }

      encoded = ReqLLM.Providers.Anthropic.Context.encode_request(context, model)
      messages = encoded[:messages]

      assistant_msg = Enum.find(messages, fn m -> m[:role] == "assistant" end)
      content_blocks = assistant_msg[:content]

      type_order = Enum.map(content_blocks, fn b -> b[:type] end)
      assert type_order == ["thinking", "text", "tool_use"]

      [thinking_block] = Enum.filter(content_blocks, &(&1[:type] == "thinking"))
      assert thinking_block[:signature] == "sig123"
    end

    test "preserves signed thinking content with tool calls without reasoning_details" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      tool_call = %ReqLLM.ToolCall{
        id: "call_456",
        type: "function",
        function: %{name: "get_weather", arguments: ~s({"location":"NYC"})}
      }

      assistant_message = %ReqLLM.Message{
        role: :assistant,
        content: [
          %ReqLLM.Message.ContentPart{
            type: :thinking,
            text: "I should check the weather.",
            metadata: %{signature: "sig456"}
          },
          %ReqLLM.Message.ContentPart{type: :text, text: "I'll check the weather."}
        ],
        tool_calls: [tool_call],
        reasoning_details: nil,
        metadata: %{}
      }

      context = %ReqLLM.Context{messages: [assistant_message]}
      encoded = ReqLLM.Providers.Anthropic.Context.encode_request(context, model)
      [assistant_msg] = encoded[:messages]

      assert Enum.map(assistant_msg[:content], & &1[:type]) == ["thinking", "text", "tool_use"]
      assert [thinking_block] = Enum.filter(assistant_msg[:content], &(&1[:type] == "thinking"))
      assert thinking_block[:signature] == "sig456"
      assert thinking_block[:thinking] == "I should check the weather."
    end

    test "preserves signed thinking when reasoning_details encode no Anthropic blocks" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      tool_call = %ReqLLM.ToolCall{
        id: "call_789",
        type: "function",
        function: %{name: "get_weather", arguments: ~s({"location":"NYC"})}
      }

      assistant_message = %ReqLLM.Message{
        role: :assistant,
        content: [
          %ReqLLM.Message.ContentPart{
            type: :thinking,
            text: "I should check the weather.",
            metadata: %{signature: "sig789"}
          },
          %ReqLLM.Message.ContentPart{type: :text, text: "I'll check the weather."}
        ],
        tool_calls: [tool_call],
        reasoning_details: [
          %ReqLLM.Message.ReasoningDetails{
            provider: :openai,
            index: 0,
            text: "openai reasoning"
          }
        ],
        metadata: %{}
      }

      context = %ReqLLM.Context{messages: [assistant_message]}
      encoded = ReqLLM.Providers.Anthropic.Context.encode_request(context, model)
      [assistant_msg] = encoded[:messages]

      assert Enum.map(assistant_msg[:content], & &1[:type]) == ["thinking", "text", "tool_use"]
      assert [thinking_block] = Enum.filter(assistant_msg[:content], &(&1[:type] == "thinking"))
      assert thinking_block[:signature] == "sig789"
    end

    test "preserves redacted thinking content with tool calls without reasoning_details" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      tool_call = %ReqLLM.ToolCall{
        id: "call_789",
        type: "function",
        function: %{name: "get_weather", arguments: ~s({"location":"NYC"})}
      }

      assistant_message = %ReqLLM.Message{
        role: :assistant,
        content: [
          %ReqLLM.Message.ContentPart{
            type: :thinking,
            text: "",
            metadata: %{"redacted" => true, "data" => "redacted-bytes"}
          },
          %ReqLLM.Message.ContentPart{type: :text, text: "I'll check the weather."}
        ],
        tool_calls: [tool_call],
        reasoning_details: [],
        metadata: %{}
      }

      context = %ReqLLM.Context{messages: [assistant_message]}
      encoded = ReqLLM.Providers.Anthropic.Context.encode_request(context, model)
      [assistant_msg] = encoded[:messages]

      assert Enum.map(assistant_msg[:content], & &1[:type]) == [
               "redacted_thinking",
               "text",
               "tool_use"
             ]

      assert hd(assistant_msg[:content]) == %{
               type: "redacted_thinking",
               data: "redacted-bytes"
             }
    end
  end
end

defmodule ReqLLM.CompactionTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Compaction
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart

  @compaction_item %{"id" => "cmp_1", "type" => "compaction", "encrypted_content" => "opaque"}

  @chat_model %LLMDB.Model{
    provider: :openai,
    id: "chat-test-model",
    capabilities: %{chat: true},
    extra: %{wire: %{protocol: "openai_chat"}}
  }

  defp compacted_message(provider \\ :openai) do
    %Message{role: :assistant, content: [ContentPart.provider_block(provider, @compaction_item)]}
  end

  describe "compact_context/3 validation" do
    test "requires messages or a previous_response_id" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               Compaction.compact_context("openai:gpt-5.4", nil, api_key: "k")

      assert message =~ "previous_response_id"
    end

    test "rejects messages combined with a previous_response_id" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               Compaction.compact_context("openai:gpt-5.4", "Hello",
                 api_key: "k",
                 previous_response_id: "resp_1"
               )

      assert message =~ "not both"

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Compaction.compact_context("openai:gpt-5.4", "Hello",
                 api_key: "k",
                 provider_options: [previous_response_id: "resp_1"]
               )
    end

    test "rejects non-keyword options" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Compaction.compact_context("openai:gpt-5.4", "Hello", %{api_key: "k"})
    end

    test "rejects providers without Responses API compaction" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               Compaction.compact_context("anthropic:claude-sonnet-4-5", "Hello", api_key: "k")

      assert message =~ ":compact"
    end

    test "rejects Chat Completions models" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               Compaction.compact_context(@chat_model, "Hello", api_key: "k")

      assert message =~ "Responses API model"
    end

    test "is exposed on the ReqLLM facade" do
      assert function_exported?(ReqLLM, :compact_context, 3)
      assert function_exported?(ReqLLM, :compact_context!, 3)

      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        ReqLLM.compact_context!(@chat_model, "Hello", api_key: "k")
      end
    end
  end

  describe "compacted_message/1" do
    test "keeps only compaction items and drops replayable leftovers" do
      message = %Message{
        role: :assistant,
        content: [
          ContentPart.text("Echoed answer"),
          ContentPart.provider_block(:openai, @compaction_item)
        ],
        tool_calls: [ReqLLM.ToolCall.new("call_1", "lookup", "{}")],
        reasoning_details: [
          %ReqLLM.Message.ReasoningDetails{
            text: "Plan",
            signature: nil,
            encrypted?: false,
            provider: :openai,
            format: "openai-responses-v1",
            index: 0,
            provider_data: %{}
          }
        ],
        metadata: %{compaction_response_id: "resp_c", phase: "final_answer", phase_items: []}
      }

      compacted = Compaction.compacted_message(message)

      assert [%ContentPart{type: :provider_block}] = compacted.content
      assert compacted.tool_calls == nil
      assert compacted.reasoning_details == nil
      assert compacted.metadata == %{compaction_response_id: "resp_c"}
    end
  end

  describe "compaction_part?/1 and compaction_message?/1" do
    test "recognise compaction provider blocks" do
      assert Compaction.compaction_part?(ContentPart.provider_block(:azure, @compaction_item))
      refute Compaction.compaction_part?(ContentPart.text("hello"))

      refute Compaction.compaction_part?(
               ContentPart.provider_block(:anthropic, %{"type" => "server_tool_use"})
             )

      assert Compaction.compaction_message?(compacted_message())
      refute Compaction.compaction_message?(Context.user("hello"))
    end
  end

  describe "trim/1" do
    test "keeps the messages from the latest compaction item onward" do
      context =
        Context.new([
          Context.user("old"),
          compacted_message(),
          Context.user("middle"),
          compacted_message(:azure),
          Context.user("new")
        ])

      assert %Context{messages: [compacted, user]} = Compaction.trim(context)
      assert Compaction.compaction_message?(compacted)
      assert compacted.content |> hd() |> Map.get(:metadata) |> Map.get(:provider) == :azure
      assert [%ContentPart{text: "new"}] = user.content
    end

    test "returns the context unchanged without compaction items" do
      context = Context.new([Context.user("a"), Context.assistant("b")])

      assert Compaction.trim(context) == context
    end
  end
end

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
    test "keeps retained content, tool calls, and reasoning for replay" do
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

      assert compacted == message
    end
  end

  for provider <- [:openai, :azure] do
    test "#{provider} compaction replays the complete returned window" do
      provider = unquote(provider)

      output = [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "Keep this instruction."}]
        },
        %{
          "id" => "msg_retained",
          "type" => "message",
          "role" => "assistant",
          "phase" => "commentary",
          "content" => [%{"type" => "output_text", "text" => "Retained answer"}]
        },
        %{
          "type" => "function_call",
          "call_id" => "call_1",
          "name" => "lookup",
          "arguments" => "{}"
        },
        %{"type" => "function_call_output", "call_id" => "call_1", "output" => "Found"},
        @compaction_item
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        if String.ends_with?(conn.request_path, "/compact") do
          Req.Test.json(conn, %{"id" => "cmp_response", "output" => output})
        else
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          request = Jason.decode!(body)
          assert Enum.drop(request["input"], -1) == output
          assert List.last(request["input"])["role"] == "user"
          refute Map.has_key?(request, "previous_response_id")

          Req.Test.json(conn, %{
            "id" => "resp_next",
            "output" => [
              %{
                "type" => "message",
                "role" => "assistant",
                "content" => [
                  %{"type" => "output_text", "text" => "Continued"}
                ]
              }
            ]
          })
        end
      end)

      opts = [api_key: "test-key", req_http_options: [plug: {Req.Test, __MODULE__}]]

      opts =
        opts ++
          unquote(
            if provider == :azure,
              do: [base_url: "https://fixture.openai.azure.com/openai/v1", deployment: "gpt-5.4"],
              else: []
          )

      assert {:ok, compacted} = ReqLLM.compact_context("#{provider}:gpt-5.4", "Old", opts)
      assert compacted.message.metadata.responses_replay == %{provider: provider, items: output}
      assert Compaction.trim(compacted.context) == compacted.context

      next = Context.append(compacted.context, Context.user("Continue"))
      assert {:ok, response} = ReqLLM.generate_text("#{provider}:gpt-5.4", next, opts)
      assert ReqLLM.Response.text(response) == "Continued"
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

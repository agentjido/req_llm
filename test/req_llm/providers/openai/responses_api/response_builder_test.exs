defmodule Provider.OpenAI.ResponsesAPI.ResponseBuilderTest do
  use ExUnit.Case, async: false

  import ReqLLM.Test.OpenAI.ResponsesAPIHelpers, only: [refusal_message_item: 2]

  alias ReqLLM.Providers.OpenAI.ResponsesAPI

  describe "ResponseBuilder - streaming reasoning_details extraction" do
    alias ReqLLM.Providers.OpenAI.ResponsesAPI.ResponseBuilder

    test "upgrades stop finish reason to tool_calls when tool chunks are present" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.tool_call("get_weather", %{"city" => "SF"}),
        ReqLLM.StreamChunk.text("Calling a tool")
      ]

      {:ok, response} =
        ResponseBuilder.build_response(
          chunks,
          %{finish_reason: :stop},
          context: context,
          model: model
        )

      assert response.finish_reason == :tool_calls
      assert [%ReqLLM.ToolCall{function: %{name: "get_weather"}}] = response.message.tool_calls
    end

    test "keeps a streamed refusal's content_filter finish reason when tool chunks are present" do
      {:ok, model} = ReqLLM.model("openai:gpt-5")
      context = %ReqLLM.Context{messages: []}

      refusal_item = refusal_message_item("msg_1", "I can't help with that.")

      function_item = %{
        "type" => "function_call",
        "call_id" => "call_1",
        "name" => "lookup",
        "arguments" => ~s({"q":"docs"})
      }

      events = [
        %{
          "type" => "response.refusal.delta",
          "output_index" => 0,
          "content_index" => 0,
          "delta" => "I can't help with that."
        },
        %{"type" => "response.output_item.done", "output_index" => 1, "item" => function_item},
        %{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_1",
            "status" => "completed",
            "output" => [refusal_item, function_item]
          }
        }
      ]

      {chunks, _state} =
        Enum.flat_map_reduce(events, nil, fn data, state ->
          ResponsesAPI.decode_stream_event(%{data: data}, model, state)
        end)

      {terminal, content_chunks} = List.pop_at(chunks, -1)

      assert %ReqLLM.StreamChunk{type: :meta, metadata: %{finish_reason: :content_filter}} =
               terminal

      {:ok, response} =
        ResponseBuilder.build_response(
          content_chunks,
          %{finish_reason: terminal.metadata.finish_reason},
          context: context,
          model: model
        )

      assert response.finish_reason == :content_filter
      assert [%ReqLLM.ToolCall{function: %{name: "lookup"}}] = response.message.tool_calls
    end

    test "preserves stop finish reason when only builtin tool chunks are present" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.tool_call("web_search_call", %{"query" => "docs"}, %{
          id: "ws_1",
          builtin?: true
        })
      ]

      {:ok, response} =
        ResponseBuilder.build_response(
          chunks,
          %{finish_reason: :stop},
          context: context,
          model: model
        )

      assert response.finish_reason == :stop
      assert [%ReqLLM.ToolCall{} = tool_call] = response.message.tool_calls
      assert ReqLLM.ToolCall.builtin?(tool_call)
    end

    test "upgrades string stop finish reason to tool_calls when tool chunks are present" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.tool_call("search", %{"query" => "docs"})
      ]

      {:ok, response} =
        ResponseBuilder.build_response(
          chunks,
          %{finish_reason: "stop"},
          context: context,
          model: model
        )

      assert response.finish_reason == :tool_calls
    end

    test "preserves non-stop finish reason when tool chunks are present" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.tool_call("search", %{"query" => "docs"})
      ]

      {:ok, response} =
        ResponseBuilder.build_response(
          chunks,
          %{finish_reason: :length},
          context: context,
          model: model
        )

      assert response.finish_reason == :length
    end

    test "extracts reasoning_details from thinking chunks" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      thinking_meta = %{
        provider: :openai,
        format: "openai-responses-v1",
        encrypted?: false,
        provider_data: %{"type" => "reasoning"}
      }

      chunks = [
        ReqLLM.StreamChunk.thinking("Step 1: Analyze the problem", thinking_meta),
        ReqLLM.StreamChunk.thinking("Step 2: Consider solutions", thinking_meta),
        ReqLLM.StreamChunk.text("The answer is 42.")
      ]

      metadata = %{finish_reason: :stop, response_id: "resp_123"}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.reasoning_details != nil
      assert length(response.message.reasoning_details) == 2

      [first, second] = response.message.reasoning_details
      assert %ReqLLM.Message.ReasoningDetails{} = first
      assert first.text == "Step 1: Analyze the problem"
      assert first.provider == :openai
      assert first.format == "openai-responses-v1"
      assert first.index == 0

      assert second.text == "Step 2: Consider solutions"
      assert second.index == 1
    end

    test "propagates response_id to message metadata" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.thinking("Thinking..."),
        ReqLLM.StreamChunk.text("Response")
      ]

      metadata = %{finish_reason: :stop, response_id: "resp_abc123"}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.metadata[:response_id] == "resp_abc123"
      assert length(response.message.reasoning_details) == 1
    end

    test "propagates phase replay metadata to message metadata" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.text("Inspecting logs. Cache race confirmed.")
      ]

      metadata = %{
        finish_reason: :stop,
        response_id: "resp_abc123",
        phase_items: [
          %{
            "phase" => "commentary",
            "content" => [%{"type" => "output_text", "text" => "Inspecting logs. "}]
          },
          %{
            "phase" => "final_answer",
            "content" => [%{"type" => "output_text", "text" => "Cache race confirmed."}]
          }
        ]
      }

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.metadata[:response_id] == "resp_abc123"

      assert response.message.metadata[:phase_items] == [
               %{
                 "phase" => "commentary",
                 "content" => [%{"type" => "output_text", "text" => "Inspecting logs. "}]
               },
               %{
                 "phase" => "final_answer",
                 "content" => [%{"type" => "output_text", "text" => "Cache race confirmed."}]
               }
             ]
    end

    test "attaches reasoning_details to context messages" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.thinking("Deep thought"),
        ReqLLM.StreamChunk.text("Final answer")
      ]

      metadata = %{finish_reason: :stop}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      [context_msg] = response.context.messages
      assert context_msg.reasoning_details != nil
      assert length(context_msg.reasoning_details) == 1
      assert hd(context_msg.reasoning_details).text == "Deep thought"
    end

    test "leaves message metadata unchanged when response_id is absent" do
      {:ok, model} = ReqLLM.model("openai:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.text("No response id")
      ]

      {:ok, response} =
        ResponseBuilder.build_response(
          chunks,
          %{finish_reason: :stop},
          context: context,
          model: model
        )

      assert response.message.metadata == %{}
    end
  end
end

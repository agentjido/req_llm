defmodule ReqLLM.Providers.Anthropic.StreamingTest do
  @moduledoc """
  Tests Anthropic streaming requests, event decoding, and response assembly.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Anthropic, async: true

  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.Anthropic

  describe "request preparation & pipeline wiring" do
    test "attach_stream adds beta header for web_fetch server tool" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Fetch example.com")])

      {:ok, finch_request} =
        Anthropic.attach_stream(
          model,
          context,
          [api_key: "anthropic-test-key", provider_options: [web_fetch: %{max_uses: 1}]],
          nil
        )

      headers = Map.new(finch_request.headers)
      assert headers["anthropic-beta"] == "tools-2024-05-16"
    end

    test "attach_stream adds files beta header for uploaded file references" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user([
            ContentPart.text("Summarize this document."),
            ContentPart.file_id("file_011CNha8iCJcU1wXNR6q4V8w")
          ])
        ])

      {:ok, finch_request} =
        Anthropic.attach_stream(model, context, [api_key: "anthropic-test-key"], nil)

      headers = Map.new(finch_request.headers)
      assert headers["anthropic-beta"] == "files-api-2025-04-14"
    end

    test "attach_stream defaults max_tokens from model output limit" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Write a detailed answer")])

      {:ok, finch_request} = Anthropic.attach_stream(model, context, [api_key: "test-key"], nil)

      body = Jason.decode!(finch_request.body)
      assert body["max_tokens"] == model.limits.output
    end

    test "attach_stream preserves explicit max_tokens" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Write a detailed answer")])

      {:ok, finch_request} =
        Anthropic.attach_stream(model, context, [api_key: "test-key", max_tokens: 123], nil)

      body = Jason.decode!(finch_request.body)
      assert body["max_tokens"] == 123
    end
  end

  describe "streaming response decoding" do
    test "a message_delta carries the provider's stop_reason on its terminal chunk" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      event = %{
        data: %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "pause_turn"},
          "usage" => %{"output_tokens" => 7}
        }
      }

      for chunks <- [
            Anthropic.decode_stream_event(event, model),
            event |> Anthropic.Response.decode_stream_event(model, nil) |> elem(0)
          ] do
        assert [%ReqLLM.StreamChunk{type: :meta, metadata: %{usage: _}}, terminal] = chunks

        assert terminal.metadata == %{
                 finish_reason: :incomplete,
                 terminal?: true,
                 provider_meta: %{"stop_reason" => "pause_turn"}
               }
      end
    end

    test "a streamed paused turn reports its stop_reason in the stream's provider_meta" do
      Process.flag(:trap_exit, true)
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      server =
        ReqLLM.Test.StreamServerHelpers.start_server(
          provider_mod: ReqLLM.Providers.Anthropic,
          model: model
        )

      _task = ReqLLM.Test.StreamServerHelpers.mock_http_task(server)

      events = [
        %{
          "type" => "message_start",
          "message" => %{
            "id" => "msg_1",
            "type" => "message",
            "role" => "assistant",
            "content" => [],
            "usage" => %{"input_tokens" => 5, "output_tokens" => 1}
          }
        },
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "pause_turn"},
          "usage" => %{"output_tokens" => 7}
        },
        %{"type" => "message_stop"}
      ]

      for event <- events do
        sse = "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
        ReqLLM.StreamServer.http_event(server, {:data, sse})
      end

      ReqLLM.StreamServer.http_event(server, :done)

      assert {:ok, metadata} = ReqLLM.StreamServer.await_metadata(server, 1_000)
      assert metadata.finish_reason == :incomplete
      assert metadata.provider_meta == %{"stop_reason" => "pause_turn"}

      ReqLLM.StreamServer.cancel(server)
    end

    test "decode_stream_event returns keepalive meta chunk for ping events" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      event = %{data: %{"type" => "ping"}}

      assert [%ReqLLM.StreamChunk{} = chunk] = Anthropic.decode_stream_event(event, model)
      assert chunk.type == :meta
      assert chunk.metadata[:keepalive?] == true
      assert chunk.metadata[:provider_event] == :ping
    end

    test "decode_stream_event/3 emits one reasoning detail for a streamed thinking block" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-20250514")

      events = [
        %{
          data: %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{"type" => "thinking", "thinking" => "", "signature" => ""}
          }
        },
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => "First part "}
          }
        },
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => "second part"}
          }
        },
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "signature_delta", "signature" => "sig_test_123"}
          }
        },
        %{data: %{"type" => "content_block_stop", "index" => 0}}
      ]

      {chunks, _state} =
        Enum.reduce(events, {[], Anthropic.init_stream_state(model)}, fn event, {acc, state} ->
          {event_chunks, next_state} = Anthropic.decode_stream_event(event, model, state)
          {acc ++ event_chunks, next_state}
        end)

      assert Enum.filter(chunks, &(&1.type == :thinking)) |> Enum.map(& &1.text) == [
               "First part ",
               "second part"
             ]

      reasoning_chunks =
        Enum.filter(chunks, fn
          %ReqLLM.StreamChunk{type: :meta, metadata: %{reasoning_details: [_detail]}} -> true
          _ -> false
        end)

      assert [%ReqLLM.StreamChunk{metadata: %{reasoning_details: [detail]}}] = reasoning_chunks
      assert detail.text == "First part second part"
      assert detail.signature == "sig_test_123"
      assert detail.index == 0
    end

    test "streamed thinking round-trips as a single Anthropic reasoning block" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-20250514")
      context = %ReqLLM.Context{messages: []}

      events = [
        %{
          data: %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{"type" => "thinking", "thinking" => "", "signature" => ""}
          }
        },
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => "First part "}
          }
        },
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => "second part"}
          }
        },
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "signature_delta", "signature" => "sig_test_123"}
          }
        },
        %{data: %{"type" => "content_block_stop", "index" => 0}},
        %{
          data: %{
            "type" => "content_block_start",
            "index" => 1,
            "content_block" => %{"type" => "text", "text" => "Answer: "}
          }
        },
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 1,
            "delta" => %{"type" => "text_delta", "text" => "42"}
          }
        }
      ]

      {chunks, _state} =
        Enum.reduce(events, {[], Anthropic.init_stream_state(model)}, fn event, {acc, state} ->
          {event_chunks, next_state} = Anthropic.decode_stream_event(event, model, state)
          {acc ++ event_chunks, next_state}
        end)

      {:ok, response} =
        ReqLLM.Providers.Anthropic.ResponseBuilder.build_response(
          chunks,
          %{finish_reason: :stop},
          context: context,
          model: model
        )

      assert [detail] = response.message.reasoning_details
      assert detail.text == "First part second part"
      assert detail.signature == "sig_test_123"

      encoded = ReqLLM.Providers.Anthropic.Context.encode_request(response.context, model)
      [assistant_message] = encoded[:messages]
      [thinking_block, text_block] = assistant_message[:content]

      assert thinking_block[:type] == "thinking"
      assert thinking_block[:thinking] == "First part second part"
      assert thinking_block[:signature] == "sig_test_123"
      assert text_block == %{type: "text", text: "Answer: 42"}
    end

    test "empty streamed tool arguments do not report lost args" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      context = %ReqLLM.Context{messages: []}

      events = [
        %{
          data: %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "toolu_empty_args",
              "name" => "test_tool",
              "input" => %{}
            }
          }
        },
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => ""}
          }
        },
        %{data: %{"type" => "content_block_stop", "index" => 0}}
      ]

      {chunks, _state} =
        Enum.reduce(events, {[], Anthropic.init_stream_state(model)}, fn event, {acc, state} ->
          {event_chunks, next_state} = Anthropic.decode_stream_event(event, model, state)
          {acc ++ event_chunks, next_state}
        end)

      {:ok, response} =
        ReqLLM.Providers.Anthropic.ResponseBuilder.build_response(
          chunks,
          %{finish_reason: :tool_calls},
          context: context,
          model: model
        )

      assert [tool_call] = response.message.tool_calls
      assert tool_call.id == "toolu_empty_args"
      assert tool_call.function.name == "test_tool"
      assert tool_call.function.arguments == "{}"
      refute get_in(tool_call.function, [:metadata, :error])
    end
  end

  describe "ResponseBuilder - streaming reasoning_details extraction" do
    alias ReqLLM.Providers.Anthropic.ResponseBuilder

    test "prefers finalized reasoning_details from meta chunks over delta chunks" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-20250514")
      context = %ReqLLM.Context{messages: []}

      reasoning_detail = %ReqLLM.Message.ReasoningDetails{
        text: "Let me analyze this step by stepFirst, consider the constraints",
        signature: "sig_abc123",
        encrypted?: true,
        provider: :anthropic,
        format: "anthropic-thinking-v1",
        index: 0,
        provider_data: %{"type" => "thinking"}
      }

      chunks = [
        ReqLLM.StreamChunk.thinking("Let me analyze this step by step"),
        ReqLLM.StreamChunk.thinking("First, consider the constraints"),
        ReqLLM.StreamChunk.meta(%{reasoning_details: [reasoning_detail]}),
        ReqLLM.StreamChunk.text("The answer is 42.")
      ]

      metadata = %{finish_reason: :stop}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.reasoning_details != nil
      assert [detail] = response.message.reasoning_details
      assert detail.text == reasoning_detail.text
      assert detail.signature == "sig_abc123"
      assert detail.provider == :anthropic
      assert detail.format == "anthropic-thinking-v1"
      assert detail.index == 0
    end

    test "returns nil reasoning_details when no thinking chunks" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-20250514")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.text("Just a simple response.")
      ]

      metadata = %{finish_reason: :stop}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.reasoning_details == nil
    end

    test "preserves signature from thinking chunk metadata" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-20250514")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        %ReqLLM.StreamChunk{
          type: :thinking,
          text: "Deep thought",
          metadata: %{signature: "sig_abc123"}
        },
        ReqLLM.StreamChunk.text("Response")
      ]

      metadata = %{finish_reason: :stop}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      [detail] = response.message.reasoning_details
      assert detail.signature == "sig_abc123"
    end

    test "attaches reasoning_details to context messages" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-20250514")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.thinking("Extended reasoning here"),
        ReqLLM.StreamChunk.text("Final answer")
      ]

      metadata = %{finish_reason: :stop}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      [context_msg] = response.context.messages
      assert context_msg.reasoning_details != nil
      assert length(context_msg.reasoning_details) == 1
      assert hd(context_msg.reasoning_details).text == "Extended reasoning here"
    end

    test "ensures non-empty content when tool calls present" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-20250514")
      context = %ReqLLM.Context{messages: []}

      chunks = [
        ReqLLM.StreamChunk.thinking("Planning tool use"),
        %ReqLLM.StreamChunk{
          type: :tool_call,
          name: "get_weather",
          arguments: %{"location" => "NYC"},
          metadata: %{id: "call_123", index: 0}
        }
      ]

      metadata = %{finish_reason: :tool_calls}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.content != []
      assert response.message.reasoning_details != nil
      assert length(response.message.reasoning_details) == 1
    end
  end
end

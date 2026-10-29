defmodule ReqLLM.Providers.Anthropic.ToolSearchTest do
  @moduledoc """
  Tests Anthropic deferred tool search and server tool block round trips.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Anthropic, async: true

  import ReqLLM.Test.AnthropicToolHelpers,
    only: [deferred_tool: 1, direct_tool: 1, encode_tools: 2]

  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.Anthropic

  describe "tool search tool" do
    test "tool_search leads the tools list, BM25 by default" do
      [search, direct, deferred] =
        encode_tools([direct_tool("direct"), deferred_tool("deferred")], tool_search: %{})

      assert search == %{
               "type" => "tool_search_tool_bm25_20251119",
               "name" => "tool_search_tool_bm25"
             }

      assert direct["name"] == "direct"
      refute Map.has_key?(direct, "defer_loading")
      assert deferred["defer_loading"] == true
    end

    test "the regex variant is selectable" do
      [search | _] = encode_tools([direct_tool("direct")], tool_search: %{variant: :regex})

      assert search["type"] == "tool_search_tool_regex_20251119"
      assert search["name"] == "tool_search_tool_regex"
    end
  end

  describe "tool search round-trip" do
    # The blocks the API returns when the model searched a deferred catalog. It
    # expects them back verbatim in the next assistant turn; with extended
    # thinking on, a turn that lost them fails with "thinking blocks in the
    # latest assistant message cannot be modified".
    @search_use %{
      "type" => "server_tool_use",
      "id" => "srvtoolu_01",
      "name" => "tool_search_tool_bm25",
      "input" => %{"query" => "glossary term"}
    }
    @search_result %{
      "type" => "tool_search_tool_result",
      "tool_use_id" => "srvtoolu_01",
      "content" => %{
        "type" => "tool_search_tool_search_result",
        "tool_references" => [%{"type" => "tool_reference", "tool_name" => "create_term"}]
      }
    }

    defp provider_blocks(%ReqLLM.Message{content: content}) do
      for %ContentPart{type: :provider_block, data: block} <- content, do: block
    end

    test "decode_response keeps search blocks as provider blocks, in order" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      {:ok, response} =
        ReqLLM.Providers.Anthropic.Response.decode_response(
          %{
            "id" => "msg_01",
            "role" => "assistant",
            "model" => "claude-sonnet-4-5-20250929",
            "content" => [
              %{"type" => "thinking", "thinking" => "Need the catalog.", "signature" => "sig_1"},
              @search_use,
              @search_result,
              %{"type" => "thinking", "thinking" => "Found it.", "signature" => "sig_2"},
              %{"type" => "text", "text" => "Creating it now."},
              %{"type" => "tool_use", "id" => "toolu_01", "name" => "create_term", "input" => %{}}
            ],
            "stop_reason" => "tool_use",
            "usage" => %{
              "input_tokens" => 10,
              "output_tokens" => 20,
              "server_tool_use" => %{"tool_search_requests" => 1}
            }
          },
          model
        )

      # The trailing thinking block rides along as a provider block: only the
      # ordered content keeps its position, and the API rejects a replay that
      # hoists it to the front.
      assert provider_blocks(response.message) == [
               @search_use,
               @search_result,
               %{"type" => "thinking", "thinking" => "Found it.", "signature" => "sig_2"}
             ]

      assert Enum.map(response.message.content, & &1.type) ==
               [:thinking, :provider_block, :provider_block, :provider_block, :text]

      # The leading thinking block keeps the reasoning-detail path.
      assert [%{text: "Need the catalog.", signature: "sig_1"}] =
               response.message.reasoning_details

      assert [%ReqLLM.ToolCall{function: %{name: "create_term"}}] = response.message.tool_calls
      assert response.usage[:tool_usage][:tool_search][:count] == 1
    end

    test "without server tool blocks a thinking block still decodes as a reasoning detail" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      {:ok, response} =
        ReqLLM.Providers.Anthropic.Response.decode_response(
          %{
            "id" => "msg_02",
            "role" => "assistant",
            "model" => "claude-sonnet-4-5-20250929",
            "content" => [
              %{"type" => "thinking", "thinking" => "First.", "signature" => "sig_1"},
              %{"type" => "text", "text" => "Answer."},
              %{"type" => "thinking", "thinking" => "Second.", "signature" => "sig_2"}
            ],
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          },
          model
        )

      assert provider_blocks(response.message) == []
      assert Enum.map(response.message.reasoning_details, & &1.text) == ["First.", "Second."]
    end

    test "completed server tool results stay with their calls in the next request" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      for {tool_name, result_type} <- [
            {"web_search", "web_search_tool_result"},
            {"web_fetch", "web_fetch_tool_result"}
          ] do
        use_block = %{
          "type" => "server_tool_use",
          "id" => "srvtoolu_02",
          "name" => tool_name,
          "input" => %{"query" => "example"}
        }

        result_block = %{
          "type" => result_type,
          "tool_use_id" => "srvtoolu_02",
          "content" => %{"type" => "result", "data" => "opaque"}
        }

        {:ok, response} =
          ReqLLM.Providers.Anthropic.Response.decode_response(
            %{
              "id" => "msg_03",
              "role" => "assistant",
              "model" => model.id,
              "content" => [use_block, result_block, %{"type" => "text", "text" => "Done."}],
              "stop_reason" => "end_turn"
            },
            model
          )

        encoded = ReqLLM.Providers.Anthropic.Context.encode_request(response.context, model)
        [assistant] = encoded[:messages]

        assert [^use_block, ^result_block, %{type: "text", text: "Done."}] =
                 assistant[:content]

        events = [
          %{"type" => "content_block_start", "index" => 0, "content_block" => use_block},
          %{"type" => "content_block_stop", "index" => 0},
          %{"type" => "content_block_start", "index" => 1, "content_block" => result_block}
        ]

        {chunks, _state} =
          Enum.reduce(events, {[], Anthropic.init_stream_state(model)}, fn data, {acc, state} ->
            {next, state} = Anthropic.decode_stream_event(%{data: data}, model, state)
            {acc ++ next, state}
          end)

        assert Enum.map(chunks, & &1.content_part.data) == [use_block, result_block]
      end
    end

    test "a paused response with only a server tool block remains in the context" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      {:ok, response} =
        ReqLLM.Providers.Anthropic.Response.decode_response(
          %{
            "id" => "msg_04",
            "role" => "assistant",
            "model" => model.id,
            "content" => [@search_use],
            "stop_reason" => "pause_turn"
          },
          model
        )

      assert response.message != nil
      assert response.finish_reason == :incomplete

      assert [assistant] =
               ReqLLM.Providers.Anthropic.Context.encode_request(response.context, model)[
                 :messages
               ]

      assert assistant[:content] == [@search_use]
    end

    test "redacted thinking blocks remain in their original position" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")
      redacted = %{"type" => "redacted_thinking", "data" => "opaque"}
      later_thinking = %{"type" => "thinking", "thinking" => "Later.", "signature" => "sig"}

      {:ok, response} =
        ReqLLM.Providers.Anthropic.Response.decode_response(
          %{
            "id" => "msg_05",
            "role" => "assistant",
            "model" => model.id,
            "content" => [redacted, later_thinking, %{"type" => "text", "text" => "Done."}],
            "stop_reason" => "end_turn"
          },
          model
        )

      encoded = ReqLLM.Providers.Anthropic.Context.encode_request(response.context, model)
      [assistant] = encoded[:messages]

      assert assistant[:content] == [redacted, later_thinking, %{type: "text", text: "Done."}]

      events = [
        %{"type" => "content_block_start", "index" => 0, "content_block" => redacted},
        %{
          "type" => "content_block_start",
          "index" => 1,
          "content_block" => later_thinking
        },
        %{"type" => "content_block_stop", "index" => 1}
      ]

      {chunks, _state} =
        Enum.reduce(events, {[], Anthropic.init_stream_state(model)}, fn data, {acc, state} ->
          {next, state} = Anthropic.decode_stream_event(%{data: data}, model, state)
          {acc ++ next, state}
        end)

      assert Enum.filter(chunks, &(&1.type == :content_part))
             |> Enum.map(& &1.content_part.data) == [redacted, later_thinking]
    end

    test "streamed search blocks arrive whole, with the input assembled from deltas" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      events = [
        %{
          data: %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => Map.put(@search_use, "input", %{})
          }
        },
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"query\": "}
          }
        },
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => "\"glossary term\"}"}
          }
        },
        %{data: %{"type" => "content_block_stop", "index" => 0}},
        %{
          data: %{
            "type" => "content_block_start",
            "index" => 1,
            "content_block" => @search_result
          }
        },
        %{data: %{"type" => "content_block_stop", "index" => 1}}
      ]

      {chunks, _state} =
        Enum.reduce(events, {[], Anthropic.init_stream_state(model)}, fn event, {acc, state} ->
          {event_chunks, next_state} = Anthropic.decode_stream_event(event, model, state)
          {acc ++ event_chunks, next_state}
        end)

      assert [
               %ReqLLM.StreamChunk{type: :content_part, content_part: use_part},
               %ReqLLM.StreamChunk{type: :content_part, content_part: result_part}
             ] = chunks

      assert use_part.data == @search_use
      assert use_part.metadata == %{provider: :anthropic, block_type: "server_tool_use"}
      assert result_part.data == @search_result
    end

    test "an unfinished streamed search block is flushed with the stream" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      event = %{
        data: %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => @search_use
        }
      }

      {[], state} =
        Anthropic.decode_stream_event(event, model, Anthropic.init_stream_state(model))

      {[chunk], _state} = ReqLLM.Providers.Anthropic.Response.flush_stream_state(model, state)

      assert chunk.content_part.data == @search_use
    end

    test "later thinking streams to callers and replays once without earlier thinking" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      events = [
        %{"type" => "content_block_start", "index" => 0, "content_block" => @search_use},
        %{"type" => "content_block_stop", "index" => 0},
        %{"type" => "content_block_start", "index" => 1, "content_block" => @search_result},
        %{"type" => "content_block_stop", "index" => 1},
        %{
          "type" => "content_block_start",
          "index" => 2,
          "content_block" => %{"type" => "thinking", "thinking" => "", "signature" => ""}
        },
        %{
          "type" => "content_block_delta",
          "index" => 2,
          "delta" => %{"type" => "thinking_delta", "thinking" => "Found it."}
        },
        %{
          "type" => "content_block_delta",
          "index" => 2,
          "delta" => %{"type" => "signature_delta", "signature" => "sig_2"}
        },
        %{"type" => "content_block_stop", "index" => 2}
      ]

      {chunks, _state} =
        Enum.reduce(events, {[], Anthropic.init_stream_state(model)}, fn data, {acc, state} ->
          {next, state} = Anthropic.decode_stream_event(%{data: data}, model, state)
          {acc ++ next, state}
        end)

      assert Enum.filter(chunks, &(&1.type == :thinking)) |> Enum.map(& &1.text) ==
               ["Found it."]

      {:ok, response} =
        ReqLLM.Providers.Anthropic.ResponseBuilder.build_response(
          chunks,
          %{finish_reason: :stop},
          context: %ReqLLM.Context{messages: [ReqLLM.Context.user("search")]},
          model: model
        )

      assert response.message.reasoning_details == nil
      encoded = ReqLLM.Providers.Anthropic.Context.encode_request(response.context, model)
      [_user, assistant] = encoded[:messages]

      assert assistant[:content] == [
               @search_use,
               @search_result,
               %{"type" => "thinking", "thinking" => "Found it.", "signature" => "sig_2"}
             ]
    end

    test "the replayed assistant turn carries the search blocks verbatim, in place" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      events = [
        %{
          data: %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{
              "type" => "thinking",
              "thinking" => "Need the catalog.",
              "signature" => ""
            }
          }
        },
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "signature_delta", "signature" => "sig_1"}
          }
        },
        %{data: %{"type" => "content_block_stop", "index" => 0}},
        %{data: %{"type" => "content_block_start", "index" => 1, "content_block" => @search_use}},
        %{data: %{"type" => "content_block_stop", "index" => 1}},
        %{
          data: %{
            "type" => "content_block_start",
            "index" => 2,
            "content_block" => @search_result
          }
        },
        %{data: %{"type" => "content_block_stop", "index" => 2}},
        %{
          data: %{
            "type" => "content_block_start",
            "index" => 3,
            "content_block" => %{"type" => "thinking", "thinking" => "", "signature" => ""}
          }
        },
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 3,
            "delta" => %{"type" => "thinking_delta", "thinking" => "Found it."}
          }
        },
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 3,
            "delta" => %{"type" => "signature_delta", "signature" => "sig_2"}
          }
        },
        %{data: %{"type" => "content_block_stop", "index" => 3}},
        %{
          data: %{
            "type" => "content_block_start",
            "index" => 4,
            "content_block" => %{"type" => "text", "text" => "Creating it now."}
          }
        },
        %{data: %{"type" => "content_block_stop", "index" => 4}},
        %{
          data: %{
            "type" => "content_block_start",
            "index" => 5,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "toolu_01",
              "name" => "create_term"
            }
          }
        },
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 5,
            "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"name\": \"hero\"}"}
          }
        },
        %{data: %{"type" => "content_block_stop", "index" => 5}}
      ]

      {chunks, _state} =
        Enum.reduce(events, {[], Anthropic.init_stream_state(model)}, fn event, {acc, state} ->
          {event_chunks, next_state} = Anthropic.decode_stream_event(event, model, state)
          {acc ++ event_chunks, next_state}
        end)

      assert Enum.filter(chunks, &(&1.type == :thinking)) |> Enum.map(& &1.text) == [
               "Need the catalog.",
               "Found it."
             ]

      {:ok, response} =
        ReqLLM.Providers.Anthropic.ResponseBuilder.build_response(
          chunks,
          %{finish_reason: :tool_calls},
          context: %ReqLLM.Context{messages: [ReqLLM.Context.user("make a term")]},
          model: model
        )

      encoded = ReqLLM.Providers.Anthropic.Context.encode_request(response.context, model)
      [_user, assistant] = encoded[:messages]
      [thinking, search_use, search_result, thinking_after, text, tool_use] = assistant[:content]

      assert thinking[:type] == "thinking" and thinking[:signature] == "sig_1"
      assert search_use == @search_use
      assert search_result == @search_result

      assert thinking_after == %{
               "type" => "thinking",
               "thinking" => "Found it.",
               "signature" => "sig_2"
             }

      assert text == %{type: "text", text: "Creating it now."}
      assert tool_use[:type] == "tool_use" and tool_use[:name] == "create_term"
    end

    test "a block another provider owns is not replayed" do
      {:ok, model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      context = %ReqLLM.Context{
        messages: [
          ReqLLM.Context.user("hi"),
          %ReqLLM.Message{
            role: :assistant,
            content: [
              ContentPart.provider_block(:openai, %{"type" => "web_search_call", "id" => "ws_1"}),
              ContentPart.text("Found it.")
            ]
          }
        ]
      }

      encoded = ReqLLM.Providers.Anthropic.Context.encode_request(context, model)
      [_user, assistant] = encoded[:messages]

      assert assistant[:content] == "Found it."
    end
  end
end

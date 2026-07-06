defmodule ReqLLM.Provider.ChunkAccumulatorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ReqLLM.{Message, StreamChunk, ToolCall}
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Provider.ChunkAccumulator

  describe "push/2 - text" do
    test "accumulates text content as iodata" do
      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{type: :content, text: "Hello, "})
        |> ChunkAccumulator.push(%StreamChunk{type: :content, text: "world!"})

      assert ChunkAccumulator.finalize_text(acc) == "Hello, world!"
    end

    test "skips empty text chunks" do
      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{type: :content, text: ""})

      assert ChunkAccumulator.finalize_text(acc) == ""
    end
  end

  describe "push/2 - thinking" do
    test "accumulates thinking content separately from text" do
      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{type: :content, text: "Answer."})
        |> ChunkAccumulator.push(%StreamChunk{type: :thinking, text: "Reasoning..."})

      assert ChunkAccumulator.finalize_text(acc) == "Answer."
      assert ChunkAccumulator.finalize_thinking(acc) == "Reasoning..."
    end
  end

  describe "push/2 - tool calls" do
    test "captures tool call with provider-supplied id" do
      acc =
        ChunkAccumulator.push(
          ChunkAccumulator.new(),
          %StreamChunk{
            type: :tool_call,
            name: "get_weather",
            arguments: %{},
            metadata: %{id: "call_abc", index: 0}
          }
        )

      assert [%{id: "call_abc", name: "get_weather", index: 0}] = acc.tool_calls
    end

    test "generates UUIDv7 id when chunk metadata lacks one" do
      acc =
        ChunkAccumulator.push(
          ChunkAccumulator.new(),
          %StreamChunk{type: :tool_call, name: "f", arguments: %{}, metadata: %{}}
        )

      [%{id: id}] = acc.tool_calls
      # UUIDv7 ids are 36 chars after the "call_" prefix
      assert String.starts_with?(id, "call_")
      assert byte_size(id) == 5 + 36
    end

    test "skips tool call chunks with no name" do
      acc =
        ChunkAccumulator.push(
          ChunkAccumulator.new(),
          %StreamChunk{type: :tool_call, name: nil, arguments: %{}, metadata: %{}}
        )

      assert acc.tool_calls == []
    end

    test "propagates builtin? flag from chunk metadata" do
      acc =
        ChunkAccumulator.push(
          ChunkAccumulator.new(),
          %StreamChunk{
            type: :tool_call,
            name: "web_search_call",
            arguments: %{},
            metadata: %{id: "ws_1", index: 0, builtin?: true}
          }
        )

      assert [%{builtin?: true}] = acc.tool_calls
    end
  end

  describe "push/2 - meta chunks" do
    test "merges argument fragments by index as iodata" do
      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{tool_call_args: %{index: 0, fragment: "{\"location"}}
        })
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{tool_call_args: %{index: 0, fragment: "\":\"SF\""}}
        })
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{tool_call_args: %{index: 0, fragment: "}"}}
        })

      assert IO.iodata_to_binary(acc.arg_fragments[0]) == "{\"location\":\"SF\"}"
    end

    test "tracks empty argument fragments by index" do
      acc =
        ChunkAccumulator.push(
          ChunkAccumulator.new(),
          %StreamChunk{
            type: :meta,
            metadata: %{tool_call_args: %{index: 0, fragment: ""}}
          }
        )

      assert Map.has_key?(acc.arg_fragments, 0)
      assert IO.iodata_to_binary(acc.arg_fragments[0]) == ""
    end

    test "collects reasoning_details across meta chunks in arrival order" do
      details_a = %{provider: :openai, text: "first"}
      details_b = %{provider: :openai, text: "second"}

      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{reasoning_details: [details_a]}
        })
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{reasoning_details: [details_b]}
        })

      assert ChunkAccumulator.finalize_reasoning_details(acc) == [details_a, details_b]
    end

    test "collects logprobs across meta chunks in arrival order" do
      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{logprobs: [%{token: "a"}, %{token: "b"}]}
        })

      assert ChunkAccumulator.finalize_logprobs(acc) == [%{token: "a"}, %{token: "b"}]
    end
  end

  describe "finalize_tool_calls_for_response/1" do
    test "reconstructs args when the first chunk carries the opening brace (llama.cpp/vLLM)" do
      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{
          type: :tool_call,
          name: "get_weather",
          arguments: %{},
          metadata: %{id: "call_1", index: 0, raw_arguments: "{", invalid_arguments: true}
        })
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{tool_call_args: %{index: 0, fragment: "\"city\":\"NYC\""}}
        })
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{tool_call_args: %{index: 0, fragment: "}"}}
        })

      assert [
               %{id: "call_1", name: "get_weather", arguments: %{"city" => "NYC"}}
             ] = ChunkAccumulator.finalize_tool_calls_for_response(acc)
    end

    test "decodes argument fragments and drops :index" do
      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{
          type: :tool_call,
          name: "get_weather",
          arguments: %{},
          metadata: %{id: "call_1", index: 0}
        })
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{tool_call_args: %{index: 0, fragment: ~s({"city":"NYC"})}}
        })

      assert [
               %{id: "call_1", name: "get_weather", arguments: %{"city" => "NYC"}}
             ] = ChunkAccumulator.finalize_tool_calls_for_response(acc)
    end

    test "falls back to raw arguments when fragments fail to decode" do
      attach_args_lost_handler("call_invalid_json")

      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{
          type: :tool_call,
          name: "get_weather",
          arguments: %{"raw" => "args"},
          metadata: %{id: "call_invalid_json", index: 0}
        })
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{tool_call_args: %{index: 0, fragment: "not-json"}}
        })

      assert [
               %{
                 arguments: %{"raw" => "args"},
                 metadata: %{error: {:args_lost, :json_decode_error}}
               }
             ] =
               ChunkAccumulator.finalize_tool_calls_for_response(acc)

      assert_receive {:args_lost, "call_invalid_json", %{count: 1}, %{reason: :json_decode_error}}
    end

    test "does not log raw argument fragment content when JSON decode fails" do
      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{
          type: :tool_call,
          name: "get_secret",
          arguments: %{},
          metadata: %{id: "call_secret", index: 0}
        })
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{tool_call_args: %{index: 0, fragment: ~s({"token":"secret-value")}}
        })

      log =
        capture_log(fn ->
          ChunkAccumulator.finalize_tool_calls_for_response(acc)
        end)

      assert log =~ "reason=json_decode_error"
      assert log =~ "tool_call_id=call_secret"
      assert log =~ "json_bytes="
      refute log =~ "secret-value"
    end

    test "does not mark direct arguments as missing fragments" do
      attach_args_lost_handler("call_direct_args")

      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{
          type: :tool_call,
          name: "get_weather",
          arguments: %{"city" => "NYC"},
          metadata: %{id: "call_direct_args", index: 0}
        })

      assert [%{arguments: %{"city" => "NYC"}} = tool_call] =
               ChunkAccumulator.finalize_tool_calls_for_response(acc)

      refute Map.has_key?(tool_call, :metadata)
      refute_receive {:args_lost, "call_direct_args", _, _}
    end

    test "preserves non-control tool metadata" do
      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{
          type: :tool_call,
          name: "search",
          arguments: %{"query" => "docs"},
          metadata: %{
            id: "call_meta",
            index: 0,
            builtin?: true,
            done_at_unix_nano: 123,
            thought_signature: "sig_123",
            raw_arguments: ~s({"query":"docs"})
          }
        })

      assert [
               %{
                 builtin?: true,
                 metadata: %{
                   thought_signature: "sig_123",
                   raw_arguments: ~s({"query":"docs"})
                 }
               } = tool_call
             ] = ChunkAccumulator.finalize_tool_calls_for_response(acc)

      refute Map.has_key?(tool_call.metadata, :id)
      refute Map.has_key?(tool_call.metadata, :index)
      refute Map.has_key?(tool_call.metadata, :builtin?)
      refute Map.has_key?(tool_call.metadata, :done_at_unix_nano)
    end

    test "marks missing expected argument fragments" do
      attach_args_lost_handler("call_missing_fragments")

      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{
          type: :tool_call,
          name: "get_weather",
          arguments: %{},
          metadata: %{id: "call_missing_fragments", index: 0, start: true}
        })

      assert [%{metadata: %{error: {:args_lost, :missing_fragments}}}] =
               ChunkAccumulator.finalize_tool_calls_for_response(acc)

      assert_receive {:args_lost, "call_missing_fragments", %{count: 1},
                      %{reason: :missing_fragments}}
    end

    test "does not mark empty expected argument fragments as missing" do
      attach_args_lost_handler("call_empty_fragments")

      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{
          type: :tool_call,
          name: "test_tool",
          arguments: %{},
          metadata: %{id: "call_empty_fragments", index: 0, start: true}
        })
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{tool_call_args: %{index: 0, fragment: ""}}
        })

      assert [%{arguments: %{}} = tool_call] =
               ChunkAccumulator.finalize_tool_calls_for_response(acc)

      refute Map.has_key?(tool_call, :metadata)
      refute_receive {:args_lost, "call_empty_fragments", _, _}
    end

    test "returns [] for empty accumulator" do
      assert ChunkAccumulator.finalize_tool_calls_for_response(ChunkAccumulator.new()) == []
    end
  end

  describe "finalize_message/1" do
    test "returns nil for empty accumulator" do
      refute ChunkAccumulator.finalize_message(ChunkAccumulator.new())
    end

    test "builds an assistant message with text content" do
      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{type: :content, text: "Hi!"})

      assert %Message{
               role: :assistant,
               content: [%ContentPart{type: :text, text: "Hi!"}],
               tool_calls: nil,
               reasoning_details: nil
             } = ChunkAccumulator.finalize_message(acc)
    end

    test "builds assistant message with tool calls as ToolCall structs" do
      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{
          type: :tool_call,
          name: "get_weather",
          arguments: %{},
          metadata: %{id: "call_1", index: 0}
        })
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{tool_call_args: %{index: 0, fragment: ~s({"city":"SF"})}}
        })

      assert %Message{role: :assistant, content: [], tool_calls: [tool_call]} =
               ChunkAccumulator.finalize_message(acc)

      assert %ToolCall{id: "call_1", function: %{name: "get_weather"}} = tool_call
      refute ToolCall.builtin?(tool_call)
    end

    test "reconstructs tool call args from raw leading argument fragments" do
      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{
          type: :tool_call,
          name: "get_weather",
          arguments: %{},
          metadata: %{id: "call_1", index: 0, raw_arguments: "{", invalid_arguments: true}
        })
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{tool_call_args: %{index: 0, fragment: "\"city\":\"NYC\""}}
        })
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{tool_call_args: %{index: 0, fragment: "}"}}
        })

      assert %Message{tool_calls: [tool_call]} = ChunkAccumulator.finalize_message(acc)
      assert %ToolCall{function: %{arguments: arguments}} = tool_call
      assert Jason.decode!(arguments) == %{"city" => "NYC"}
    end

    test "preserves builtin flag on emitted ToolCall struct" do
      acc =
        ChunkAccumulator.push(
          ChunkAccumulator.new(),
          %StreamChunk{
            type: :tool_call,
            name: "web_search_call",
            arguments: %{"query" => "elixir"},
            metadata: %{id: "ws_1", index: 0, builtin?: true}
          }
        )

      assert %Message{tool_calls: [tool_call]} = ChunkAccumulator.finalize_message(acc)
      assert ToolCall.builtin?(tool_call)
    end

    test "preserves non-control metadata on emitted ToolCall struct" do
      acc =
        ChunkAccumulator.push(
          ChunkAccumulator.new(),
          %StreamChunk{
            type: :tool_call,
            name: "search",
            arguments: %{"query" => "docs"},
            metadata: %{
              id: "call_meta",
              index: 0,
              thought_signature: "sig_123",
              done_at_unix_nano: 123
            }
          }
        )

      assert %Message{tool_calls: [tool_call]} = ChunkAccumulator.finalize_message(acc)
      assert ToolCall.metadata(tool_call) == %{thought_signature: "sig_123"}
    end
  end

  describe "reduce/2" do
    test "is equivalent to repeated push/2 calls" do
      chunks = [
        %StreamChunk{type: :content, text: "Hello "},
        %StreamChunk{type: :content, text: "world"},
        %StreamChunk{
          type: :tool_call,
          name: "f",
          arguments: %{},
          metadata: %{id: "c1", index: 0}
        }
      ]

      via_reduce = ChunkAccumulator.reduce(ChunkAccumulator.new(), chunks)
      via_push = Enum.reduce(chunks, ChunkAccumulator.new(), &ChunkAccumulator.push(&2, &1))

      assert via_reduce.text_content == via_push.text_content
      assert via_reduce.tool_calls == via_push.tool_calls
    end
  end

  describe "push/2 - finish_reason from meta" do
    test "captures finish_reason from a single meta chunk" do
      acc =
        ChunkAccumulator.push(
          ChunkAccumulator.new(),
          %StreamChunk{type: :meta, metadata: %{finish_reason: "stop"}}
        )

      assert ChunkAccumulator.finalize_finish_reason(acc) == "stop"
    end

    test "latest finish_reason wins across multiple meta chunks" do
      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{type: :meta, metadata: %{finish_reason: "stop"}})
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{finish_reason: "tool_calls"}
        })

      assert ChunkAccumulator.finalize_finish_reason(acc) == "tool_calls"
    end

    test "nil finish_reason in meta does not overwrite an earlier value" do
      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{type: :meta, metadata: %{finish_reason: "stop"}})
        |> ChunkAccumulator.push(%StreamChunk{type: :meta, metadata: %{finish_reason: nil}})

      assert ChunkAccumulator.finalize_finish_reason(acc) == "stop"
    end

    test "returns nil when no meta chunk surfaced a finish_reason" do
      acc =
        ChunkAccumulator.push(
          ChunkAccumulator.new(),
          %StreamChunk{type: :content, text: "hi"}
        )

      assert ChunkAccumulator.finalize_finish_reason(acc) == nil
    end
  end

  describe "push/2 - usage from meta" do
    test "captures usage from a single meta chunk and recomputes totals" do
      acc =
        ChunkAccumulator.push(
          ChunkAccumulator.new(),
          %StreamChunk{
            type: :meta,
            metadata: %{usage: %{input_tokens: 10, output_tokens: 20}}
          }
        )

      usage = ChunkAccumulator.finalize_usage(acc)
      assert usage.input_tokens == 10
      assert usage.output_tokens == 20
      assert usage.total_tokens == 30
    end

    test "merges cumulative usage across meta chunks (max wins per field)" do
      acc =
        ChunkAccumulator.new()
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{usage: %{input_tokens: 5, output_tokens: 5}}
        })
        |> ChunkAccumulator.push(%StreamChunk{
          type: :meta,
          metadata: %{usage: %{input_tokens: 10, output_tokens: 20}}
        })

      usage = ChunkAccumulator.finalize_usage(acc)
      assert usage.input_tokens == 10
      assert usage.output_tokens == 20
      assert usage.total_tokens == 30
    end

    test "returns nil when no meta chunk surfaced usage" do
      acc =
        ChunkAccumulator.push(ChunkAccumulator.new(), %StreamChunk{type: :content, text: "hi"})

      assert ChunkAccumulator.finalize_usage(acc) == nil
    end
  end

  describe "order preservation under O(1) prepend" do
    test "finalize_tool_calls_for_response yields tool calls in arrival order" do
      chunks =
        for i <- 0..49 do
          %StreamChunk{
            type: :tool_call,
            name: "f_#{i}",
            arguments: %{},
            metadata: %{id: "call_#{i}", index: i}
          }
        end

      result =
        chunks
        |> Enum.reduce(ChunkAccumulator.new(), &ChunkAccumulator.push(&2, &1))
        |> ChunkAccumulator.finalize_tool_calls_for_response()

      assert length(result) == 50
      assert Enum.map(result, & &1.id) == Enum.map(0..49, &"call_#{&1}")
    end

    test "finalize_message returns tool calls in arrival order" do
      chunks =
        for i <- 0..9 do
          %StreamChunk{
            type: :tool_call,
            name: "f_#{i}",
            arguments: %{},
            metadata: %{id: "call_#{i}", index: i}
          }
        end

      acc = Enum.reduce(chunks, ChunkAccumulator.new(), &ChunkAccumulator.push(&2, &1))
      message = ChunkAccumulator.finalize_message(acc)

      assert Enum.map(message.tool_calls, & &1.id) == Enum.map(0..9, &"call_#{&1}")
    end

    test "reasoning_details across many meta chunks stay ordered" do
      acc =
        Enum.reduce(0..19, ChunkAccumulator.new(), fn i, acc ->
          ChunkAccumulator.push(acc, %StreamChunk{
            type: :meta,
            metadata: %{reasoning_details: [%{idx: i}]}
          })
        end)

      assert ChunkAccumulator.finalize_reasoning_details(acc) ==
               Enum.map(0..19, &%{idx: &1})
    end

    test "logprobs from a single meta chunk stay ordered" do
      tokens = Enum.map(0..9, &%{idx: &1})

      acc =
        ChunkAccumulator.push(
          ChunkAccumulator.new(),
          %StreamChunk{type: :meta, metadata: %{logprobs: tokens}}
        )

      assert ChunkAccumulator.finalize_logprobs(acc) == tokens
    end
  end

  defp attach_args_lost_handler(call_id) do
    test_pid = self()
    handler_id = {__MODULE__, test_pid, call_id}

    :ok =
      :telemetry.attach(
        handler_id,
        [:req_llm, :tool_call_args_lost],
        fn _event, measurements, metadata, {pid, expected_call_id} ->
          if metadata.tool_call_id == expected_call_id do
            send(pid, {:args_lost, expected_call_id, measurements, metadata})
          end
        end,
        {test_pid, call_id}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end

defmodule ReqLLM.StreamEventProjectionTest do
  use ExUnit.Case, async: true

  @moduletag contract: :public_api

  alias ReqLLM.Context
  alias ReqLLM.Provider.Defaults
  alias ReqLLM.Providers.Anthropic
  alias ReqLLM.Response.OutputItem
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamEvent
  alias ReqLLM.StreamResponse
  alias ReqLLM.StreamResponse.MetadataHandle

  describe "StreamEvent" do
    test "exposes a validated additive event contract" do
      assert %StreamEvent{type: :text_delta, data: "hello", metadata: %{sequence: 1}} =
               StreamEvent.new(:text_delta, "hello", %{sequence: 1})

      assert :start in StreamEvent.types()
      assert :provider_event in StreamEvent.types()
      assert StreamEvent.output?(StreamEvent.new(:source, %{}))
      refute StreamEvent.output?(StreamEvent.new(:usage, %{}))
      assert StreamEvent.terminal?(StreamEvent.new(:finish, %{finish_reason: :stop}))
      refute StreamEvent.terminal?(StreamEvent.new(:text_delta, "hello"))
      assert StreamEvent.schema()
    end
  end

  describe "events/1" do
    test "projects ordered text, reasoning, tool, source, usage, and lifecycle events" do
      source = %{
        "uri" => "https://example.com/guide?api_key=secret-value",
        "title" => "Guide"
      }

      provider_meta = %{"google" => %{"sources" => [source]}}
      usage = %{input_tokens: 4, output_tokens: 3, total_tokens: 7}

      chunks = [
        StreamChunk.text("Hello", %{sequence: 1}),
        StreamChunk.thinking("Consider", %{signature: "reasoning-secret"}),
        StreamChunk.tool_call("search", %{}, %{
          id: "call_1",
          index: 0,
          expects_arg_fragments: true
        }),
        StreamChunk.meta(%{
          tool_call_args: %{index: 0, fragment: ~s({"query":"elixir"})}
        }),
        StreamChunk.meta(%{
          provider_meta: provider_meta,
          usage: usage,
          finish_reason: :stop,
          terminal?: true
        })
      ]

      response =
        stream_response(chunks, %{
          provider_meta: provider_meta,
          usage: usage,
          finish_reason: :stop,
          response_id: "resp_123"
        })

      events = Enum.to_list(StreamResponse.events(response))

      assert Enum.map(events, & &1.type) == [
               :start,
               :text_delta,
               :reasoning_delta,
               :tool_call_start,
               :tool_call_delta,
               :source,
               :tool_call,
               :usage,
               :finish
             ]

      assert %StreamEvent{data: %{model: %{id: "test-model", provider: :test}}} = hd(events)
      assert %StreamEvent{type: :text_delta, data: "Hello", metadata: %{sequence: 1}} in events

      assert %StreamEvent{
               type: :reasoning_delta,
               data: "Consider",
               metadata: %{signature: "[REDACTED]"}
             } in events

      assert %StreamEvent{
               type: :tool_call,
               data: %{id: "call_1", name: "search", arguments: %{"query" => "elixir"}}
             } in events

      assert %StreamEvent{type: :source, data: %OutputItem{type: :source} = source_item} =
               Enum.find(events, &(&1.type == :source))

      source_json = inspect(source_item.data)
      refute source_json =~ "secret-value"
      assert %StreamEvent{type: :usage, data: ^usage} = Enum.find(events, &(&1.type == :usage))

      assert %StreamEvent{
               type: :finish,
               data: %{finish_reason: :stop},
               metadata: %{response_id: "resp_123"}
             } = List.last(events)

      assert StreamResponse.usage(response) == usage
      assert StreamResponse.finish_reason(response) == :stop
    end

    test "normalizes current OpenAI and Anthropic decoder output without consumer branching" do
      openai_model = %LLMDB.Model{provider: :openai, id: "gpt-test"}
      anthropic_model = %LLMDB.Model{provider: :anthropic, id: "claude-test"}

      openai_chunks =
        [
          %{data: %{"choices" => [%{"delta" => %{"content" => "Hello"}}]}},
          %{data: %{"choices" => [%{"delta" => %{"reasoning_content" => "Think"}}]}},
          %{
            data: %{
              "choices" => [
                %{
                  "delta" => %{
                    "tool_calls" => [
                      %{
                        "id" => "call_1",
                        "type" => "function",
                        "index" => 0,
                        "function" => %{"name" => "lookup"}
                      }
                    ]
                  }
                }
              ]
            }
          },
          %{
            data: %{
              "choices" => [
                %{
                  "delta" => %{
                    "tool_calls" => [
                      %{"index" => 0, "function" => %{"arguments" => ~s({"q":"elixir"})}}
                    ]
                  }
                }
              ]
            }
          },
          %{
            data: %{
              "choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}],
              "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 3, "total_tokens" => 7}
            }
          }
        ]
        |> Enum.flat_map(&Defaults.default_decode_stream_event(&1, openai_model))

      anthropic_chunks =
        [
          %{
            data: %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => "Hello"}
            }
          },
          %{
            data: %{
              "type" => "content_block_delta",
              "index" => 1,
              "delta" => %{"type" => "thinking_delta", "thinking" => "Think"}
            }
          },
          %{
            data: %{
              "type" => "content_block_start",
              "index" => 0,
              "content_block" => %{"type" => "tool_use", "id" => "call_1", "name" => "lookup"}
            }
          },
          %{
            data: %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"q":"elixir"})}
            }
          },
          %{
            data: %{
              "type" => "message_delta",
              "delta" => %{"stop_reason" => "tool_use"},
              "usage" => %{"input_tokens" => 4, "output_tokens" => 3}
            }
          }
        ]
        |> Enum.flat_map(&Anthropic.decode_stream_event(&1, anthropic_model))

      openai_events =
        stream_response(openai_chunks, %{finish_reason: :tool_calls})
        |> StreamResponse.events()
        |> Enum.to_list()

      anthropic_events =
        stream_response(anthropic_chunks, %{finish_reason: :tool_calls})
        |> StreamResponse.events()
        |> Enum.to_list()

      expected_types = [
        :start,
        :text_delta,
        :reasoning_delta,
        :tool_call_start,
        :tool_call_delta,
        :tool_call,
        :usage,
        :finish
      ]

      assert Enum.map(openai_events, & &1.type) == expected_types
      assert Enum.map(anthropic_events, & &1.type) == expected_types

      assert Enum.find(openai_events, &(&1.type == :tool_call)).data.arguments == %{
               "q" => "elixir"
             }

      assert Enum.find(anthropic_events, &(&1.type == :tool_call)).data.arguments == %{
               "q" => "elixir"
             }
    end

    test "emits one terminal cancellation event" do
      response = stream_response([], %{finish_reason: :cancelled})

      assert [
               %StreamEvent{type: :start},
               %StreamEvent{type: :cancelled, data: %{finish_reason: :cancelled}}
             ] = Enum.to_list(StreamResponse.events(response))
    end

    test "emits one terminal error from collected metadata" do
      error = ReqLLM.Error.API.Request.exception(reason: "provider unavailable", status: 503)
      response = stream_response([StreamChunk.text("partial")], %{error: error})

      assert [
               %StreamEvent{type: :start},
               %StreamEvent{type: :text_delta, data: "partial"},
               %StreamEvent{type: :error, data: ^error}
             ] = Enum.to_list(StreamResponse.events(response))
    end

    test "uses terminal error and finish signals retained by chunks" do
      error = ReqLLM.Error.API.Stream.exception(reason: "provider failed", cause: :provider)

      error_response =
        stream_response(
          [StreamChunk.meta(%{error: error, finish_reason: :error, terminal?: true})],
          %{}
        )

      assert [%StreamEvent{type: :start}, %StreamEvent{type: :error, data: ^error}] =
               Enum.to_list(StreamResponse.events(error_response))

      finish_response =
        stream_response([StreamChunk.meta(%{"finish_reason" => "length"})], %{})

      assert [
               %StreamEvent{type: :start},
               %StreamEvent{type: :finish, data: %{finish_reason: :length}}
             ] = Enum.to_list(StreamResponse.events(finish_response))
    end

    test "turns a fatal stream exception into a terminal error event" do
      test_pid = self()
      error = ReqLLM.Error.API.Stream.exception(reason: "transport closed", cause: :closed)

      stream =
        Stream.resource(
          fn -> 0 end,
          fn
            0 -> {[StreamChunk.text("partial")], 1}
            1 -> raise error
          end,
          fn _state -> send(test_pid, :upstream_closed) end
        )

      response = stream_response(stream, %{finish_reason: :error})
      events = Enum.to_list(StreamResponse.events(response))

      assert Enum.map(events, & &1.type) == [:start, :text_delta, :error]
      assert %StreamEvent{type: :error, data: ^error} = List.last(events)
      assert_receive :upstream_closed
    end

    test "halts the one underlying stream when enumeration stops early" do
      test_pid = self()

      stream =
        Stream.resource(
          fn -> 0 end,
          fn index -> {[StreamChunk.text(Integer.to_string(index))], index + 1} end,
          fn _state -> send(test_pid, :upstream_halted) end
        )

      response = stream_response(stream, %{finish_reason: :cancelled})

      assert [
               %StreamEvent{type: :start},
               %StreamEvent{type: :text_delta, data: "0"}
             ] = response |> StreamResponse.events() |> Stream.take(2) |> Enum.to_list()

      assert_receive :upstream_halted
    end

    test "pulls each underlying chunk once and closes it after full consumption" do
      test_pid = self()
      chunks = [StreamChunk.text("a"), StreamChunk.text("b"), StreamChunk.text("c")]

      stream =
        Stream.resource(
          fn -> chunks end,
          fn
            [chunk | rest] ->
              send(test_pid, {:pulled, chunk.text})
              {[chunk], rest}

            [] ->
              {:halt, []}
          end,
          fn _state -> send(test_pid, :upstream_closed) end
        )

      response = stream_response(stream, %{finish_reason: :stop})
      events = Enum.to_list(StreamResponse.events(response))

      assert Enum.map(events, & &1.type) == [
               :start,
               :text_delta,
               :text_delta,
               :text_delta,
               :finish
             ]

      assert_receive {:pulled, "a"}
      assert_receive {:pulled, "b"}
      assert_receive {:pulled, "c"}
      refute_receive {:pulled, _text}
      assert_receive :upstream_closed
    end

    test "redacts provider metadata and warning secrets" do
      chunks = [
        StreamChunk.meta(%{api_key: "sk-secret", provider_sequence: 2}),
        StreamChunk.meta(%{warning: "Ignored key sk-secret"})
      ]

      response =
        stream_response(chunks, %{
          api_key: "sk-secret",
          warnings: ["Ignored key sk-secret"],
          finish_reason: :stop
        })

      events = Enum.to_list(StreamResponse.events(response))

      assert %StreamEvent{
               type: :provider_event,
               data: %{api_key: "[REDACTED]", provider_sequence: 2}
             } in events

      assert %StreamEvent{type: :warning, data: "Ignored key [REDACTED]"} in events
      refute inspect(events) =~ "sk-secret"
    end

    test "projects provider-native items and files without changing chunks" do
      code_item = %{"type" => "code_interpreter_call", "id" => "ci_1"}

      file = %{
        url: "https://example.com/result.png?api_key=file-secret",
        media_type: "image/png"
      }

      chunks = [
        StreamChunk.meta(%{code_interpreter_item: code_item}),
        StreamChunk.meta(%{file: file})
      ]

      response = stream_response(chunks, %{finish_reason: :stop})
      events = Enum.to_list(StreamResponse.events(response))

      assert %StreamEvent{
               type: :output_item,
               data: %OutputItem{type: :provider_item, data: ^code_item}
             } = Enum.find(events, &(&1.type == :output_item))

      assert %StreamEvent{type: :file, data: %OutputItem{type: :file} = file_item} =
               Enum.find(events, &(&1.type == :file))

      assert file_item.data.media_type == "image/png"
      refute inspect(file_item.data) =~ "file-secret"

      legacy_response = stream_response(chunks, %{finish_reason: :stop})
      assert Enum.to_list(legacy_response.stream) == chunks
    end

    test "keeps the StreamResponse struct and legacy projections unchanged" do
      chunks = [StreamChunk.text("hello"), StreamChunk.meta(%{finish_reason: :stop})]
      response = stream_response(chunks, %{finish_reason: :stop})

      assert response |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
               [:cancel, :context, :metadata_handle, :model, :stream]

      token_response = stream_response(chunks, %{finish_reason: :stop})
      assert Enum.to_list(StreamResponse.tokens(token_response)) == ["hello"]

      legacy_response = stream_response(chunks, %{finish_reason: :stop})
      assert Enum.to_list(legacy_response.stream) == chunks
    end
  end

  defp stream_response(stream, metadata) do
    {:ok, metadata_handle} = MetadataHandle.start_link(fn -> metadata end)

    %StreamResponse{
      stream: stream,
      metadata_handle: metadata_handle,
      cancel: fn -> :ok end,
      model: %LLMDB.Model{provider: :test, id: "test-model"},
      context: Context.new([Context.system("Test")])
    }
  end
end

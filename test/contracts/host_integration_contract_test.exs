defmodule ReqLLM.HostIntegrationContractTest do
  use ExUnit.Case, async: true

  @moduletag contract: :public_api
  @moduletag host_contract: true

  alias ReqLLM.Context
  alias ReqLLM.Provider.Defaults
  alias ReqLLM.Providers.Anthropic
  alias ReqLLM.Providers.Anthropic.Response, as: AnthropicResponse
  alias ReqLLM.Response
  alias ReqLLM.StreamEvent
  alias ReqLLM.StreamResponse
  alias ReqLLM.StreamResponse.MetadataHandle
  alias ReqLLM.Tool
  alias ReqLLM.ToolCall

  test "OpenAI and Anthropic expose equivalent buffered, materialized, and event contracts" do
    projections =
      for provider <- [:openai, :anthropic] do
        fixture = provider_fixture(provider)
        event_response = stream_response(fixture)
        events = event_response |> StreamResponse.events() |> Enum.to_list()
        :ok = StreamResponse.close(event_response)
        refute Process.alive?(event_response.metadata_handle)

        materialized_response = stream_response(fixture)
        assert {:ok, materialized} = StreamResponse.to_response(materialized_response)

        buffered_projection = host_response_projection(fixture.buffered)
        materialized_projection = host_response_projection(materialized)
        event_projection = host_event_projection(events)

        assert buffered_projection == materialized_projection
        assert materialized_projection == event_projection
        assert Enum.all?(events, &match?(%StreamEvent{}, &1))

        buffered_projection
      end

    assert [openai_projection, anthropic_projection] = projections
    assert openai_projection == anthropic_projection
  end

  test "the public boundary inspects tools and appends results without execution or another call" do
    tool =
      Tool.new!(
        name: "lookup",
        description: "Look up documentation",
        parameter_schema: [q: [type: :string, required: true]],
        callback: fn _arguments ->
          send(self(), :tool_executed)
          {:ok, "unexpected"}
        end
      )

    for provider <- [:openai, :anthropic] do
      fixture = provider_fixture(provider)
      assert {:ok, %LLMDB.Model{provider: ^provider}} = ReqLLM.model(fixture.model)
      assert [call] = Response.tool_calls(fixture.buffered)

      assert %{
               state: :valid,
               id: "call_1",
               name: "lookup",
               validated_arguments: %{q: "elixir"}
             } = ToolCall.resolve(call, [tool])

      refute_received :tool_executed

      result = Context.tool_result("call_1", "lookup", "Documentation found")
      input_context = Context.new([Context.user("Find the documentation")])

      assert {:ok, continued} =
               Context.append_tool_exchange(input_context, fixture.buffered, [result])

      assert Enum.map(continued.messages, & &1.role) == [:user, :assistant, :tool]
      assert continued.tools == []
      assert is_binary(Jason.encode!(continued))
      refute_received :tool_executed
    end
  end

  defp provider_fixture(:openai) do
    model = %LLMDB.Model{provider: :openai, id: "host-contract-openai"}

    body = %{
      "id" => "response_1",
      "model" => model.id,
      "warnings" => ["contract warning"],
      "choices" => [
        %{
          "message" => %{
            "content" => "Hello",
            "reasoning_content" => "Think",
            "tool_calls" => [
              %{
                "id" => "call_1",
                "type" => "function",
                "function" => %{
                  "name" => "lookup",
                  "arguments" => ~s({"q":"elixir"})
                }
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{
        "prompt_tokens" => 4,
        "completion_tokens" => 3,
        "total_tokens" => 7
      }
    }

    assert {:ok, buffered} = Defaults.decode_response_body_openai_format(body, model)

    chunks =
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
                    %{
                      "index" => 0,
                      "function" => %{"arguments" => ~s({"q":"elixir"})}
                    }
                  ]
                }
              }
            ]
          }
        },
        %{
          data: %{
            "choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}],
            "usage" => %{
              "prompt_tokens" => 4,
              "completion_tokens" => 3,
              "total_tokens" => 7
            }
          }
        }
      ]
      |> Enum.flat_map(&Defaults.default_decode_stream_event(&1, model))

    fixture(model, buffered, chunks)
  end

  defp provider_fixture(:anthropic) do
    model = %LLMDB.Model{provider: :anthropic, id: "host-contract-anthropic"}

    body = %{
      "id" => "response_1",
      "model" => model.id,
      "content" => [
        %{"type" => "text", "text" => "Hello"},
        %{"type" => "thinking", "thinking" => "Think", "signature" => "signature"},
        %{
          "type" => "tool_use",
          "id" => "call_1",
          "name" => "lookup",
          "input" => %{"q" => "elixir"}
        }
      ],
      "stop_reason" => "tool_use",
      "warnings" => ["contract warning"],
      "usage" => %{
        "input_tokens" => 4,
        "output_tokens" => 3,
        "reasoning_output_tokens" => 3
      }
    }

    assert {:ok, buffered} = AnthropicResponse.decode_response(body, model)

    chunks =
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
            "content_block" => %{
              "type" => "tool_use",
              "id" => "call_1",
              "name" => "lookup"
            }
          }
        },
        %{
          data: %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{
              "type" => "input_json_delta",
              "partial_json" => ~s({"q":"elixir"})
            }
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
      |> Enum.flat_map(&Anthropic.decode_stream_event(&1, model))

    fixture(model, buffered, chunks)
  end

  defp fixture(model, buffered, chunks) do
    %{
      model: model,
      buffered: buffered,
      chunks: chunks,
      metadata: %{
        response_id: "response_1",
        usage: canonical_usage(buffered.usage),
        warnings: ["contract warning"],
        finish_reason: :tool_calls,
        provider_meta: %{"warnings" => ["contract warning"]}
      }
    }
  end

  defp stream_response(fixture) do
    {:ok, handle} = MetadataHandle.start_link(fn -> fixture.metadata end)

    %StreamResponse{
      stream: fixture.chunks,
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: fixture.model,
      context: Context.new()
    }
  end

  defp host_response_projection(response) do
    classification = Response.classify(response)
    metadata = Response.call_metadata(response)

    %{
      type: classification.type,
      text: classification.text,
      thinking: classification.thinking,
      tool_calls: classification.tool_calls,
      finish_reason: classification.finish_reason,
      usage: canonical_usage(metadata.usage),
      warnings: Map.get(metadata, :warnings, []),
      output_types: response |> Response.output_items() |> Enum.map(& &1.type)
    }
  end

  defp host_event_projection(events) do
    tool_calls =
      events
      |> Enum.filter(&(&1.type == :tool_call))
      |> Enum.map(& &1.data)

    usage = events |> Enum.find(&(&1.type == :usage)) |> Map.fetch!(:data)
    finish = events |> List.last() |> Map.fetch!(:data)

    %{
      type: if(tool_calls == [], do: :final_answer, else: :tool_calls),
      text: events |> event_data(:text_delta) |> Enum.join(),
      thinking: events |> event_data(:reasoning_delta) |> Enum.join(),
      tool_calls: tool_calls,
      finish_reason: finish.finish_reason,
      usage: canonical_usage(usage),
      warnings: event_data(events, :warning),
      output_types:
        events
        |> Enum.flat_map(fn
          %StreamEvent{type: :text_delta} -> [:text]
          %StreamEvent{type: :reasoning_delta} -> [:thinking]
          %StreamEvent{type: :tool_call} -> [:tool_call]
          _event -> []
        end)
    }
  end

  defp event_data(events, type) do
    events
    |> Enum.filter(&(&1.type == type))
    |> Enum.map(& &1.data)
  end

  defp canonical_usage(usage) do
    Map.take(usage || %{}, [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :cached_tokens,
      :reasoning_tokens
    ])
  end
end

defmodule ReqLLM.Provider.OpenAIChatMaterializationTest do
  use ExUnit.Case, async: true

  @moduletag contract: :provider_boundary

  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.Provider.Defaults
  alias ReqLLM.Provider.Defaults.ResponseBuilder
  alias ReqLLM.Response
  alias ReqLLM.Response.Stream, as: ResponseStream
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamResponse
  alias ReqLLM.StreamResponse.MetadataHandle
  alias ReqLLM.ToolCall

  setup do
    %{model: %LLMDB.Model{provider: :openai, id: "gpt-chat-test"}}
  end

  test "buffered and streamed chat data share semantic materialization", %{model: model} do
    reasoning_detail = %{
      "type" => "reasoning.text",
      "text" => "Think",
      "signature" => "sig-1",
      "index" => 0
    }

    logprobs = [%{"token" => "Hello", "logprob" => -0.1}]

    buffered_data = %{
      "id" => "chatcmpl-123",
      "model" => "gpt-chat-wire",
      "system_fingerprint" => "fp-123",
      "warnings" => ["provider warning"],
      "choices" => [
        %{
          "message" => %{
            "content" => "Hello",
            "reasoning_content" => "Think",
            "reasoning_details" => [reasoning_detail],
            "tool_calls" => [
              %{
                "id" => "call-1",
                "type" => "function",
                "function" => %{
                  "name" => "lookup",
                  "arguments" => ~s({"city":"Paris"})
                }
              }
            ]
          },
          "finish_reason" => "tool_calls",
          "logprobs" => %{"content" => logprobs}
        }
      ],
      "usage" => %{
        "prompt_tokens" => 4,
        "completion_tokens" => 3,
        "total_tokens" => 7
      }
    }

    {:ok, buffered} = Defaults.decode_response_body_openai_format(buffered_data, model)

    normalized_detail =
      ReasoningDetails.from_openai_compatible(reasoning_detail, :openai, 0)

    streamed_chunks = [
      StreamChunk.text("Hello"),
      StreamChunk.thinking("Think"),
      StreamChunk.tool_call("lookup", %{"city" => "Paris"}, %{id: "call-1", index: 0}),
      StreamChunk.meta(%{reasoning_details: [normalized_detail]}),
      StreamChunk.meta(%{logprobs: logprobs}),
      StreamChunk.meta(%{
        usage: %{
          input_tokens: 4,
          output_tokens: 3,
          total_tokens: 7,
          cached_tokens: 0,
          reasoning_tokens: 3
        },
        finish_reason: :tool_calls
      })
    ]

    {:ok, streamed} =
      ResponseBuilder.build_response(
        streamed_chunks,
        %{
          response_id: "chatcmpl-123",
          usage: %{
            input_tokens: 4,
            output_tokens: 3,
            total_tokens: 7,
            cached_tokens: 0,
            reasoning_tokens: 3
          },
          finish_reason: :tool_calls,
          provider_meta: %{
            "system_fingerprint" => "fp-123",
            "warnings" => ["provider warning"]
          }
        },
        context: Context.new(),
        model: model
      )

    assert semantic_projection(buffered) == semantic_projection(streamed)
    assert buffered.id == streamed.id
    assert buffered.message.metadata == %{}
    assert streamed.message.metadata == %{response_id: "chatcmpl-123"}
    assert buffered.model == "gpt-chat-wire"
    assert streamed.model == "gpt-chat-test"
  end

  test "buffered compatibility profile preserves legacy content and tool argument shapes", %{
    model: model
  } do
    content_data = %{
      "choices" => [
        %{
          "message" => %{
            "content" => [
              %{"type" => "text", "text" => "{\"answer\":"},
              %{"type" => "text", "text" => "42}"}
            ]
          },
          "finish_reason" => "stop"
        }
      ]
    }

    {:ok, content_response} =
      Defaults.decode_response_body_openai_format(content_data, model)

    assert content_response.message.content == [
             %ContentPart{type: :text, text: "{\"answer\":", metadata: %{}},
             %ContentPart{type: :text, text: "42}", metadata: %{}}
           ]

    assert content_response.object == nil
    assert content_response.message.metadata == %{}
    assert content_response.context == Context.new([content_response.message])

    malformed = buffered_tool_response("{not-json")
    scalar = buffered_tool_response(~s("draft"))

    {:ok, malformed_response} =
      Defaults.decode_response_body_openai_format(malformed, model)

    {:ok, scalar_response} = Defaults.decode_response_body_openai_format(scalar, model)

    {:ok, unknown_finish_response} =
      Defaults.decode_response_body_openai_format(
        buffered_tool_response("{}", "tool_call"),
        model
      )

    [malformed_call] = malformed_response.message.tool_calls
    [scalar_call] = scalar_response.message.tool_calls

    assert ToolCall.args_json(malformed_call) == "{not-json"
    assert ToolCall.args_json(scalar_call) == "{}"
    assert ToolCall.metadata(malformed_call) == %{}
    assert ToolCall.metadata(scalar_call) == %{}
    assert unknown_finish_response.finish_reason == :error
  end

  test "StreamResponse helpers share terminal error materialization", %{model: model} do
    error = ReqLLM.Error.API.Stream.exception(reason: "provider failed", cause: :closed)

    to_response = stream_response(model, [StreamChunk.text("partial")], %{error: error})
    process_stream = stream_response(model, [StreamChunk.text("partial")], %{error: error})

    assert {:error, ^error} = StreamResponse.to_response(to_response)
    assert {:error, ^error} = StreamResponse.process_stream(process_stream)
    refute Process.alive?(to_response.metadata_handle)
    refute Process.alive?(process_stream.metadata_handle)
  end

  test "StreamResponse helpers retain cancellation materialization", %{model: model} do
    to_response = stream_response(model, [], %{finish_reason: :cancelled})
    process_stream = stream_response(model, [], %{finish_reason: :cancelled})

    assert {:ok, %Response{finish_reason: :cancelled}} =
             StreamResponse.to_response(to_response)

    assert {:ok, %Response{finish_reason: :cancelled}} =
             StreamResponse.process_stream(process_stream)

    refute Process.alive?(to_response.metadata_handle)
    refute Process.alive?(process_stream.metadata_handle)
  end

  test "legacy stream summaries and final responses retain equal projections", %{model: model} do
    usage = %{
      input_tokens: 2,
      output_tokens: 1,
      total_tokens: 3,
      cached_tokens: 0,
      reasoning_tokens: 0
    }

    chunks = [
      StreamChunk.text("Answer"),
      StreamChunk.thinking("Think"),
      StreamChunk.tool_call("lookup", %{}, %{id: "call-1", index: 0}),
      StreamChunk.meta(%{tool_call_args: %{index: 0, fragment: ~s({"q":"docs"})}}),
      StreamChunk.meta(%{usage: usage, finish_reason: :tool_calls})
    ]

    summary = ResponseStream.summarize(chunks)

    response =
      stream_response(model, chunks, %{
        usage: ReqLLM.Usage.normalize(usage),
        finish_reason: :tool_calls
      })

    assert {:ok, materialized} = StreamResponse.to_response(response)
    assert summary.text == Response.text(materialized)
    assert summary.thinking == Response.thinking(materialized)
    assert summary.tool_calls == Enum.map(Response.tool_calls(materialized), &ToolCall.to_map/1)

    assert canonical_usage(summary.usage) == canonical_usage(materialized.usage)
    assert summary.finish_reason == materialized.finish_reason
  end

  defp semantic_projection(response) do
    %{
      text: Response.text(response),
      thinking: Response.thinking(response),
      tool_calls: Enum.map(Response.tool_calls(response), &ToolCall.to_map/1),
      reasoning_details: response.message.reasoning_details,
      object: response.object,
      usage: response.usage,
      finish_reason: response.finish_reason,
      provider_meta: response.provider_meta
    }
  end

  defp buffered_tool_response(arguments, finish_reason \\ "tool_calls") do
    %{
      "id" => "chatcmpl-tool",
      "choices" => [
        %{
          "message" => %{
            "tool_calls" => [
              %{
                "id" => "call-1",
                "type" => "function",
                "function" => %{"name" => "lookup", "arguments" => arguments}
              }
            ]
          },
          "finish_reason" => finish_reason
        }
      ]
    }
  end

  defp canonical_usage(usage) do
    Map.take(usage, [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :cached_tokens,
      :reasoning_tokens
    ])
  end

  defp stream_response(model, chunks, metadata) do
    {:ok, handle} = MetadataHandle.start_link(fn -> metadata end)

    %StreamResponse{
      stream: chunks,
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: model,
      context: Context.new()
    }
  end
end

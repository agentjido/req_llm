defmodule ReqLLM.Providers.OpenAI.ChatStreamingUsageTest do
  @moduledoc """
  Regression test for the Azure OpenAI / LiteLLM trailing-usage ordering.

  Azure (and OpenAI-compatible gateways like LiteLLM) stream the token `usage`
  in a SEPARATE chunk that arrives AFTER the `finish_reason` chunk and just
  before `[DONE]`:

      data: {"choices":[{"finish_reason":"stop","index":0,"delta":{}}]}
      data: {"choices":[{"index":0,"delta":{}}],"usage":{...}}
      data: [DONE]

  If the finish_reason chunk is flagged `terminal?`, the stream halts there and
  the consumer reads `Response.usage` before the trailing usage chunk has been
  merged — so token counts (and the cost derived from them) come back as zero.
  Chat-completion finish_reason chunks must remain non-terminal so the stream
  finalizes on `[DONE]` after the trailing usage chunk is accumulated.
  """
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Response, StreamResponse, StreamServer}
  alias ReqLLM.Providers.OpenAI.ChatAPI
  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamResponse.MetadataHandle

  @model %LLMDB.Model{provider: :openai, id: "gpt-4o"}

  test "finish_reason chunk is not terminal" do
    finish_event = %{
      data: %{
        "choices" => [%{"finish_reason" => "stop", "index" => 0, "delta" => %{}}]
      }
    }

    chunks = ChatAPI.decode_stream_event(finish_event, @model)
    meta = Enum.find(chunks, &match?(%StreamChunk{type: :meta}, &1))

    assert meta, "expected a meta chunk carrying the finish_reason"
    assert meta.metadata[:finish_reason] == :stop
    refute Map.get(meta.metadata, :terminal?), "finish_reason must not terminate the stream"
  end

  test "the trailing usage chunk (non-empty choices, no finish_reason) yields usage" do
    usage_event = %{
      data: %{
        "choices" => [%{"index" => 0, "delta" => %{}}],
        "usage" => %{
          "prompt_tokens" => 12,
          "completion_tokens" => 8,
          "total_tokens" => 20
        }
      }
    }

    [meta] = ChatAPI.decode_stream_event(usage_event, @model)
    assert meta.type == :meta
    assert meta.metadata[:usage][:input_tokens] == 12
    assert meta.metadata[:usage][:output_tokens] == 8
  end

  test "[DONE] remains terminal" do
    [meta] = ChatAPI.decode_stream_event(%{data: "[DONE]"}, @model)
    assert meta.metadata[:terminal?] == true
  end

  test "an inline error chunk stays terminal" do
    error_event = %{data: %{"error" => %{"message" => "boom"}}}

    [meta] = ChatAPI.decode_stream_event(error_event, @model)
    assert meta.metadata[:finish_reason] == :error
    assert meta.metadata[:terminal?] == true
  end

  test "an empty-choices usage chunk keeps its own terminal flag" do
    usage_event = %{
      data: %{
        "choices" => [],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 2, "total_tokens" => 7}
      }
    }

    [meta] = ChatAPI.decode_stream_event(usage_event, @model)
    assert meta.metadata[:terminal?] == true
    assert meta.metadata[:usage][:input_tokens] == 5
  end

  test "finish_reason + usage in a single event still yields usage" do
    combined = %{
      data: %{
        "choices" => [%{"finish_reason" => "stop", "index" => 0, "delta" => %{}}],
        "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 4, "total_tokens" => 15}
      }
    }

    chunks = ChatAPI.decode_stream_event(combined, @model)
    usage_meta = Enum.find(chunks, &(is_map(&1.metadata) and Map.has_key?(&1.metadata, :usage)))
    assert usage_meta.metadata[:usage][:input_tokens] == 11
    refute Enum.any?(chunks, &(&1.metadata[:finish_reason] == :stop and &1.metadata[:terminal?]))
  end

  test "to_response keeps usage that arrives after finish_reason" do
    {:ok, server} = StreamServer.start_link(provider_mod: ChatAPI, model: @model)
    stream_response = stream_response_for(server)

    await_metadata_waiter(server)

    send_sse(server, %{"choices" => [%{"delta" => %{"content" => "Done"}}]})

    send_sse(server, %{
      "choices" => [%{"finish_reason" => "stop", "index" => 0, "delta" => %{}}]
    })

    send_sse(server, %{
      "choices" => [%{"index" => 0, "delta" => %{}}],
      "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 8, "total_tokens" => 20}
    })

    send_done(server)
    StreamServer.http_event(server, :done)

    assert {:ok, response} = StreamResponse.to_response(stream_response)
    assert Response.text(response) == "Done"
    assert Response.finish_reason(response) == :stop

    usage = Response.usage(response)
    assert usage.input_tokens == 12
    assert usage.output_tokens == 8
    assert usage.total_tokens == 20
  end

  defp stream_response_for(server) do
    {:ok, metadata_handle} =
      MetadataHandle.start_link(fn ->
        case StreamServer.await_metadata(server, 500) do
          {:ok, metadata} -> metadata
          {:error, reason} -> %{error: reason}
        end
      end)

    %StreamResponse{
      stream: stream_from(server),
      metadata_handle: metadata_handle,
      cancel: fn -> StreamServer.cancel(server) end,
      model: @model,
      context: Context.normalize!("Say done")
    }
  end

  defp stream_from(server) do
    Stream.resource(
      fn -> false end,
      fn
        true ->
          {:halt, true}

        false ->
          case StreamServer.next(server, 500) do
            {:ok, chunk} -> {[chunk], false}
            :halt -> {:halt, true}
            {:error, reason} -> raise "stream failed: #{inspect(reason)}"
          end
      end,
      fn exhausted? ->
        if not exhausted? do
          StreamServer.cancel(server)
        end
      end
    )
  end

  defp send_sse(server, data) do
    StreamServer.http_event(server, {:data, "data: #{Jason.encode!(data)}\n\n"})
  end

  defp send_done(server) do
    StreamServer.http_event(server, {:data, "data: [DONE]\n\n"})
  end

  defp await_metadata_waiter(server, attempts \\ 50)

  defp await_metadata_waiter(server, attempts) when attempts > 0 do
    state = :sys.get_state(server)

    if Enum.any?(state.waiting_callers, &(&1.type == :metadata)) do
      :ok
    else
      Process.sleep(10)
      await_metadata_waiter(server, attempts - 1)
    end
  end

  defp await_metadata_waiter(_server, 0), do: flunk("metadata waiter was not registered")
end

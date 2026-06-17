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
  `ChatAPI.decode_stream_event/2` strips the terminal flag off finish_reason
  chunks so the stream finalizes on `[DONE]` instead.
  """
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.OpenAI.ChatAPI
  alias ReqLLM.StreamChunk

  @model %LLMDB.Model{provider: :openai, id: "gpt-4o"}

  test "finish_reason chunk is not terminal (so the trailing usage chunk is not raced)" do
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

  test "an inline error chunk STAYS terminal (must fail fast, not wait for [DONE])" do
    # OpenAI-compatible gateways (incl. LiteLLM/Azure) report mid-stream
    # failures as `data: {"error": {...}}` with an HTTP 200. These must remain
    # terminal so the stream errors immediately instead of hanging.
    error_event = %{data: %{"error" => %{"message" => "boom"}}}

    [meta] = ChatAPI.decode_stream_event(error_event, @model)
    assert meta.metadata[:finish_reason] == :error
    assert meta.metadata[:terminal?] == true
  end

  test "an empty-choices usage chunk keeps its own terminal flag" do
    # Some servers send the final usage with `choices: []`; the default decoder
    # marks that terminal. It has no :finish_reason key, so it must pass through
    # untouched.
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
    # If a gateway combines both into one chunk (non-empty choices), usage is
    # captured and the finish_reason chunk is no longer terminal (stream
    # finalizes on [DONE] / close).
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
end

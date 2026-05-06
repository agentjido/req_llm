defmodule ReqLLM.OpenTelemetry.AttributesTest do
  use ExUnit.Case, async: true

  alias ReqLLM.OpenTelemetry.Attributes

  describe "start/1" do
    test "emits the full GenAI request attribute set" do
      metadata = %{
        request_id: "req-1",
        operation: :chat,
        provider: :openai,
        model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
        request_options: %{
          temperature: 0.7,
          top_p: 0.95,
          top_k: 40,
          max_tokens: 256,
          frequency_penalty: 0.1,
          presence_penalty: 0.2,
          stop_sequences: ["END"],
          seed: 42,
          n: 3,
          stream?: false,
          encoding_formats: ["float"],
          conversation_id: "session-abc"
        },
        server: %{address: "api.openai.com", port: 443}
      }

      attributes = Attributes.start(metadata)

      assert attributes["gen_ai.provider.name"] == "openai"
      assert attributes["gen_ai.operation.name"] == "chat"
      assert attributes["gen_ai.request.model"] == "gpt-5"
      assert attributes["gen_ai.output.type"] == "text"
      assert attributes["req_llm.request_id"] == "req-1"
      assert attributes["gen_ai.request.temperature"] == 0.7
      assert attributes["gen_ai.request.top_p"] == 0.95
      assert attributes["gen_ai.request.top_k"] == 40
      assert attributes["gen_ai.request.max_tokens"] == 256
      assert attributes["gen_ai.request.frequency_penalty"] == 0.1
      assert attributes["gen_ai.request.presence_penalty"] == 0.2
      assert attributes["gen_ai.request.stop_sequences"] == ["END"]
      assert attributes["gen_ai.request.seed"] == 42
      assert attributes["gen_ai.request.choice.count"] == 3
      assert attributes["gen_ai.request.stream"] == false
      assert attributes["gen_ai.request.encoding_formats"] == ["float"]
      assert attributes["gen_ai.conversation.id"] == "session-abc"
      assert attributes["server.address"] == "api.openai.com"
      assert attributes["server.port"] == 443
    end

    test "preserves stream? false when present (does not collapse to nil)" do
      metadata = %{
        operation: :chat,
        provider: :openai,
        model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
        request_options: %{stream?: false}
      }

      attributes = Attributes.start(metadata)

      assert attributes["gen_ai.request.stream"] == false
    end

    test "falls back to model.provider when metadata.provider is missing" do
      metadata = %{
        operation: :chat,
        model: %LLMDB.Model{provider: :amazon_bedrock, id: "claude-sonnet-4-5"}
      }

      assert Attributes.start(metadata)["gen_ai.provider.name"] == "aws.bedrock"
    end

    test "compacts nil and empty values" do
      attributes = Attributes.start(%{operation: :chat})

      refute Map.has_key?(attributes, "gen_ai.request.model")
      refute Map.has_key?(attributes, "server.address")
    end
  end

  describe "terminal/1" do
    test "emits usage, response, and finish reasons" do
      metadata = %{
        operation: :chat,
        finish_reason: :stop,
        usage: %{
          tokens: %{
            input: 21,
            output: 34,
            cached_input: 8,
            cache_creation: 5,
            reasoning: 12
          }
        },
        response_payload: %ReqLLM.Response{
          id: "resp_abc",
          model: "gpt-5-2026-03-01",
          context: nil,
          message: nil,
          object: nil,
          stream?: false,
          stream: nil,
          usage: nil,
          finish_reason: :stop,
          provider_meta: %{},
          error: nil
        },
        model: %LLMDB.Model{provider: :openai, id: "gpt-5"}
      }

      attributes = Attributes.terminal(metadata)

      assert attributes["gen_ai.response.finish_reasons"] == ["stop"]
      assert attributes["gen_ai.usage.input_tokens"] == 21
      assert attributes["gen_ai.usage.output_tokens"] == 34
      assert attributes["gen_ai.usage.cache_read.input_tokens"] == 8
      assert attributes["gen_ai.usage.cache_creation.input_tokens"] == 5
      assert attributes["gen_ai.usage.reasoning.output_tokens"] == 12
      assert attributes["gen_ai.response.id"] == "resp_abc"
      assert attributes["gen_ai.response.model"] == "gpt-5-2026-03-01"
    end

    test "handles flat usage shape (input_tokens / output_tokens)" do
      attributes =
        Attributes.terminal(%{
          operation: :chat,
          finish_reason: :stop,
          usage: %{input_tokens: 12, output_tokens: 8, reasoning_tokens: 64}
        })

      assert attributes["gen_ai.usage.input_tokens"] == 12
      assert attributes["gen_ai.usage.output_tokens"] == 8
      assert attributes["gen_ai.usage.reasoning.output_tokens"] == 64
    end

    test "emits embeddings dimension count for embedding ops" do
      attributes =
        Attributes.terminal(%{
          operation: :embedding,
          finish_reason: nil,
          usage: %{input_tokens: 4, output_tokens: 0},
          response_summary: %{dimensions: 1536}
        })

      assert attributes["gen_ai.embeddings.dimension.count"] == 1536
    end

    test "emits error.type when http_status is a failure" do
      attributes =
        Attributes.terminal(%{
          operation: :chat,
          finish_reason: nil,
          usage: nil,
          http_status: 503
        })

      assert attributes["error.type"] == "503"
    end

    test "falls back to requested model when response.model is empty" do
      attributes =
        Attributes.terminal(%{
          operation: :chat,
          finish_reason: :stop,
          usage: nil,
          response_payload: %{id: "resp_x", model: ""},
          model: %LLMDB.Model{provider: :openai, id: "gpt-5"}
        })

      assert attributes["gen_ai.response.model"] == "gpt-5"
    end
  end

  describe "exception/1 + exception_event/1" do
    test "exception class wins over http_status" do
      metadata = %{
        request_id: "req-2",
        http_status: 500,
        error: RuntimeError.exception("boom")
      }

      assert Attributes.exception(metadata)["error.type"] == "RuntimeError"
      assert Attributes.exception_event(metadata)["exception.type"] == "RuntimeError"
      assert Attributes.exception_event(metadata)["exception.message"] == "boom"
    end

    test "uses http_status when no error struct" do
      metadata = %{request_id: "req-3", http_status: 504}

      assert Attributes.exception(metadata)["error.type"] == "504"
    end

    test "falls back to _OTHER when nothing identifies the error" do
      assert Attributes.exception(%{request_id: "req-4"})["error.type"] == "_OTHER"
    end
  end

  describe "error_status/1" do
    test "returns nil for success" do
      assert Attributes.error_status(%{http_status: 200}) == nil
      assert Attributes.error_status(%{}) == nil
    end

    test "returns {error_type, message} for HTTP failures" do
      assert Attributes.error_status(%{http_status: 503}) == {"503", "HTTP 503"}
    end
  end

  describe "provider_name/1 + request_model/1" do
    test "provider_name resolves the spec enum" do
      metadata = %{
        provider: :anthropic,
        model: %LLMDB.Model{id: "claude-sonnet-4-6", provider: :anthropic}
      }

      assert Attributes.provider_name(metadata) == "anthropic"
    end

    test "provider_name falls back to model.provider when metadata.provider is nil" do
      metadata = %{model: %LLMDB.Model{id: "gpt-5", provider: :openai}}
      assert Attributes.provider_name(metadata) == "openai"
    end

    test "provider_name returns nil when neither source is present" do
      assert Attributes.provider_name(%{}) == nil
    end

    test "request_model returns the model id" do
      metadata = %{model: %LLMDB.Model{id: "gpt-5", provider: :openai}}
      assert Attributes.request_model(metadata) == "gpt-5"
    end

    test "request_model returns nil when model is missing" do
      assert Attributes.request_model(%{}) == nil
    end
  end

  describe "streaming_ttfc_seconds/1" do
    test "converts native time-to-first-chunk to seconds" do
      native = System.convert_time_unit(250, :millisecond, :native)
      metadata = %{mode: :stream, streaming: %{time_to_first_chunk: native}}
      assert_in_delta(Attributes.streaming_ttfc_seconds(metadata), 0.25, 0.001)
    end

    test "returns nil for sync requests" do
      assert Attributes.streaming_ttfc_seconds(%{mode: :sync}) == nil
    end

    test "returns nil when streaming map has no first chunk" do
      assert Attributes.streaming_ttfc_seconds(%{
               mode: :stream,
               streaming: %{time_to_first_chunk: nil}
             }) == nil
    end
  end

  describe "terminal/1 streaming attribute" do
    test "emits gen_ai.response.time_to_first_chunk for streaming requests" do
      native = System.convert_time_unit(120, :millisecond, :native)

      attrs =
        Attributes.terminal(%{
          finish_reason: :stop,
          mode: :stream,
          streaming: %{first_chunk_at: 0, time_to_first_chunk: native}
        })

      assert_in_delta(attrs["gen_ai.response.time_to_first_chunk"], 0.12, 0.001)
    end

    test "omits gen_ai.response.time_to_first_chunk for sync requests" do
      attrs = Attributes.terminal(%{finish_reason: :stop, mode: :sync})
      refute Map.has_key?(attrs, "gen_ai.response.time_to_first_chunk")
    end
  end
end

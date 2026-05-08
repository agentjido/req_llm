defmodule ReqLLM.OpenTelemetry.SemConvTest do
  use ExUnit.Case, async: true

  alias ReqLLM.OpenTelemetry.{Attributes, SemConv}

  describe "provider_name/1" do
    test "maps known providers to spec values" do
      assert SemConv.provider_name(:openai) == "openai"
      assert SemConv.provider_name(:anthropic) == "anthropic"
      assert SemConv.provider_name(:amazon_bedrock) == "aws.bedrock"
      assert SemConv.provider_name(:azure) == "azure.ai.openai"
      assert SemConv.provider_name(:google) == "gcp.gen_ai"
      assert SemConv.provider_name(:google_vertex) == "gcp.vertex_ai"
      assert SemConv.provider_name(:groq) == "groq"
      assert SemConv.provider_name(:xai) == "x_ai"
      assert SemConv.provider_name(:deepseek) == "deepseek"
    end

    test "maps :openai_codex to openai (same provider, different model line)" do
      assert SemConv.provider_name(:openai_codex) == "openai"
    end

    test "stringifies non-spec providers" do
      assert SemConv.provider_name(:openrouter) == "openrouter"
      assert SemConv.provider_name(:cerebras) == "cerebras"
    end

    test "passes through binaries and rejects nil/garbage" do
      assert SemConv.provider_name("custom") == "custom"
      assert SemConv.provider_name(nil) == nil
      assert SemConv.provider_name(123) == nil
    end
  end

  describe "operation_name/1" do
    test "maps known operations to spec values" do
      assert SemConv.operation_name(:chat) == "chat"
      assert SemConv.operation_name(:object) == "chat"
      assert SemConv.operation_name(:embedding) == "embeddings"
      assert SemConv.operation_name(:image) == "generate_content"
    end

    test "defaults to chat when nil" do
      assert SemConv.operation_name(nil) == "chat"
    end

    test "stringifies non-spec operations" do
      assert SemConv.operation_name(:speech) == "speech"
      assert SemConv.operation_name(:transcription) == "transcription"
      assert SemConv.operation_name("custom") == "custom"
    end
  end

  describe "output_type/1" do
    test "maps operations to GenAI output types" do
      assert SemConv.output_type(:chat) == "text"
      assert SemConv.output_type(:object) == "json"
      assert SemConv.output_type(:image) == "image"
      assert SemConv.output_type(:embedding) == "embedding"
      assert SemConv.output_type(:speech) == "speech"
      assert SemConv.output_type(:transcription) == "text"
    end

    test "returns nil for unknown operations" do
      assert SemConv.output_type(:custom_op) == nil
      assert SemConv.output_type(nil) == nil
    end
  end

  describe "span_name/2" do
    test "joins operation and model id" do
      assert SemConv.span_name(:chat, "gpt-5") == "chat gpt-5"

      assert SemConv.span_name(:embedding, "text-embedding-3-small") ==
               "embeddings text-embedding-3-small"
    end

    test "falls back to operation when model id is empty or nil" do
      assert SemConv.span_name(:chat, "") == "chat"
      assert SemConv.span_name(:chat, nil) == "chat"
    end
  end

  describe "cross-surface attribute alignment" do
    test "bridge and stub mapper emit the same gen_ai.* attribute keys for the same metadata" do
      metadata = %{
        request_id: "req-x",
        operation: :chat,
        provider: :openai,
        model: %LLMDB.Model{provider: :openai, id: "gpt-5"},
        finish_reason: :stop,
        usage: %{
          tokens: %{input: 10, output: 20, cached_input: 4, cache_creation: 3, reasoning: 5}
        },
        request_options: %{temperature: 0.5, stream?: false},
        server: %{address: "api.openai.com", port: 443},
        response_payload: %{id: "resp_x", model: "gpt-5-2026-03-01"}
      }

      start_attrs = Attributes.start(metadata)
      terminal_attrs = Attributes.terminal(metadata)
      combined = Map.merge(start_attrs, terminal_attrs)

      bridge_keys = combined |> Map.keys() |> Enum.sort()

      stub_stub = ReqLLM.Telemetry.OpenTelemetry.request_stop(metadata)
      stub_keys = stub_stub.attributes |> Map.keys() |> Enum.sort()

      assert bridge_keys == stub_keys
    end
  end
end

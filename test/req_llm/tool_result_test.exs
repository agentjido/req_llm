defmodule ReqLLM.ToolResultTest do
  use ExUnit.Case, async: true

  @moduletag contract: :public_api

  alias ReqLLM.{Message, ToolResult}

  describe "schema helpers" do
    test "exposes schema and metadata key" do
      refute is_nil(ToolResult.schema())
      assert ToolResult.metadata_key() == :tool_output
    end
  end

  describe "application output and model-facing content" do
    test "remain independently inspectable" do
      content = [ReqLLM.Message.ContentPart.text("A concise model-facing result")]

      result = %ToolResult{
        output: %{records: [%{id: 1}], internal_cursor: "cursor_123"},
        content: content,
        metadata: %{provider_native: %{request_id: "req_123"}}
      }

      assert result.output == %{records: [%{id: 1}], internal_cursor: "cursor_123"}
      assert result.content == content
      assert result.metadata.provider_native.request_id == "req_123"
    end
  end

  describe "output_from_message/1" do
    test "reads atom-key metadata from message structs" do
      message = %Message{role: :tool, metadata: %{tool_output: %{ok: true}}}

      assert ToolResult.output_from_message(message) == %{ok: true}
    end

    test "reads string-key metadata from plain maps" do
      assert ToolResult.output_from_message(%{metadata: %{"tool_output" => %{ok: true}}}) == %{
               ok: true
             }
    end

    test "returns nil for unsupported inputs" do
      assert ToolResult.output_from_message(nil) == nil
      assert ToolResult.output_from_message(%{}) == nil
    end
  end

  describe "put_output_metadata/2" do
    test "returns metadata unchanged when output is nil" do
      metadata = %{request_id: "req_123"}

      assert ToolResult.put_output_metadata(metadata, nil) == metadata
    end

    test "adds tool output metadata when output is present" do
      assert ToolResult.put_output_metadata(%{request_id: "req_123"}, %{ok: true}) == %{
               request_id: "req_123",
               tool_output: %{ok: true}
             }
    end
  end
end

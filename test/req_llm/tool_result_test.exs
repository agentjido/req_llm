defmodule ReqLLM.ToolResultTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Message, ToolResult}

  describe "schema helpers" do
    test "exposes schema and metadata key" do
      refute is_nil(ToolResult.schema())
      assert ToolResult.metadata_key() == :tool_output
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

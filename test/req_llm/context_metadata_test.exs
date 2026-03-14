defmodule ReqLLM.ContextMetadataTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context

  test "preserves assistant metadata and reasoning details when normalizing loose maps" do
    direct =
      Context.assistant(
        "Use the tool.",
        tool_calls: [%{id: "call_123", name: "list_directory", arguments: %{path: "."}}],
        metadata: %{response_id: "resp_123"}
      )

    assert direct.metadata == %{response_id: "resp_123"}

    {:ok, context} =
      Context.normalize([
        %{
          role: :assistant,
          content: "Use the tool.",
          tool_calls: [%{id: "call_123", name: "list_directory", arguments: %{path: "."}}],
          metadata: %{response_id: "resp_123"},
          reasoning_details: [%{signature: "sig_abc"}]
        }
      ])

    [message] = context.messages

    assert message.metadata == %{response_id: "resp_123"}
    assert message.reasoning_details == [%{signature: "sig_abc"}]
    assert is_list(message.tool_calls)
  end
end

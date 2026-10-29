defmodule ReqLLM.Providers.Anthropic.PromptCacheBreakpointsTest do
  @moduledoc """
  Tests Anthropic prompt-cache breakpoints for direct and deferred tool definitions.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Anthropic, async: true

  import ReqLLM.Test.AnthropicToolHelpers,
    only: [deferred_tool: 1, direct_tool: 1, encode_tools: 3]

  describe "tool search tool" do
    test "the prompt-cache breakpoint lands on the last non-deferred tool" do
      [search, direct, deferred_a, deferred_b] =
        encode_tools(
          [direct_tool("direct"), deferred_tool("deferred_a"), deferred_tool("deferred_b")],
          [tool_search: %{}],
          anthropic_prompt_cache: true
        )

      assert direct["cache_control"] == %{"type" => "ephemeral"}
      refute Map.has_key?(search, "cache_control")
      refute Map.has_key?(deferred_a, "cache_control")
      refute Map.has_key?(deferred_b, "cache_control")
    end

    test "without deferred tools the breakpoint stays on the last tool" do
      [_search, _first, last] =
        encode_tools([direct_tool("first"), direct_tool("last")], [tool_search: %{}],
          anthropic_prompt_cache: true
        )

      assert last["cache_control"] == %{"type" => "ephemeral"}
    end
  end
end

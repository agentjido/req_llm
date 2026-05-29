defmodule ReqLLM.ProviderTest.ComprehensiveTest do
  use ExUnit.Case, async: true

  alias ReqLLM.ProviderTest.Comprehensive

  describe "object generation support" do
    test "excludes Anthropic models that do not support structured outputs" do
      refute Comprehensive.supports_object_generation?("anthropic:claude-opus-4-20250514")

      refute Comprehensive.supports_streaming_object_generation?(
               "anthropic:claude-opus-4-20250514"
             )
    end

    test "includes Anthropic models that support structured outputs" do
      assert Comprehensive.supports_object_generation?("anthropic:claude-opus-4-1-20250805")

      assert Comprehensive.supports_streaming_object_generation?(
               "anthropic:claude-opus-4-1-20250805"
             )
    end
  end
end

defmodule ReqLLM.UsageHelpersTest do
  use ExUnit.Case, async: true

  describe "ReqLLM.Usage.Tool" do
    test "build defaults to call unit" do
      assert ReqLLM.Usage.Tool.build(:web_search, 2) == %{web_search: %{count: 2, unit: :call}}
    end

    test "count respects unit matching" do
      usage = %{tool_usage: %{web_search: %{count: 3, unit: "query"}}}

      assert ReqLLM.Usage.Tool.count(usage, :web_search, :query) == 3
      assert ReqLLM.Usage.Tool.count(usage, :web_search, :call) == 0
    end
  end

  describe "ReqLLM.Usage.Image" do
    test "counts inline image parts" do
      parts = [
        %{"inlineData" => %{"mimeType" => "image/png", "data" => "AAA"}},
        %{"inlineData" => %{"mimeType" => "text/plain", "data" => "BBB"}},
        %{"inline_data" => %{"mime_type" => "image/jpeg", "data" => "CCC"}}
      ]

      assert ReqLLM.Usage.Image.count_inline_parts(parts) == 2
    end
  end

  describe "ReqLLM.Usage" do
    test "normalizes provider usage maps with canonical and alias keys" do
      usage =
        ReqLLM.Usage.normalize(%{
          "prompt_tokens" => 10,
          "completion_tokens" => 5
        })

      assert usage.input_tokens == 10
      assert usage.output_tokens == 5
      assert usage.total_tokens == 15
      assert usage.input == 10
      assert usage.output == 5
    end

    test "preserves explicit total_tokens when provided" do
      usage =
        ReqLLM.Usage.normalize(%{
          input_tokens: 4,
          output_tokens: 6,
          total_tokens: 100
        })

      assert usage.input_tokens == 4
      assert usage.output_tokens == 6
      assert usage.total_tokens == 100
      assert usage.input == 4
      assert usage.output == 6
    end

    test "returns zeroed canonical and alias keys for non-map values" do
      usage = ReqLLM.Usage.normalize(nil)

      assert usage == %{
               input_tokens: 0,
               output_tokens: 0,
               total_tokens: 0,
               input: 0,
               output: 0
             }
    end
  end

  describe "ReqLLM.Pricing" do
    test "resolves tool unit from pricing components" do
      model = %LLMDB.Model{
        id: "m1",
        provider: :test,
        pricing: %{components: [%{kind: :tool, tool: "web_search", unit: "query"}]}
      }

      assert ReqLLM.Pricing.tool_unit(model, :web_search) == "query"
    end
  end
end

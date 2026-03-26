defmodule ReqLLM.ModelIdTest do
  use ExUnit.Case, async: true

  alias ReqLLM.ModelId

  describe "normalize/2" do
    test "returns model struct ids when available" do
      assert ModelId.normalize(%LLMDB.Model{provider: :openai, id: "gpt-4o"}, "fallback") ==
               "gpt-4o"
    end

    test "returns string ids unchanged" do
      assert ModelId.normalize("openai:gpt-4o", "fallback") == "openai:gpt-4o"
    end

    test "falls back for unsupported values" do
      assert ModelId.normalize(nil, "fallback") == "fallback"
      assert ModelId.normalize(%{}, "fallback") == "fallback"
    end
  end
end

defmodule ReqLLM.EvaluationFilterTest do
  use ExUnit.Case, async: false

  test "OpenRouter fallback respects the LLMDB model filter" do
    on_exit(fn -> LLMDB.load() end)

    assert {:ok, _snapshot} = LLMDB.load(allow: [:typesafe])

    assert ReqLLM.evaluation_models() == [
             "typesafe:jev-1.13.0",
             "typesafe:jev-latest",
             "typesafe:jev-preview"
           ]

    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
             ReqLLM.evaluate(
               "openrouter:typesafe/jev-1.13",
               "text",
               %{urgent: %{type: :boolean, instructions: "Is this urgent?"}},
               req_http_options: [plug: fn _conn -> flunk("unexpected HTTP request") end]
             )

    assert message =~ "Unknown evaluation model spec"
  end
end

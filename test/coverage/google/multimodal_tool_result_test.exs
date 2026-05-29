defmodule ReqLLM.Coverage.Google.MultimodalToolResultTest do
  @moduledoc """
  Google multimodal tool result coverage tests.

  Validates the Gemini 3+ `functionResponse.parts` encoding: a tool
  returning text alongside a PDF must deliver both to the model with
  the binary nested inside `functionResponse.parts` and the text in
  `functionResponse.response.content`.

  Run with REQ_LLM_FIXTURES_MODE=record to test against live API and record fixtures.
  Otherwise uses fixtures for fast, reliable testing.
  """

  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: "google"
  @moduletag timeout: 180_000

  @model_spec "google:gemini-3.1-pro-preview"

  setup_all do
    LLMDB.load(allow: :all, custom: %{})
    :ok
  end

  @tag scenario: :multimodal_tool_result
  @tag model: "gemini-3.1-pro-preview"
  test "tool result with PDF and accompanying text reaches the model" do
    pdf_bytes = File.read!(Path.join(File.cwd!(), "priv/examples/test.pdf"))

    tools = [
      ReqLLM.tool(
        name: "get_document",
        description: "Fetch the requested document and return its raw contents.",
        parameter_schema: [
          name: [type: :string, required: true]
        ],
        callback: fn _args ->
          {:ok,
           [
             ReqLLM.Message.ContentPart.text("Here is the file you requested:"),
             ReqLLM.Message.ContentPart.file(pdf_bytes, "test.pdf", "application/pdf")
           ]}
        end
      )
    ]

    base_opts =
      param_bundles().deterministic
      |> Keyword.put(:max_tokens, 256)

    {:ok, resp1} =
      ReqLLM.generate_text(
        @model_spec,
        "Call get_document with name=\"test.pdf\" to fetch the file, then quote the text it contains in full.",
        fixture_opts(
          "multimodal_tool_result_1",
          base_opts ++
            [
              tools: tools,
              tool_choice: %{type: "tool", name: "get_document"}
            ]
        )
      )

    tool_calls = ReqLLM.Response.tool_calls(resp1)
    assert tool_calls != [], "expected the model to call get_document"

    ctx2 = ReqLLM.Context.execute_and_append_tools(resp1.context, tool_calls, tools)

    {:ok, resp2} =
      ReqLLM.generate_text(
        @model_spec,
        ctx2,
        fixture_opts("multimodal_tool_result_2", base_opts ++ [tools: tools])
      )

    text = ReqLLM.Response.text(resp2) || ""
    assert text != "", "expected a follow-up response after the tool result"

    assert String.match?(text, ~r/test pdf document/i),
           "expected model to quote PDF contents in follow-up, got: #{text}"
  end
end

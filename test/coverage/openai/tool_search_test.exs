defmodule ReqLLM.Coverage.OpenAI.ToolSearchTest do
  @moduledoc """
  OpenAI Responses API hosted tool search coverage.

  The model finds a deferred function inside a namespace with the hosted
  `tool_search` tool and calls it. The second turn replays the search items and
  the call's namespace, which the API accepts only together.

  Run with REQ_LLM_FIXTURES_MODE=record and OPENAI_API_KEY to record fixtures:

      REQ_LLM_FIXTURES_MODE=record mix test test/coverage/openai/tool_search_test.exs --include coverage
  """

  use ExUnit.Case, async: false

  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ProviderTest.ResponsesContext
  alias ReqLLM.Response
  alias ReqLLM.Test.CompatibilityScenario

  @moduletag :coverage
  @moduletag provider: "openai"
  @moduletag timeout: 240_000

  @model_id ResponsesContext.model_id()
  @model_spec "openai:#{@model_id}"

  @prompt "How many managed devices are at the hq site? Use your tools; never guess."

  setup_all do
    LLMDB.load(allow: :all, custom: Application.get_env(:llm_db, :custom, %{}))
    :ok
  end

  defp tools do
    [
      %{type: "tool_search"},
      ReqLLM.Tool.new!(
        name: "get_time",
        description: "Get the current UTC time.",
        parameter_schema: [],
        callback: fn _ -> {:ok, "2026-10-14T12:00:00Z"} end
      ),
      deferred("list", "List the managed devices at a site, with the device count.", "devices"),
      deferred("restart", "Restart the managed devices at a site.", "devices"),
      deferred("invoices", "List the invoices for a site.", "billing")
    ]
  end

  defp deferred(name, description, namespace) do
    ReqLLM.Tool.new!(
      name: name,
      description: description,
      parameter_schema: [site: [type: :string, required: true]],
      callback: fn _ -> {:ok, "Site hq has 17 managed devices."} end,
      provider_options: [
        openai: [
          defer_loading: true,
          namespace: namespace,
          namespace_description: "Tools for #{namespace} at a site."
        ]
      ]
    )
  end

  defp opts(index, extra) do
    ResponsesContext.opts(
      :openai,
      :tool_search,
      index,
      Keyword.merge([tools: tools(), provider_options: [store: false]], extra)
    )
  end

  defp assert_search_turn(%Response{} = response) do
    item_types =
      for %ContentPart{type: :provider_block, data: %{"type" => type}} <- response.message.content,
          do: type

    assert "tool_search_call" in item_types
    assert "tool_search_output" in item_types

    assert [call] = response.message.tool_calls
    assert ReqLLM.ToolCall.name(call) == "list"
    assert ReqLLM.ToolCall.metadata(call)[:namespace] == "devices"
    call
  end

  defp follow_up(%Response{} = response, call) do
    Context.append(
      response.context,
      Context.tool_result(call.id, "Site hq has 17 managed devices.")
    )
  end

  @tag CompatibilityScenario.tag!(:tool_search)
  @tag model: @model_id
  test "finds a namespaced deferred function and replays the search" do
    {:ok, first} = ReqLLM.generate_text(@model_spec, @prompt, opts(0, []))
    call = assert_search_turn(first)

    {:ok, second} = ReqLLM.generate_text(@model_spec, follow_up(first, call), opts(1, []))
    assert Response.text(second) =~ "17"
  end

  @tag CompatibilityScenario.tag!(:tool_search)
  @tag model: @model_id
  test "streams the search items and replays them" do
    {:ok, stream_response} = ReqLLM.stream_text(@model_spec, @prompt, opts(2, stream: true))
    {:ok, first} = ReqLLM.StreamResponse.to_response(stream_response)
    call = assert_search_turn(first)

    {:ok, second} = ReqLLM.generate_text(@model_spec, follow_up(first, call), opts(3, []))
    assert Response.text(second) =~ "17"
  end
end

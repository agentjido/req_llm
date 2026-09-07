defmodule ReqLLM.ProviderTest.SequentialToolCache do
  @moduledoc false

  import ExUnit.Assertions

  alias ReqLLM.Context
  alias ReqLLM.Response
  alias ReqLLM.Test.CompatibilityScenario
  alias ReqLLM.Test.Helpers
  alias ReqLLM.ToolCall

  @cache_padding String.duplicate("Stable cache reference sentence for this fixture. ", 450)

  def run(model, opts \\ []) do
    provider_options = Keyword.get(opts, :provider_options, [])

    context =
      Context.new([
        Context.system(system_prompt()),
        Context.user("Find the current balance for customer Ada Lovelace.")
      ])

    assert {:ok, first} = generate(model, context, 0, provider_options)
    first_call = assert_tool_call(first, "find_customer", %{"name" => "Ada Lovelace"})

    if Keyword.get(opts, :assert_initial_cache, false) do
      assert first.usage.cached_tokens > 0 or first.usage.cache_creation_tokens > 0
    end

    context = append_result(first, first_call, "customer_7f9c2a")

    assert {:ok, second} = generate(model, context, 1, provider_options)

    second_call =
      assert_tool_call(second, "find_account", %{"customer_id" => "customer_7f9c2a"})

    assert second.usage.cached_tokens > 0
    context = append_result(second, second_call, "account_4d81be")

    assert {:ok, third} = generate(model, context, 2, provider_options)
    third_call = assert_tool_call(third, "get_balance", %{"account_id" => "account_4d81be"})
    assert third.usage.cached_tokens > 0
    context = append_result(third, third_call, "42")

    assert {:ok, final} = generate(model, context, 3, provider_options)
    assert Response.tool_calls(final) == []
    assert Response.text(final) =~ "42"
    assert final.usage.cached_tokens > 0

    :ok
  end

  defp generate(model, context, fixture_index, provider_options) do
    fixture = CompatibilityScenario.fixture!(:sequential_tool_cache, fixture_index)

    ReqLLM.generate_text(
      model,
      context,
      Helpers.fixture_opts(fixture,
        max_tokens: 128,
        temperature: 0.0,
        tools: tools(),
        provider_options: provider_options
      )
    )
  end

  defp append_result(response, call, result) do
    tool_result = Context.tool_result(call.id, call.function.name, result)

    assert {:ok, context} =
             Context.append_tool_exchange(response.context, response, [tool_result])

    context
  end

  defp assert_tool_call(response, name, arguments) do
    assert [call] = Response.tool_calls(response)
    assert call.function.name == name
    assert ToolCall.args_map(call) == arguments
    call
  end

  defp system_prompt do
    """
    Complete the customer balance workflow with exactly one tool call per response.
    First call find_customer. After its result, call find_account with that exact customer ID.
    After its result, call get_balance with that exact account ID. Then report the balance.
    Do not guess an ID. Do not call a later tool before its required result is present.

    #{@cache_padding}
    """
  end

  defp tools do
    [
      ReqLLM.tool(
        name: "find_customer",
        description: "Find the customer ID for an exact customer name",
        parameter_schema: [
          name: [type: :string, required: true, doc: "Exact customer name"]
        ],
        callback: fn _arguments -> {:ok, "customer_7f9c2a"} end
      ),
      ReqLLM.tool(
        name: "find_account",
        description: "Find the account ID for an exact customer ID",
        parameter_schema: [
          customer_id: [type: :string, required: true, doc: "Exact customer ID"]
        ],
        callback: fn _arguments -> {:ok, "account_4d81be"} end
      ),
      ReqLLM.tool(
        name: "get_balance",
        description: "Get the current balance for an exact account ID",
        parameter_schema: [
          account_id: [type: :string, required: true, doc: "Exact account ID"]
        ],
        callback: fn _arguments -> {:ok, "42"} end
      )
    ]
  end
end

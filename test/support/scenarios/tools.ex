defmodule ReqLLM.Test.Scenarios.ToolMulti do
  @moduledoc """
  Multi-tool selection scenario.
  """

  use ReqLLM.Test.Scenario,
    id: :tool_multi,
    name: "tool calling - multi-tool selection",
    description: "Validates that tool-capable models can select an appropriate tool."

  alias ReqLLM.Test.Scenarios.Capabilities

  @impl ReqLLM.Test.Scenario
  def applies?(model), do: Capabilities.supports_tool_calling?(model)

  @impl ReqLLM.Test.Scenario
  def fixtures(_model), do: ["multi_tool"]

  @impl ReqLLM.Test.Scenario
  def run(model_spec, model, opts) do
    provider = Keyword.fetch!(opts, :provider)

    tools = [
      ReqLLM.tool(
        name: "get_weather",
        description: "Get current weather information for a location",
        parameter_schema: [
          location: [type: :string, required: true],
          unit: [type: {:in, ["celsius", "fahrenheit"]}]
        ],
        callback: fn _args -> {:ok, "Weather data"} end
      ),
      ReqLLM.tool(
        name: "tell_joke",
        description: "Tell a funny joke",
        parameter_schema: [
          topic: [type: :string, doc: "Topic for the joke"]
        ],
        callback: fn _args -> {:ok, "Why did the cat cross the road?"} end
      ),
      ReqLLM.tool(
        name: "get_time",
        description: "Get the current time",
        parameter_schema: [],
        callback: fn _args -> {:ok, "12:00 PM"} end
      )
    ]

    budget = tool_budget_for(model_spec)

    base_opts =
      param_bundles().deterministic
      |> Keyword.put(:max_tokens, budget)
      |> then(&reasoning_overlay(model_spec, &1, budget * 2))

    result =
      ReqLLM.generate_text(
        model_spec,
        "What's the weather like in Paris, France?",
        fixture_opts("multi_tool", base_opts ++ [tools: tools])
      )

    case result do
      {:ok, response} ->
        assert_basic_response(result)

        tool_calls = ReqLLM.Response.tool_calls(response) || []

        if Enum.empty?(tool_calls) and truncated?(response) do
          rt = ReqLLM.Response.reasoning_tokens(response)
          assert is_number(rt) and rt >= 0
        else
          assert_has_tool_call(response)
        end

      {:error, _} ->
        flunk("Expected successful response with tool call")
    end

    Scenario.ok(__MODULE__, [Scenario.step(:generate_text, "multi_tool")], %{
      provider: provider,
      model: model.id
    })
  end
end

defmodule ReqLLM.Test.Scenarios.ToolRoundTrip do
  @moduledoc """
  Tool round-trip execution scenario.
  """

  use ReqLLM.Test.Scenario,
    id: :tool_round_trip,
    name: "tool calling - round trip execution",
    description: "Validates tool execution, context append, and final response."

  alias ReqLLM.Test.Scenarios.Capabilities

  @impl ReqLLM.Test.Scenario
  def applies?(model), do: Capabilities.supports_tool_calling?(model)

  @impl ReqLLM.Test.Scenario
  def fixtures(_model), do: ["tool_round_trip_1", "tool_round_trip_2"]

  @impl ReqLLM.Test.Scenario
  def run(model_spec, model, opts) do
    provider = Keyword.fetch!(opts, :provider)

    tools = [
      ReqLLM.tool(
        name: "add",
        description: "Add two integers",
        parameter_schema: [
          a: [type: :integer, required: true],
          b: [type: :integer, required: true]
        ],
        callback: fn %{a: a, b: b} -> {:ok, a + b} end
      )
    ]

    base_opts =
      param_bundles().deterministic
      |> Keyword.put(:max_tokens, tool_budget_for(model_spec))

    tool_choice =
      if Capabilities.supports_forced_tool_choice?(model) do
        %{type: "tool", name: "add"}
      else
        "required"
      end

    {:ok, resp1} =
      ReqLLM.generate_text(
        model_spec,
        "Use the add tool to compute 2 + 3. After the tool result arrives, respond with 'sum=<value>'.",
        fixture_opts(
          "tool_round_trip_1",
          base_opts ++
            [
              tools: tools,
              tool_choice: tool_choice
            ]
        )
      )

    tool_calls = ReqLLM.Response.tool_calls(resp1)
    assert tool_calls != []

    ctx2 = ReqLLM.Context.execute_and_append_tools(resp1.context, tool_calls, tools)

    {:ok, resp2} =
      ReqLLM.generate_text(
        model_spec,
        ctx2,
        fixture_opts("tool_round_trip_2", base_opts)
      )

    text = ReqLLM.Response.text(resp2) || ""
    assert text != ""
    assert String.contains?(text, "5")
    assert Enum.empty?(ReqLLM.Response.tool_calls(resp2))

    Scenario.ok(
      __MODULE__,
      [
        Scenario.step(:tool_request, "tool_round_trip_1"),
        Scenario.step(:tool_result, "tool_round_trip_2")
      ],
      %{provider: provider, model: model.id}
    )
  end
end

defmodule ReqLLM.Test.Scenarios.ToolNone do
  @moduledoc """
  No-tool text generation scenario.
  """

  use ReqLLM.Test.Scenario,
    id: :tool_none,
    name: "tool calling - no tool when inappropriate",
    description: "Validates that regular text output still works when tools are available."

  alias ReqLLM.Test.Scenarios.Capabilities

  @impl ReqLLM.Test.Scenario
  def applies?(model), do: Capabilities.supports_tool_calling?(model)

  @impl ReqLLM.Test.Scenario
  def fixtures(_model), do: ["no_tool"]

  @impl ReqLLM.Test.Scenario
  def run(model_spec, model, opts) do
    provider = Keyword.fetch!(opts, :provider)

    tools = [
      ReqLLM.tool(
        name: "get_weather",
        description: "Get current weather information for a location",
        parameter_schema: [
          location: [type: :string, required: true]
        ],
        callback: fn _args -> {:ok, "Weather data"} end
      )
    ]

    budget = tool_budget_for(model_spec)

    base_opts =
      param_bundles().deterministic
      |> Keyword.put(:max_tokens, budget)
      |> then(&reasoning_overlay(model_spec, &1, budget * 2))

    ReqLLM.generate_text(
      model_spec,
      "Tell me a joke about cats",
      fixture_opts("no_tool", base_opts ++ [tools: tools])
    )
    |> assert_basic_response()

    Scenario.ok(__MODULE__, [Scenario.step(:generate_text, "no_tool")], %{
      provider: provider,
      model: model.id
    })
  end
end

defmodule ReqLLM.Test.Scenarios.FixtureGuardrailTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Test.FixturePath
  alias ReqLLM.Test.Fixtures
  alias ReqLLM.Test.Scenarios

  @expected_fixtures %{
    basic: ["basic"],
    streaming: ["streaming"],
    token_limit: ["token_limit"],
    usage: ["usage"],
    context_append: ["context_append_1", "context_append_2"],
    tool_multi: ["multi_tool"],
    tool_round_trip: ["tool_round_trip_1", "tool_round_trip_2"],
    tool_none: ["no_tool"],
    object_basic: ["object_basic"],
    object_streaming: ["object_streaming"],
    reasoning: ["reasoning_basic", "reasoning_streaming"]
  }

  @scenario_specs %{
    basic: "openai:gpt-4o-mini",
    streaming: "openai:gpt-4o-mini",
    token_limit: "openai:gpt-4o-mini",
    usage: "openai:gpt-4o-mini",
    context_append: "openai:gpt-4o-mini",
    tool_multi: "openai:gpt-4o-mini",
    tool_round_trip: "openai:gpt-4o-mini",
    tool_none: "openai:gpt-4o-mini",
    object_basic: "openai:gpt-4o-mini",
    object_streaming: "openai:gpt-4o-mini",
    reasoning: "anthropic:claude-haiku-4-5-20251001"
  }

  @provider_slices [
    {"anthropic:claude-haiku-4-5-20251001", [:object_basic, :object_streaming, :reasoning]},
    {"google:gemini-2.5-flash", [:object_streaming, :reasoning]},
    {"xai:grok-4.3", [:object_basic, :object_streaming, :reasoning]}
  ]

  setup do
    previous_mode = System.get_env("REQ_LLM_FIXTURES_MODE")
    System.put_env("REQ_LLM_FIXTURES_MODE", "replay")

    on_exit(fn ->
      case previous_mode do
        nil -> System.delete_env("REQ_LLM_FIXTURES_MODE")
        value -> System.put_env("REQ_LLM_FIXTURES_MODE", value)
      end
    end)

    :ok
  end

  test "scenario ids map to exact replay fixture names" do
    actual =
      Scenarios.all()
      |> Map.new(fn scenario -> {scenario.id(), scenario.fixtures(:model)} end)

    assert actual == @expected_fixtures
  end

  test "each comprehensive scenario resolves to existing replay fixtures" do
    for {scenario_id, spec} <- @scenario_specs do
      {:ok, model} = ReqLLM.model(spec)
      {:ok, scenario} = Scenarios.get(scenario_id)

      for fixture <- scenario.fixtures(model) do
        path = FixturePath.file(model, fixture)

        assert File.exists?(path),
               "Expected fixture for #{spec} #{scenario.id()} #{fixture} at #{path}"
      end
    end
  end

  test "representative provider slices resolve to existing replay fixtures" do
    for {spec, scenario_ids} <- @provider_slices do
      {:ok, model} = ReqLLM.model(spec)

      for scenario_id <- scenario_ids do
        {:ok, scenario} = Scenarios.get(scenario_id)

        for fixture <- scenario.fixtures(model) do
          path = FixturePath.file(model, fixture)

          assert File.exists?(path),
                 "Expected fixture for #{spec} #{scenario.id()} #{fixture} at #{path}"
        end
      end
    end
  end

  test "fixture paths keep provider model slug and fixture basename stable" do
    assert FixturePath.file("openai:gpt-4o-mini", "basic") ==
             Path.expand("test/support/fixtures/openai/gpt_4o_mini/basic.json")

    assert FixturePath.file("anthropic:claude-haiku-4-5-20251001", "reasoning_streaming") ==
             Path.expand(
               "test/support/fixtures/anthropic/claude_haiku_4_5_20251001/reasoning_streaming.json"
             )
  end

  test "missing replay fixtures fail with record-mode guidance" do
    {:ok, model} = ReqLLM.model("openai:gpt-4o-mini")

    assert_raise RuntimeError,
                 ~r/Fixture not found: .*missing_guardrail_fixture.*REQ_LLM_FIXTURES_MODE=record/s,
                 fn ->
                   Fixtures.replay_path(model, fixture: "missing_guardrail_fixture")
                 end
  end
end

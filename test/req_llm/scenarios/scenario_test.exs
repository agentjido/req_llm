defmodule ReqLLM.Test.ScenarioTest do
  use ExUnit.Case, async: true

  defmodule AlwaysScenario do
    use ReqLLM.Test.Scenario,
      id: :always,
      name: "always",
      description: "always applies"

    @impl ReqLLM.Test.Scenario
    def run(_model_spec, _model, _opts) do
      Scenario.ok(__MODULE__, [Scenario.step(:request, "always")], %{checked: true})
    end
  end

  defmodule NeverScenario do
    use ReqLLM.Test.Scenario,
      id: :never,
      name: "never",
      description: "never applies"

    @impl ReqLLM.Test.Scenario
    def applies?(_model), do: false

    @impl ReqLLM.Test.Scenario
    def run(_model_spec, _model, _opts), do: Scenario.ok(__MODULE__)
  end

  alias ReqLLM.Test.Scenario
  alias ReqLLM.Test.Scenarios

  test "scenario metadata and default fixture naming are deterministic" do
    assert AlwaysScenario.id() == :always
    assert AlwaysScenario.name() == "always"
    assert AlwaysScenario.description() == "always applies"
    assert AlwaysScenario.fixtures(:model) == ["always"]
    assert Scenario.fixture_name(:token_limit) == "token_limit"
  end

  test "result maps include scenario id, status, steps, error, and metadata" do
    result =
      AlwaysScenario.run(
        "openai:gpt-4o-mini",
        %LLMDB.Model{provider: :openai, id: "gpt-4o-mini"},
        provider: :openai
      )

    assert %{
             id: :always,
             status: :ok,
             steps: [%{id: :request, fixture: "always", metadata: %{}}],
             error: nil,
             metadata: %{checked: true}
           } = result
  end

  test "registry filters by applies?/1 and exposes ids" do
    modules = [AlwaysScenario, NeverScenario]

    assert Scenarios.ids(modules) == [:always, :never]
    assert Scenarios.get("always", modules) == {:ok, AlwaysScenario}
    assert Scenarios.get(:missing, modules) == :error
    assert Scenarios.for_model(:model, modules) == [AlwaysScenario]
    assert Scenarios.fixture_manifest(:model, modules) == %{always: ["always"]}
  end
end

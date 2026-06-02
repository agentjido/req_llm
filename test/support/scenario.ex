defmodule ReqLLM.Test.Scenario do
  @moduledoc """
  Contract for reusable provider coverage scenarios.

  Scenarios describe one fixture-backed behavior check and can be run by the
  comprehensive coverage macro, model compatibility tooling, or focused tests.
  """

  @type step :: %{
          required(:id) => atom(),
          required(:fixture) => binary() | nil,
          optional(:metadata) => map()
        }

  @type result :: %{
          required(:id) => atom(),
          required(:status) => :ok | :error,
          required(:steps) => [step()],
          required(:error) => term() | nil,
          required(:metadata) => map()
        }

  @callback id() :: atom()
  @callback name() :: binary()
  @callback description() :: binary()
  @callback applies?(binary() | LLMDB.Model.t()) :: boolean()
  @callback fixtures(binary() | LLMDB.Model.t()) :: [binary()]
  @callback run(binary(), LLMDB.Model.t(), keyword()) :: result()

  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)
    name = Keyword.fetch!(opts, :name)
    description = Keyword.get(opts, :description, name)

    quote bind_quoted: [id: id, name: name, description: description] do
      @behaviour ReqLLM.Test.Scenario

      import ExUnit.Assertions
      import ReqLLM.Context
      import ReqLLM.Debug, only: [dbug: 2]
      import ReqLLM.Test.Helpers

      alias ReqLLM.Test.Scenario

      @scenario_id id
      @scenario_name name
      @scenario_description description

      @impl ReqLLM.Test.Scenario
      def id, do: @scenario_id

      @impl ReqLLM.Test.Scenario
      def name, do: @scenario_name

      @impl ReqLLM.Test.Scenario
      def description, do: @scenario_description

      @impl ReqLLM.Test.Scenario
      def applies?(_model), do: true

      @impl ReqLLM.Test.Scenario
      def fixtures(_model), do: [Scenario.fixture_name(@scenario_id)]

      defoverridable applies?: 1, fixtures: 1
    end
  end

  @spec fixture_name(atom() | binary()) :: binary()
  def fixture_name(id) when is_atom(id), do: Atom.to_string(id)
  def fixture_name(id) when is_binary(id), do: id

  @spec step(atom(), binary() | nil, map()) :: step()
  def step(id, fixture, metadata \\ %{}) when is_atom(id) and is_map(metadata) do
    %{id: id, fixture: fixture, metadata: metadata}
  end

  @spec ok(module() | atom(), [step()], map()) :: result()
  def ok(scenario, steps \\ [], metadata \\ %{}) when is_list(steps) and is_map(metadata) do
    %{id: scenario_id(scenario), status: :ok, steps: steps, error: nil, metadata: metadata}
  end

  @spec error(module() | atom(), [step()], term(), map()) :: result()
  def error(scenario, steps, error, metadata \\ %{})
      when is_list(steps) and is_map(metadata) do
    %{id: scenario_id(scenario), status: :error, steps: steps, error: error, metadata: metadata}
  end

  @spec execute(module(), binary(), keyword()) :: result()
  def execute(scenario, model_spec, opts \\ [])
      when is_atom(scenario) and is_binary(model_spec) do
    with {:ok, model} <- ReqLLM.model(model_spec) do
      scenario
      |> run_scenario(model_spec, model, opts)
      |> normalize_result(scenario)
    else
      {:error, reason} ->
        error(scenario, [], %{kind: :error, reason: reason, stacktrace: []})
    end
  end

  @spec assert_result!(result()) :: result()
  def assert_result!(%{status: :ok} = result), do: result

  def assert_result!(%{
        status: :error,
        error: %{kind: :error, reason: exception, stacktrace: stacktrace}
      })
      when is_exception(exception) and is_list(stacktrace) do
    reraise exception, stacktrace
  end

  def assert_result!(%{status: :error} = result) do
    ExUnit.Assertions.flunk("Scenario #{inspect(result.id)} failed: #{inspect(result.error)}")
  end

  defp run_scenario(scenario, model_spec, model, opts) do
    scenario.run(model_spec, model, opts)
  rescue
    exception ->
      error(scenario, [], %{kind: :error, reason: exception, stacktrace: __STACKTRACE__})
  catch
    kind, reason ->
      error(scenario, [], %{kind: kind, reason: reason, stacktrace: __STACKTRACE__})
  end

  defp normalize_result(%{status: status} = result, scenario) when status in [:ok, :error] do
    result
    |> Map.put_new(:id, scenario_id(scenario))
    |> Map.put_new(:steps, [])
    |> Map.put_new(:error, nil)
    |> Map.put_new(:metadata, %{})
  end

  defp normalize_result(:ok, scenario), do: ok(scenario)

  defp normalize_result(other, scenario) do
    error(scenario, [], %{kind: :invalid_result, reason: other})
  end

  defp scenario_id(scenario) when is_atom(scenario) do
    if function_exported?(scenario, :id, 0) do
      scenario.id()
    else
      scenario
    end
  end
end

defmodule ReqLLM.ProviderTest.Comprehensive do
  @moduledoc """
  Comprehensive per-model provider tests.

  Consolidates all provider capability testing into up to 9 focused tests per model:
  1. Basic generate_text (non-streaming)
  2. Streaming with system context + creative params
  3. Token limit constraints
  4. Usage metrics and cost calculations
  5. Tool calling - multi-tool selection
  6. Tool calling - no tool when inappropriate
  7. Object generation (non-streaming) - only for models with object generation support
  8. Object generation (streaming) - only for models with object generation support
  9. Reasoning/thinking tokens - only for models with :reasoning capability

  Tests use fixtures for fast, deterministic execution while supporting
  live API recording with REQ_LLM_FIXTURES_MODE=record.

  ## Usage

      defmodule ReqLLM.Coverage.Anthropic.ComprehensiveTest do
        use ReqLLM.ProviderTest.Comprehensive, provider: :anthropic
      end

  This will generate all tests for models selected by ModelMatrix for the provider.

  ## Debug Output

  Set REQ_LLM_DEBUG=1 to enable verbose fixture output during test runs.
  """

  def supports_object_generation?(model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, model} ->
        object_generation_supported?(model)

      {:error, _} ->
        false
    end
  end

  def supports_streaming_object_generation?(model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, model} ->
        caps = model.capabilities || %{}

        # Must support object generation AND streaming tool calls
        supports_object = supports_object_generation?(model_spec)
        supports_streaming = get_in(caps, [:streaming, :tool_calls]) != false

        supports_object && supports_streaming

      {:error, _} ->
        false
    end
  end

  def supports_tool_calling?(model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, model} -> get_in(model.capabilities, [:tools, :enabled]) == true
      {:error, _} -> false
    end
  end

  def supports_reasoning?(model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, model} -> get_in(model.capabilities, [:reasoning, :enabled]) == true
      {:error, _} -> false
    end
  end

  def supports_forced_tool_choice?(model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, model} -> get_in(model.capabilities, [:tools, :forced_choice]) != false
      {:error, _} -> true
    end
  end

  defp object_generation_supported?(%LLMDB.Model{} = model) do
    structured_outputs_supported?(model) and
      (execution_object_supported?(model) or
         json_output_supported?(model) or
         strict_tool_output_supported?(model) or
         tool_workaround_supported?(model))
  end

  defp execution_object_supported?(%LLMDB.Model{execution: execution}) when is_map(execution) do
    execution
    |> map_value(:object)
    |> supported_entry?()
  end

  defp execution_object_supported?(_model), do: false

  defp json_output_supported?(%LLMDB.Model{capabilities: capabilities}) do
    capability_enabled?(capabilities, [:json, :native]) or
      capability_enabled?(capabilities, [:json, :schema])
  end

  defp strict_tool_output_supported?(%LLMDB.Model{capabilities: capabilities}) do
    capability_enabled?(capabilities, [:tools, :strict])
  end

  defp tool_workaround_supported?(%LLMDB.Model{provider: :anthropic}), do: false

  defp tool_workaround_supported?(%LLMDB.Model{capabilities: capabilities}) do
    capability_enabled?(capabilities, [:tools, :enabled])
  end

  defp structured_outputs_supported?(%LLMDB.Model{provider: :anthropic, extra: extra}) do
    cond do
      get_in(extra || %{}, [:provider_capabilities, :structured_outputs, :supported]) == false ->
        false

      get_in(extra || %{}, [:capabilities, :structured_outputs, :supported]) == false ->
        false

      true ->
        true
    end
  end

  defp structured_outputs_supported?(_model), do: true

  defp capability_enabled?(capabilities, path) do
    capabilities
    |> path_value(path)
    |> enabled_value?()
  end

  defp supported_entry?(entry) when is_map(entry),
    do: enabled_value?(map_value(entry, :supported))

  defp supported_entry?(_entry), do: false

  defp enabled_value?(true), do: true
  defp enabled_value?(_value), do: false

  defp path_value(value, []), do: value

  defp path_value(value, [key | rest]) when is_map(value) do
    value
    |> map_value(key)
    |> path_value(rest)
  end

  defp path_value(_value, _path), do: nil

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote bind_quoted: [provider: provider] do
      use ExUnit.Case, async: false

      import ExUnit.Case
      import ReqLLM.Context
      import ReqLLM.Debug, only: [dbug: 2]
      import ReqLLM.Test.Helpers

      alias ReqLLM.Test.ModelMatrix

      @moduletag :coverage
      @moduletag provider: to_string(provider)
      @moduletag timeout: 300_000

      @provider provider
      @models ModelMatrix.models_for_provider(provider, operation: :text)

      setup_all do
        LLMDB.load(allow: :all, custom: %{})
        :ok
      end

      for model_spec <- @models do
        @model_spec model_spec

        describe "#{model_spec}" do
          @describetag model: model_spec |> String.split(":", parts: 2) |> List.last()

          @tag scenario: :basic
          test "basic generate_text (non-streaming)" do
            ReqLLM.Test.Scenario.execute(
              ReqLLM.Test.Scenarios.Basic,
              @model_spec,
              provider: @provider
            )
            |> ReqLLM.Test.Scenario.assert_result!()
          end

          @tag scenario: :streaming
          test "stream_text with system context and creative params" do
            ReqLLM.Test.Scenario.execute(
              ReqLLM.Test.Scenarios.Streaming,
              @model_spec,
              provider: @provider
            )
            |> ReqLLM.Test.Scenario.assert_result!()
          end

          @tag scenario: :token_limit
          @tag timeout: 600_000
          test "token limit constraints" do
            ReqLLM.Test.Scenario.execute(
              ReqLLM.Test.Scenarios.TokenLimit,
              @model_spec,
              provider: @provider
            )
            |> ReqLLM.Test.Scenario.assert_result!()
          end

          @tag scenario: :usage
          test "usage metrics and cost calculations" do
            ReqLLM.Test.Scenario.execute(
              ReqLLM.Test.Scenarios.Usage,
              @model_spec,
              provider: @provider
            )
            |> ReqLLM.Test.Scenario.assert_result!()
          end

          @tag scenario: :context_append
          test "context append continues conversation" do
            ReqLLM.Test.Scenario.execute(
              ReqLLM.Test.Scenarios.ContextAppend,
              @model_spec,
              provider: @provider
            )
            |> ReqLLM.Test.Scenario.assert_result!()
          end

          if ReqLLM.ProviderTest.Comprehensive.supports_tool_calling?(model_spec) do
            @tag scenario: :tool_multi
            test "tool calling - multi-tool selection" do
              ReqLLM.Test.Scenario.execute(
                ReqLLM.Test.Scenarios.ToolMulti,
                @model_spec,
                provider: @provider
              )
              |> ReqLLM.Test.Scenario.assert_result!()
            end

            @tag scenario: :tool_round_trip
            test "tool calling - round trip execution" do
              ReqLLM.Test.Scenario.execute(
                ReqLLM.Test.Scenarios.ToolRoundTrip,
                @model_spec,
                provider: @provider
              )
              |> ReqLLM.Test.Scenario.assert_result!()
            end

            @tag scenario: :tool_none
            test "tool calling - no tool when inappropriate" do
              ReqLLM.Test.Scenario.execute(
                ReqLLM.Test.Scenarios.ToolNone,
                @model_spec,
                provider: @provider
              )
              |> ReqLLM.Test.Scenario.assert_result!()
            end
          end

          if ReqLLM.ProviderTest.Comprehensive.supports_object_generation?(model_spec) do
            @tag scenario: :object_basic
            test "object generation (non-streaming)" do
              ReqLLM.Test.Scenario.execute(
                ReqLLM.Test.Scenarios.ObjectBasic,
                @model_spec,
                provider: @provider
              )
              |> ReqLLM.Test.Scenario.assert_result!()
            end
          end

          if ReqLLM.ProviderTest.Comprehensive.supports_streaming_object_generation?(model_spec) do
            @tag scenario: :object_streaming
            test "object generation (streaming)" do
              ReqLLM.Test.Scenario.execute(
                ReqLLM.Test.Scenarios.ObjectStreaming,
                @model_spec,
                provider: @provider
              )
              |> ReqLLM.Test.Scenario.assert_result!()
            end
          end

          if ReqLLM.ProviderTest.Comprehensive.supports_reasoning?(model_spec) do
            @tag scenario: :reasoning
            test "reasoning/thinking tokens (non-streaming + streaming)" do
              ReqLLM.Test.Scenario.execute(
                ReqLLM.Test.Scenarios.Reasoning,
                @model_spec,
                provider: @provider
              )
              |> ReqLLM.Test.Scenario.assert_result!()
            end
          end
        end
      end
    end
  end
end

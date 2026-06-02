defmodule ReqLLM.Test.Scenarios.Assertions do
  @moduledoc """
  Assertions shared by provider coverage scenarios.
  """

  import ExUnit.Assertions

  def assert_usage_cost_fields(usage, required?) do
    present? =
      Enum.any?([:input_cost, :output_cost, :total_cost], &Map.has_key?(usage, &1))

    if required? or present? do
      assert is_number(usage.input_cost) and usage.input_cost >= 0

      assert is_number(usage.output_cost) and
               usage.output_cost >= 0

      assert is_number(usage.total_cost) and usage.total_cost >= 0

      expected = usage.input_cost + usage.output_cost
      assert abs(usage.total_cost - expected) < 0.00001
    end
  end

  def assert_streaming_usage(nil), do: :ok

  def assert_streaming_usage(usage) when is_map(usage) do
    assert is_number(usage.input_tokens) and usage.input_tokens > 0
    assert is_number(usage.output_tokens) and usage.output_tokens >= 0
    assert is_number(usage.total_tokens) and usage.total_tokens > 0
    assert is_number(usage.cached_input) and usage.cached_input >= 0
    assert is_number(usage.reasoning) and usage.reasoning >= 0
  end

  def assert_streaming_usage(usage) do
    flunk("Expected usage map or nil, got: #{inspect(usage)}")
  end
end

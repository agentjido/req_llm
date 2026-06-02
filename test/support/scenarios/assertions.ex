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

  def assert_profile_object_or_reasoning(response) do
    object = ReqLLM.Response.object(response)
    rt = ReqLLM.Response.reasoning_tokens(response)

    cond do
      is_map(object) and map_size(object) > 0 ->
        assert Map.has_key?(object, "name")
        assert Map.has_key?(object, "age")
        assert is_binary(object["name"])
        assert object["name"] != ""
        assert is_integer(object["age"])
        assert object["age"] > 0

      response.finish_reason == :length ->
        assert is_number(rt) and rt >= 0

      is_number(rt) and rt > 0 ->
        :ok

      is_map(object) ->
        :ok

      true ->
        flunk("Expected object or reasoning tokens but got: #{inspect(object)}")
    end
  end

  def assert_reasoning_details_if_present(%ReqLLM.Message{reasoning_details: nil}), do: :ok
  def assert_reasoning_details_if_present(%ReqLLM.Message{reasoning_details: []}), do: :ok

  def assert_reasoning_details_if_present(%ReqLLM.Message{reasoning_details: details})
      when is_list(details) do
    for {detail, idx} <- Enum.with_index(details) do
      assert %ReqLLM.Message.ReasoningDetails{} = detail,
             "reasoning_details[#{idx}] should be a ReasoningDetails struct, got: #{inspect(detail)}"

      assert is_atom(detail.provider) and not is_nil(detail.provider),
             "reasoning_details[#{idx}].provider should be a provider atom, got: #{inspect(detail.provider)}"

      assert is_binary(detail.format) and detail.format != "",
             "reasoning_details[#{idx}].format should be a non-empty string, got: #{inspect(detail.format)}"

      assert is_integer(detail.index) and detail.index >= 0,
             "reasoning_details[#{idx}].index should be a non-negative integer, got: #{inspect(detail.index)}"

      assert is_boolean(detail.encrypted?),
             "reasoning_details[#{idx}].encrypted? should be a boolean, got: #{inspect(detail.encrypted?)}"
    end

    :ok
  end
end

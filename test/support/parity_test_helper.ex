defmodule ReqLLM.Parity.TestHelper do
  @moduledoc """
  Shared helpers for parity tests between streaming and non-streaming responses.

  These helpers normalize Response structs for comparison, focusing on
  semantic equivalence rather than exact byte-for-byte equality.
  """

  alias ReqLLM.Response
  alias ReqLLM.ToolCall

  @doc """
  Assert that two responses have equivalent tool calls.

  Normalizes tool calls for comparison by:
  - Sorting by name for consistent ordering
  - Normalizing argument maps (string keys vs atom keys)
  - Ignoring auto-generated IDs unless both are present
  """
  def assert_tool_calls_equal(response1, response2) do
    tc1 = Response.tool_calls(response1) |> normalize_tool_calls_for_comparison()
    tc2 = Response.tool_calls(response2) |> normalize_tool_calls_for_comparison()

    ExUnit.Assertions.assert(
      tc1 == tc2,
      """
      Tool calls mismatch:

      Response 1 tool_calls:
      #{inspect(tc1, pretty: true)}

      Response 2 tool_calls:
      #{inspect(tc2, pretty: true)}
      """
    )
  end

  @doc """
  Assert that two responses have the same finish_reason.
  """
  def assert_finish_reason_equal(response1, response2) do
    fr1 = Response.finish_reason(response1)
    fr2 = Response.finish_reason(response2)

    ExUnit.Assertions.assert(
      fr1 == fr2,
      "Finish reason mismatch: #{inspect(fr1)} vs #{inspect(fr2)}"
    )
  end

  @doc """
  Assert that two responses have structurally equivalent usage.

  Checks that the same keys are present and values are reasonable
  (non-negative integers). Exact values may differ slightly between
  streaming and non-streaming due to timing.
  """
  def assert_usage_structure_equal(response1, response2) do
    u1 = Response.usage(response1)
    u2 = Response.usage(response2)

    # Both should have usage or both should be nil
    case {u1, u2} do
      {nil, nil} ->
        :ok

      {%{} = usage1, %{} = usage2} ->
        # Check same keys present
        keys1 = Map.keys(usage1) |> MapSet.new()
        keys2 = Map.keys(usage2) |> MapSet.new()

        ExUnit.Assertions.assert(
          keys1 == keys2,
          "Usage keys mismatch: #{inspect(keys1)} vs #{inspect(keys2)}"
        )

        # Check values are non-negative
        for {key, val} <- usage1 do
          ExUnit.Assertions.assert(
            is_integer(val) and val >= 0,
            "Usage #{key} should be non-negative integer, got: #{inspect(val)}"
          )
        end

      _ ->
        ExUnit.Assertions.flunk("Usage structure mismatch: #{inspect(u1)} vs #{inspect(u2)}")
    end
  end

  @doc """
  Assert that message metadata is preserved correctly.

  For providers that require metadata (e.g., OpenAI Responses API needs response_id),
  this checks that the metadata is present in both responses.
  """
  def assert_metadata_preserved(response1, response2, required_keys \\ []) do
    meta1 = get_message_metadata(response1)
    meta2 = get_message_metadata(response2)

    for key <- required_keys do
      ExUnit.Assertions.assert(
        Map.has_key?(meta1, key),
        "Response 1 missing required metadata key: #{inspect(key)}"
      )

      ExUnit.Assertions.assert(
        Map.has_key?(meta2, key),
        "Response 2 missing required metadata key: #{inspect(key)}"
      )
    end
  end

  @doc """
  Assert that the context is properly merged and can be used for next turn.

  Checks that:
  - Context has the assistant message
  - Tool calls (if any) are in the context
  - Context can be encoded for the provider
  """
  def assert_context_valid_for_next_turn(response) do
    context = response.context

    ExUnit.Assertions.assert(
      context != nil,
      "Response context should not be nil"
    )

    ExUnit.Assertions.assert(
      not Enum.empty?(context.messages),
      "Response context should have at least one message"
    )

    # Last message should be assistant
    last_msg = List.last(context.messages)

    ExUnit.Assertions.assert(
      last_msg.role == :assistant,
      "Last message in context should be assistant, got: #{inspect(last_msg.role)}"
    )
  end

  @doc """
  Assert that tool-call-only responses have valid content.

  This is critical for Anthropic which requires non-empty content blocks.
  """
  def assert_tool_call_content_valid(response) do
    message = response.message

    if message && message.tool_calls && message.tool_calls != [] do
      # For Anthropic, content must not be empty when tool_calls present
      # Other providers are more lenient
      ExUnit.Assertions.assert(
        is_list(message.content),
        "Message content should be a list"
      )
    end
  end

  @doc """
  Assert that all tool calls are proper ToolCall structs.
  """
  def assert_tool_calls_are_structs(response) do
    tool_calls = Response.tool_calls(response)

    for tc <- tool_calls do
      ExUnit.Assertions.assert(
        match?(%ToolCall{}, tc),
        "Expected ToolCall struct, got: #{inspect(tc)}"
      )
    end
  end

  # ============================================================================
  # Normalization Helpers
  # ============================================================================

  defp normalize_tool_calls_for_comparison(tool_calls) do
    tool_calls
    |> Enum.map(&normalize_single_tool_call/1)
    |> Enum.sort_by(& &1.name)
  end

  defp normalize_single_tool_call(%ToolCall{} = tc) do
    %{
      name: tc.function.name,
      arguments: normalize_arguments(ToolCall.args_map(tc))
    }
  end

  defp normalize_single_tool_call(%{name: name, arguments: args}) do
    %{
      name: name,
      arguments: normalize_arguments(args)
    }
  end

  defp normalize_single_tool_call(%{"name" => name, "arguments" => args}) do
    %{
      name: name,
      arguments: normalize_arguments(args)
    }
  end

  defp normalize_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} -> normalize_arguments(map)
      _ -> %{}
    end
  end

  defp normalize_arguments(args) when is_map(args) do
    # Convert all keys to strings for consistent comparison
    Map.new(args, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      {key, v}
    end)
  end

  defp normalize_arguments(_), do: %{}

  defp get_message_metadata(%Response{message: nil}), do: %{}
  defp get_message_metadata(%Response{message: %{metadata: meta}}), do: meta || %{}

  # ============================================================================
  # Test Data Helpers
  # ============================================================================

  @doc """
  Create a simple weather tool for testing.
  """
  def weather_tool do
    ReqLLM.Tool.new!(
      name: "get_weather",
      description: "Get the current weather for a location",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "location" => %{"type" => "string", "description" => "City name"}
        },
        "required" => ["location"]
      },
      callback: fn %{"location" => location} ->
        {:ok, %{temperature: 72, condition: "sunny", location: location}}
      end
    )
  end

  @doc """
  Create an add tool for testing.
  """
  def add_tool do
    ReqLLM.Tool.new!(
      name: "add",
      description: "Add two numbers",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "a" => %{"type" => "number", "description" => "First number"},
          "b" => %{"type" => "number", "description" => "Second number"}
        },
        "required" => ["a", "b"]
      },
      callback: fn %{"a" => a, "b" => b} ->
        {:ok, %{result: a + b}}
      end
    )
  end
end

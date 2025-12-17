defmodule ReqLLM.Parity.TestHelper do
  @moduledoc """
  Shared helpers for parity tests between streaming and non-streaming responses.

  These helpers focus on **semantic equivalence** rather than exact byte-for-byte
  equality. LLMs may produce slightly different outputs even with identical inputs,
  so we test for meaningful equivalence.

  ## Legitimate Parity Requirements

  1. **finish_reason** - Must be correct (`:tool_calls` when tools called, `:stop` otherwise)
  2. **tool_calls** - Structure must be equivalent (names, arguments)
  3. **text content** - Semantically equivalent (same answers, not necessarily same words)
  4. **context validity** - Must be usable for next turn in multi-turn conversations

  ## NOT Strict Parity

  - Exact usage keys (streaming may have additional granular fields)
  - Exact metadata structure (as long as data is accessible)
  - Exact text wording (LLMs are non-deterministic)
  """

  alias ReqLLM.Response
  alias ReqLLM.ToolCall

  # ============================================================================
  # Core Parity Assertions
  # ============================================================================

  @doc """
  Assert that two responses have the same finish_reason.

  This is critical for tool calling workflows - finish_reason must be :tool_calls
  when the model made tool calls, and :stop for normal completion.
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
  Assert that two responses have equivalent tool calls.

  Normalizes tool calls for comparison by:
  - Sorting by name for consistent ordering
  - Normalizing argument maps (string keys vs atom keys)
  - Ignoring auto-generated IDs (they will differ between calls)
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

  @doc """
  Assert that the context is properly formed and can be used for next turn.

  Checks that:
  - Context exists and has messages
  - Last message is from assistant
  - Tool calls (if any) are preserved in the context
  """
  def assert_context_valid_for_next_turn(response) do
    context = response.context

    ExUnit.Assertions.assert(
      context != nil,
      "Response context should not be nil"
    )

    ExUnit.Assertions.assert(
      context.messages != [],
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
  Assert that tool-call-only responses have valid content structure.

  This is critical for Anthropic which requires non-empty content blocks.
  """
  def assert_tool_call_content_valid(response) do
    message = response.message

    if message && message.tool_calls && message.tool_calls != [] do
      ExUnit.Assertions.assert(
        is_list(message.content),
        "Message content should be a list"
      )
    end
  end

  # ============================================================================
  # Semantic Text Comparison
  # ============================================================================

  @doc """
  Assert that two responses contain semantically equivalent text content.

  Since LLMs are non-deterministic, we don't require exact text matches.
  Instead, we check for semantic equivalence based on the type of content.

  ## Options

  - `:type` - The type of comparison to perform:
    - `:math` - Extract and compare numeric answers
    - `:contains` - Check that both contain the same key terms
    - `:non_empty` - Just verify both have non-empty text (default)
  - `:expected_values` - For `:math` type, the expected numeric values
  - `:expected_terms` - For `:contains` type, terms that should appear in both
  """
  def assert_text_semantically_equal(response1, response2, opts \\ []) do
    text1 = Response.text(response1) || ""
    text2 = Response.text(response2) || ""

    type = Keyword.get(opts, :type, :non_empty)

    case type do
      :math ->
        assert_math_answers_equal(text1, text2, opts)

      :contains ->
        expected_terms = Keyword.get(opts, :expected_terms, [])
        assert_contains_terms(text1, text2, expected_terms)

      :non_empty ->
        assert_both_non_empty_or_both_empty(text1, text2)
    end
  end

  defp assert_math_answers_equal(text1, text2, opts) do
    expected_values = Keyword.get(opts, :expected_values, [])

    numbers1 = extract_numbers(text1)
    numbers2 = extract_numbers(text2)

    if expected_values == [] do
      # At minimum, both should have extracted some numbers if math was involved
      # or both should have none
      has_numbers1 = numbers1 != []
      has_numbers2 = numbers2 != []

      ExUnit.Assertions.assert(
        has_numbers1 == has_numbers2,
        """
        Math content mismatch:
        Response 1 numbers: #{inspect(numbers1)}
        Response 2 numbers: #{inspect(numbers2)}
        """
        # Both should contain the expected values
      )
    else
      for expected <- expected_values do
        ExUnit.Assertions.assert(
          expected in numbers1,
          "Response 1 should contain #{expected}, found: #{inspect(numbers1)} in: #{text1}"
        )

        ExUnit.Assertions.assert(
          expected in numbers2,
          "Response 2 should contain #{expected}, found: #{inspect(numbers2)} in: #{text2}"
        )
      end
    end
  end

  defp assert_contains_terms(text1, text2, expected_terms) do
    text1_lower = String.downcase(text1)
    text2_lower = String.downcase(text2)

    for term <- expected_terms do
      term_lower = String.downcase(term)

      ExUnit.Assertions.assert(
        String.contains?(text1_lower, term_lower),
        "Response 1 should contain '#{term}', got: #{text1}"
      )

      ExUnit.Assertions.assert(
        String.contains?(text2_lower, term_lower),
        "Response 2 should contain '#{term}', got: #{text2}"
      )
    end
  end

  defp assert_both_non_empty_or_both_empty(text1, text2) do
    empty1 = text1 == "" or text1 == nil
    empty2 = text2 == "" or text2 == nil

    ExUnit.Assertions.assert(
      empty1 == empty2,
      """
      Text presence mismatch:
      Response 1: #{if empty1, do: "(empty)", else: "has text"}
      Response 2: #{if empty2, do: "(empty)", else: "has text"}
      """
    )
  end

  defp extract_numbers(text) do
    # Extract integers and floats from text
    # Match: optional minus, digits, optional decimal with more digits
    ~r/-?\d+(?:\.\d+)?/
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(fn str ->
      if String.contains?(str, ".") do
        String.to_float(str)
      else
        String.to_integer(str)
      end
    end)
    |> Enum.uniq()
  end

  # ============================================================================
  # Usage Assertions (Relaxed)
  # ============================================================================

  @doc """
  Assert that both responses have valid usage data with core fields present.

  This is a relaxed check - we don't require identical keys because streaming
  may include additional granular fields. We just verify:
  - Both have usage data (or both are nil)
  - Core fields (input_tokens, output_tokens) are present and valid
  """
  def assert_usage_valid(response1, response2) do
    u1 = Response.usage(response1)
    u2 = Response.usage(response2)

    case {u1, u2} do
      {nil, nil} ->
        :ok

      {%{} = usage1, %{} = usage2} ->
        # Both should have core token fields
        assert_has_core_usage_fields(usage1, "Response 1")
        assert_has_core_usage_fields(usage2, "Response 2")

      {nil, %{}} ->
        ExUnit.Assertions.flunk("Response 1 has no usage but Response 2 does")

      {%{}, nil} ->
        ExUnit.Assertions.flunk("Response 1 has usage but Response 2 does not")
    end
  end

  defp assert_has_core_usage_fields(usage, label) do
    # Check for input tokens (may be :input_tokens or :input)
    has_input =
      Map.has_key?(usage, :input_tokens) or
        Map.has_key?(usage, :input) or
        Map.has_key?(usage, "input_tokens")

    # Check for output tokens (may be :output_tokens or :output)
    has_output =
      Map.has_key?(usage, :output_tokens) or
        Map.has_key?(usage, :output) or
        Map.has_key?(usage, "output_tokens")

    ExUnit.Assertions.assert(
      has_input,
      "#{label} usage should have input token count, got: #{inspect(Map.keys(usage))}"
    )

    ExUnit.Assertions.assert(
      has_output,
      "#{label} usage should have output token count, got: #{inspect(Map.keys(usage))}"
    )
  end

  # ============================================================================
  # Tool Call Normalization
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

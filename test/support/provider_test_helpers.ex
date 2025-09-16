defmodule ReqLLM.ProviderTestHelpers do
  @moduledoc """
  Common test helpers for provider coverage tests.

  Provides assertion helpers and utilities to reduce duplication
  across provider test suites.
  """

  import ExUnit.Assertions

  @doc """
  Assert that a response has the expected basic structure and content.

  Returns the response for further chaining.
  """
  def assert_basic_response({:ok, %ReqLLM.Response{} = response}) do
    # Basic response structure
    assert response.id != nil
    assert is_binary(response.id)

    # Text content validation - tool calling responses may have empty text
    text = ReqLLM.Response.text(response)
    assert is_binary(text)

    # For responses with tool calls, text may be empty
    if has_tool_calls?(response) do
      # Tool calling response - text can be empty
      :ok
    else
      # Regular text response - must have content
      assert String.length(text) > 0
    end

    response
  end

  def assert_basic_response(other) do
    flunk("Expected {:ok, %ReqLLM.Response{}}, got: #{inspect(other)}")
  end

  @doc """
  Build fixture options with provider-scoped naming and common defaults.
  """
  def fixture_opts(provider, name, extra_opts \\ []) do
    Keyword.put(extra_opts, :fixture, "#{provider}_#{name}")
  end

  @doc """
  Common parameter bundles for testing different scenarios.
  """
  def param_bundles do
    %{
      # Deterministic generation for reproducible tests
      deterministic: [temperature: 0.0, max_tokens: 10],

      # Short creative generation
      creative: [temperature: 0.8, max_tokens: 15],

      # Minimal token limit to test truncation
      minimal: [max_tokens: 5]
    }
  end

  @doc """
  Assert response text length is within expected bounds.
  """
  def assert_text_length(response, max_length) do
    text = ReqLLM.Response.text(response)
    actual_length = String.length(text)

    assert actual_length <= max_length,
           "Expected text length <= #{max_length}, got #{actual_length}: #{inspect(text)}"

    response
  end

  # Helper to check if response has tool calls
  defp has_tool_calls?(%ReqLLM.Response{message: message}) do
    Enum.any?(message.content || [], fn content ->
      content.type == :tool_call
    end)
  end
end

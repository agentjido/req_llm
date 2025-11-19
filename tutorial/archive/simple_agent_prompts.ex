defmodule SimpleAgent.Prompts do
  @moduledoc """
  Centralized system prompts for SimpleAgent tutorial examples.

  This module provides a single source of truth for system prompts used across
  all tutorial versions, ensuring consistency and making it easy to update
  guidance for the AI assistant.
  """

  @tool_prompt """
  You are a helpful assistant with access to tools.

  - When a user asks a math question or expression, use the calculator tool with the "expression" parameter.
  - Provide only valid JSON for tool arguments; do not add extra text in the arguments.
  - After tool results are provided, give a concise final answer.
  """

  @slow_tool_prompt """
  You are a helpful assistant with access to tools.

  - When a user asks a math question or expression, use the calculator tool with the "expression" parameter.
  - You can use slow_calculator for demonstration purposes.
  - Provide only valid JSON for tool arguments; do not add extra text in the arguments.
  - After tool results are provided, give a concise final answer.
  """

  @doc """
  Returns the standard tool-calling system prompt for single calculator tool examples.

  Used in: V2, V3, V4

  ## Examples

      iex> SimpleAgent.Prompts.tool_prompt()
      "You are a helpful assistant with access to tools.\\n..."
  """
  def tool_prompt, do: @tool_prompt

  @doc """
  Returns the system prompt for examples with multiple calculator tools (fast and slow).

  Used in: V5

  ## Examples

      iex> SimpleAgent.Prompts.slow_tool_prompt()
      "You are a helpful assistant with access to tools.\\n..."
  """
  def slow_tool_prompt, do: @slow_tool_prompt
end

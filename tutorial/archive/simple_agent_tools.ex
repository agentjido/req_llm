defmodule SimpleAgent.Tools do
  @moduledoc """
  Shared tool definitions for SimpleAgent tutorial examples.

  This module provides calculator tools that demonstrate ReqLLM's tool calling
  capabilities using safe mathematical expression evaluation via Abacus.

  ## Available Tools

  - `calculator_tool/0` - Fast calculator for basic mathematical expressions
  - `slow_calculator_tool/0` - Deliberately slow calculator for demonstrating parallel execution

  ## Usage

  ```elixir
  # In your Mix.install script:
  Code.require_file("simple_agent_tools.ex", __DIR__)

  # Get the tools:
  tools = [
    SimpleAgent.Tools.calculator_tool(),
    SimpleAgent.Tools.slow_calculator_tool()
  ]

  # Use in ReqLLM requests:
  ReqLLM.stream_text(model, messages, tools: tools)
  ```

  ## Safe Evaluation with Abacus

  All calculator tools use the Abacus library for safe mathematical expression
  evaluation. This prevents code injection and ensures only mathematical operations
  are executed. Abacus supports:

  - Basic operations: +, -, *, /
  - Exponentiation: ^ or **
  - Functions: sqrt, sin, cos, tan, log, abs, etc.
  - Parentheses for grouping

  ## Callback Parameter Formats

  Tool callbacks handle both atom-key and string-key maps to accommodate different
  LLM providers' JSON serialization conventions:

  - `%{expression: "2+2"}` - Atom keys (Elixir native)
  - `%{"expression" => "2+2"}` - String keys (JSON standard)

  This dual handling ensures compatibility across all supported LLM providers.
  """

  alias ReqLLM.Tool

  @doc """
  Creates a fast calculator tool for evaluating mathematical expressions.

  Returns a `ReqLLM.Tool` struct configured to safely evaluate mathematical
  expressions using Abacus.

  ## Examples

      iex> tool = SimpleAgent.Tools.calculator_tool()
      iex> ReqLLM.Tool.execute(tool, %{expression: "2 + 2"})
      {:ok, 4.0}

      iex> tool = SimpleAgent.Tools.calculator_tool()
      iex> ReqLLM.Tool.execute(tool, %{expression: "sqrt(144)"})
      {:ok, 12.0}
  """
  def calculator_tool do
    Tool.new!(
      name: "calculator",
      description:
        ~s|Safely evaluate a mathematical expression string. Example: {"expression":"(2+3)*7"}|,
      parameter_schema: [
        expression: [
          type: :string,
          required: true,
          doc: "Math expression to evaluate, e.g., \"(2+3)^2 / 5\""
        ]
      ],
      callback: &__MODULE__.calculator_cb/1
    )
  end

  @doc """
  Creates a deliberately slow calculator tool for demonstration purposes.

  This tool sleeps for 2 seconds before evaluating expressions. It's useful for
  demonstrating parallel tool execution (V5) where multiple tools can run
  concurrently, showing significant performance improvements over sequential execution.

  ## Examples

      iex> tool = SimpleAgent.Tools.slow_calculator_tool()
      iex> ReqLLM.Tool.execute(tool, %{expression: "10 * 5"})
      {:ok, 50.0}  # Takes ~2 seconds
  """
  def slow_calculator_tool do
    Tool.new!(
      name: "slow_calculator",
      description:
        ~s|A deliberately slow calculator that sleeps before evaluating. Example: {"expression":"(2+3)*7"}|,
      parameter_schema: [
        expression: [
          type: :string,
          required: true,
          doc: "Math expression to evaluate, e.g., \"(2+3)^2 / 5\""
        ]
      ],
      callback: &__MODULE__.slow_calculator_cb/1
    )
  end

  @doc false
  def calculator_cb(%{expression: expr}) when is_binary(expr), do: eval(expr)
  def calculator_cb(%{"expression" => expr}) when is_binary(expr), do: eval(expr)
  def calculator_cb(args), do: {:error, "Expected %{expression: string}. Got: #{inspect(args)}"}

  @doc false
  def slow_calculator_cb(args) do
    Process.sleep(2000)
    calculator_cb(args)
  end

  defp eval(expr) do
    case Abacus.eval(expr) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, "Invalid expression: #{Exception.message(reason)}"}
    end
  end
end

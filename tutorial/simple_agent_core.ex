defmodule SimpleAgent.Core do
  @moduledoc """
  Core helper module for shared tool-flow logic across SimpleAgent tutorial examples.

  This module extracts the common 3-phase pattern used in V2, V3, and V5:
  1. Stream model output to detect tool calls
  2. Execute tools and append tool results to history
  3. Call generate_text/3 to produce final answer

  By centralizing this logic, the tutorial code can focus on demonstrating
  architectural differences (synchronous vs {:continue} vs parallel execution)
  rather than repeating the same tool-calling mechanics.

  ## Usage

  ```elixir
  # In your Mix.install script:
  Code.require_file("simple_agent_core.ex", __DIR__)

  # Phase 1: Stream and detect tools
  {:ok, %{chunks: chunks, assistant_text: text, tool_calls: calls}} =
    SimpleAgent.Core.stream_with_tools(model, history, tools)

  # Phase 2: Execute tools sequentially
  history = SimpleAgent.Core.execute_tools_sequential(history, tools, calls)

  # Phase 3: Finalize
  {:ok, final_text} = SimpleAgent.Core.finalize(model, history)
  ```
  """

  alias ReqLLM.{Context, Tool}
  alias SimpleAgent.Parser
  import ReqLLM.Context

  @doc """
  Phase 1: Stream model response and detect tool calls.

  Streams the LLM response, printing content chunks to stdout as they arrive,
  then extracts both text content and any tool calls from the streaming chunks.

  ## Parameters

  - `model` - Model identifier (e.g., "anthropic:claude-3-5-sonnet-20241022")
  - `history` - ReqLLM.Context struct with conversation history
  - `tools` - List of ReqLLM.Tool structs
  - `opts` - Additional options passed to ReqLLM.stream_text/3

  ## Returns

  - `{:ok, map}` - Map with :chunks, :assistant_text, and :tool_calls
  - `{:error, reason}` - Stream error

  ## Examples

      {:ok, result} = SimpleAgent.Core.stream_with_tools(
        "anthropic:claude-3-5-sonnet-20241022",
        history,
        tools,
        temperature: 0.0
      )

      result.assistant_text  #=> "I'll help you calculate that..."
      result.tool_calls      #=> [%{id: "call_123", name: "calculator", ...}]
  """
  def stream_with_tools(model, history, tools, opts \\ []) do
    case ReqLLM.stream_text(model, history.messages, Keyword.merge([tools: tools], opts)) do
      {:ok, stream_response} ->
        chunks = Enum.to_list(stream_response.stream)

        Enum.each(chunks, fn ch ->
          if ch.type == :content and is_binary(ch.text), do: IO.write(ch.text)
        end)

        IO.write("\n")

        {:ok,
         %{
           chunks: chunks,
           assistant_text: Parser.text_from_chunks(chunks),
           tool_calls: Parser.tool_calls_from_chunks(chunks)
         }}

      error ->
        error
    end
  end

  @doc """
  Phase 2: Execute tool calls sequentially and append results to history.

  For each tool call, finds the matching tool definition, executes it,
  and appends the result (or error) as a tool_result message to the history.

  ## Parameters

  - `history` - ReqLLM.Context struct
  - `tools` - List of available ReqLLM.Tool structs
  - `tool_calls` - List of tool call maps from stream_with_tools/4

  ## Returns

  Updated ReqLLM.Context with tool result messages appended

  ## Examples

      history = SimpleAgent.Core.execute_tools_sequential(
        history,
        tools,
        [%{id: "call_1", name: "calculator", arguments: %{"expression" => "2+2"}}]
      )
      #=> Updated history with tool result appended
  """
  def execute_tools_sequential(history, tools, tool_calls) do
    Enum.reduce(tool_calls, history, fn call, ctx ->
      case Enum.find(tools, &(&1.name == call.name)) do
        %Tool{} = tool ->
          case Tool.execute(tool, call.arguments) do
            {:ok, result} ->
              IO.puts("[tool] #{call.name}(#{inspect(call.arguments)}) -> #{inspect(result)}")
              Context.append(ctx, tool_result_message(call.name, call.id, result))

            {:error, reason} ->
              error_str = if is_binary(reason), do: reason, else: inspect(reason)
              IO.puts("[error] #{call.name} error: #{error_str}")
              Context.append(ctx, tool_result_message(call.name, call.id, %{error: error_str}))
          end

        nil ->
          IO.puts("[error] Tool not found: #{call.name}")
          ctx
      end
    end)
  end

  @doc """
  Phase 3: Generate final response from the LLM.

  Calls ReqLLM.generate_text/3 with the updated history (including tool results)
  and normalizes the response to extract plain text.

  ## Parameters

  - `model` - Model identifier
  - `history` - ReqLLM.Context with tool results appended
  - `opts` - Additional options passed to ReqLLM.generate_text/3

  ## Returns

  - `{:ok, text}` - Final response text
  - `{:error, reason}` - Generation error

  ## Examples

      {:ok, final_text} = SimpleAgent.Core.finalize(
        "anthropic:claude-3-5-sonnet-20241022",
        history,
        max_tokens: 256,
        temperature: 0.0
      )
      #=> {:ok, "The result is 4."}
  """
  def finalize(model, history, opts \\ []) do
    model
    |> ReqLLM.generate_text(history.messages, opts)
    |> Parser.normalize_final_text()
  end
end

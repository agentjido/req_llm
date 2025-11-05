defmodule ReqLLM.Examples.Agent do
  @moduledoc """
  A GenServer-based AI agent that uses ReqLLM for streaming text generation with tool calling.

  This agent provides a conversation interface with maintained history and supports
  function calling capabilities with Claude 3.5's streaming format.

  ## Usage

      # Start the agent
      {:ok, agent} = ReqLLM.Examples.Agent.start_link()

      # Send a prompt
      ReqLLM.Examples.Agent.prompt(agent, "What's 15 * 7?")

      # Agent streams response to stdout and returns final text
      #=> {:ok, "15 * 7 = 105"}

  ## Features

  - Streaming text generation with real-time output
  - Tool calling with proper argument parsing from Claude 3.5
  - Conversation history maintenance
  - Two-step completion for tool usage scenarios
  - Calculator and web search tools included

  """
  use GenServer

  alias ReqLLM.{Context, Tool}

  defstruct [:history, :tools, :model]

  @default_model "anthropic:claude-sonnet-4-20250514"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def prompt(pid, message) when is_binary(message) do
    GenServer.call(pid, {:prompt, message}, 30_000)
  end

  def prompt(pid, model, message) when is_binary(model) and is_binary(message) do
    GenServer.call(pid, {:prompt, model, message}, 30_000)
  end

  @impl true
  def init(opts) do
    system_prompt =
      Keyword.get(opts, :system_prompt, """
      You are a helpful AI assistant with access to tools.

      When you need to compute math, use the calculator tool with the expression parameter.

      Do not wrap arguments in code fences. Do not include extra text in arguments.

      When you need to search for information, use the web_search tool with a relevant query.

      Always use tools when appropriate and provide clear, helpful responses.
      """)

    model = Keyword.get(opts, :model, @default_model)
    tools = setup_tools()

    history = Context.new([Context.system(system_prompt)])

    {:ok, %__MODULE__{history: history, tools: tools, model: model}}
  end

  @impl true
  def handle_call({:prompt, message}, from, %{model: model} = state) do
    handle_call({:prompt, model, message}, from, state)
  end

  @impl true
  def handle_call({:prompt, model, message}, _from, state) do
    new_history = Context.append(state.history, Context.user(message))

    case stream_and_handle_tools(model, new_history, state.tools) do
      {:ok, final_history, final_response} ->
        IO.write("\n")
        {:reply, {:ok, final_response}, %{state | history: final_history}}

      {:error, error} ->
        IO.write("Error: #{inspect(error)}\n")
        {:reply, {:error, error}, state}
    end
  end

  defp stream_and_handle_tools(model, history, tools) do
    case ReqLLM.stream_text(model, history.messages, tools: tools) do
      {:ok, stream_response} ->
        # Stream chunks to console in real-time and collect for processing
        chunks =
          stream_response.stream
          |> Enum.map(fn chunk ->
            # Stream to console immediately
            IO.write(chunk.text)

            chunk
          end)

        case extract_tool_calls_from_chunks(chunks) do
          [] ->
            text = chunks |> Enum.map_join("", & &1.text)
            final_history = Context.append(history, Context.assistant(text))
            {:ok, final_history, text}

          tool_calls ->
            initial_text = chunks |> Enum.map_join("", & &1.text)

            assistant_message = Context.assistant(initial_text, tool_calls: tool_calls)
            history_with_tool_call = Context.append(history, assistant_message)

            # Execute tools and show results
            IO.write("\n")

            history_with_results =
              Enum.reduce(tool_calls, history_with_tool_call, fn tool_call, ctx ->
                # Find the tool
                tool = Enum.find(tools, fn t -> t.name == tool_call.name end)

                if tool do
                  case ReqLLM.Tool.execute(tool, tool_call.arguments) do
                    {:ok, result} ->
                      IO.write(
                        "🔧 #{tool_call.name}(#{inspect(tool_call.arguments)}) → #{inspect(result)}\n"
                      )

                      tool_result_msg =
                        Context.tool_result_message(tool_call.name, tool_call.id, result)

                      Context.append(ctx, tool_result_msg)

                    {:error, error} ->
                      IO.write("❌ #{tool_call.name}: #{inspect(error)}\n")
                      error_result = %{error: "Tool execution failed"}

                      tool_result_msg =
                        Context.tool_result_message(tool_call.name, tool_call.id, error_result)

                      Context.append(ctx, tool_result_msg)
                  end
                else
                  IO.write("❌ Tool #{tool_call.name} not found\n")
                  ctx
                end
              end)

            case ReqLLM.stream_text(model, history_with_results.messages) do
              {:ok, final_stream_response} ->
                IO.write("\n")
                # Stream final response to console in real-time
                final_chunks =
                  final_stream_response.stream
                  |> Enum.map(fn chunk ->
                    # Stream to console immediately
                    IO.write(chunk.text)
                    chunk
                  end)

                final_text = final_chunks |> Enum.map_join("", & &1.text)

                final_history =
                  Context.append(history_with_results, Context.assistant(final_text))

                {:ok, final_history, final_text}

              {:error, error} ->
                {:error, error}
            end
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp extract_tool_calls_from_chunks(chunks) do
    # Base tool calls with index
    tool_calls =
      chunks
      |> Enum.filter(&(&1.type == :tool_call))
      |> Enum.map(fn chunk ->
        %{
          id: Map.get(chunk.metadata, :id) || "call_#{:erlang.unique_integer()}",
          name: chunk.name,
          arguments: chunk.arguments || %{},
          index: Map.get(chunk.metadata, :index, 0)
        }
      end)

    # Collect argument fragments from meta chunks
    arg_fragments =
      chunks
      |> Enum.filter(fn
        %{type: :meta, metadata: %{tool_call_args: _}} -> true
        _ -> false
      end)
      |> Enum.group_by(& &1.metadata.tool_call_args.index)
      |> Map.new(fn {index, fragments} ->
        json = fragments |> Enum.map_join("", & &1.metadata.tool_call_args.fragment)
        {index, json}
      end)

    # Merge accumulated JSON back into tool calls
    tool_calls
    |> Enum.map(fn call ->
      case Map.get(arg_fragments, call.index) do
        nil ->
          Map.delete(call, :index)

        json ->
          case Jason.decode(json) do
            {:ok, args} -> call |> Map.put(:arguments, args) |> Map.delete(:index)
            # keep empty args if invalid JSON
            {:error, _} -> Map.delete(call, :index)
          end
      end
    end)
  end

  defp setup_tools do
    [
      Tool.new!(
        name: "calculator",
        description:
          "Perform mathematical calculations. Prefer structured arguments: " <>
            ~s|{"operation":"multiply","operands":[15,7]}| <>
            ". As a fallback, you may pass an expression string: " <>
            ~s|{"expression":"15 * 7 + 23"}| <>
            ". Valid operations: add, subtract, multiply, divide, power, sqrt.",
        parameter_schema: [
          operation: [
            type: :string,
            required: false,
            doc: "One of: add, subtract, multiply, divide, power, sqrt"
          ],
          operands: [
            type: {:list, :any},
            required: false,
            doc: "Numbers to operate on. For sqrt, pass a single number; for others, pass 2+."
          ],
          expression: [
            type: :string,
            required: false,
            doc: "Optional fallback. Examples: '15 * 7 + 23', '10 * 5', 'sqrt(16)'."
          ]
        ],
        callback: &calculator_callback/1
      ),
      Tool.new!(
        name: "web_search",
        description: "Search the web for information",
        parameter_schema: [
          query: [type: :string, required: true, doc: "Search query"]
        ],
        callback: fn %{"query" => query} ->
          {:ok, "Mock search results for: #{query}"}
        end
      )
    ]
  end

  defp calculator_callback(%{expression: expr}) when is_binary(expr) do
    {result, _} = Code.eval_string(expr)
    {:ok, result}
  rescue
    e -> {:error, "Invalid expression: #{Exception.message(e)}"}
  end

  defp calculator_callback(%{operation: op, operands: ops}) when is_list(ops) do
    with :ok <- validate_operation(op),
         {:ok, nums} <- cast_numbers(ops) do
      compute(op, nums)
    end
  end

  defp calculator_callback(%{"expression" => expr}) when is_binary(expr) do
    calculator_callback(%{expression: expr})
  end

  defp calculator_callback(%{"operation" => op, "operands" => ops}) when is_list(ops) do
    calculator_callback(%{operation: op, operands: ops})
  end

  defp calculator_callback(args) do
    {:error,
     "Provide either {operation, operands} or {expression}. Examples: " <>
       ~s|{"operation":"multiply","operands":[15,7]}| <>
       " or " <>
       ~s|{"expression":"15 * 7 + 23"}| <> ". Got: #{inspect(args)}"}
  end

  defp validate_operation(op)
       when op in ["add", "subtract", "multiply", "divide", "power", "sqrt"] do
    :ok
  end

  defp validate_operation(op),
    do: {:error, "Invalid operation: #{op}. Valid: add, subtract, multiply, divide, power, sqrt"}

  defp cast_numbers(ops) do
    nums =
      Enum.map(ops, fn
        n when is_integer(n) -> n * 1.0
        n when is_float(n) -> n
        s when is_binary(s) -> String.to_float(s)
      end)

    {:ok, nums}
  rescue
    _ -> {:error, "All operands must be numbers"}
  end

  defp compute("add", nums), do: {:ok, Enum.sum(nums)}
  defp compute("subtract", [a, b]), do: {:ok, a - b}
  defp compute("multiply", nums), do: {:ok, Enum.reduce(nums, 1, &(&1 * &2))}
  defp compute("divide", [a, b]) when b != 0, do: {:ok, a / b}
  defp compute("divide", [_, 0]), do: {:error, "Division by zero"}
  defp compute("power", [a, b]), do: {:ok, :math.pow(a, b)}
  defp compute("sqrt", [a]) when a >= 0, do: {:ok, :math.sqrt(a)}
  defp compute("sqrt", [a]), do: {:error, "Cannot take square root of negative number: #{a}"}

  defp compute(op, ops),
    do: {:error, "Operation #{op} not supported with #{length(ops)} operands"}

  # Handle streaming completion messages
  @impl true
  def handle_info({:stream_task_completed, _context}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, :ok}, state) when is_reference(ref) do
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end

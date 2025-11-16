#!/usr/bin/env elixir

Mix.install([
  {:req_llm, path: ".."},
  {:abacus, "~> 2.0"},
  {:jason, "~> 1.4"}
])

Logger.configure(level: :warning)

Code.require_file("simple_agent_parser.ex", __DIR__)
Code.require_file("simple_agent_tools.ex", __DIR__)
Code.require_file("simple_agent_prompts.ex", __DIR__)
Code.require_file("simple_agent_core.ex", __DIR__)

defmodule SimpleAgent.V5 do
  @moduledoc """
  Advanced agent with parallel tool execution using Task.Supervisor.

  This version demonstrates:
  - Task.Supervisor for managing concurrent tool executions
  - Per-tool timeouts with graceful error handling
  - Parallel execution of multiple tool calls
  - Production-ready error handling and monitoring

  Key improvements over V3:
  - V5 is the first version where tool execution itself runs in separate processes
    via Task.Supervisor, freeing the agent process while tools run
  - Tools execute in parallel rather than sequentially
  - Configurable timeout per tool (default: 5000ms)
  - Failed tools don't block other tools
  """

  use GenServer

  alias ReqLLM.{Context, Tool}
  import ReqLLM.Context
  alias SimpleAgent.{Core, Prompts}

  defstruct [:model, :history, :tools, :supervisor]

  @default_tool_timeout 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    model = Keyword.get(opts, :model)

    tools = [
      SimpleAgent.Tools.calculator_tool(),
      SimpleAgent.Tools.slow_calculator_tool()
    ]

    {:ok, supervisor} = Task.Supervisor.start_link()

    history = Context.new([system(Prompts.slow_tool_prompt())])
    {:ok, %__MODULE__{model: model, history: history, tools: tools, supervisor: supervisor}}
  end

  def ask(pid, user_text) when is_binary(user_text) do
    GenServer.call(pid, {:ask, user_text}, 30_000)
  end

  @impl true
  def handle_call({:ask, user_text}, from, state) do
    IO.puts("Received: #{user_text}\n")
    state = update_in(state.history, &Context.append(&1, user(user_text)))
    {:noreply, state, {:continue, {:stream_response, from}}}
  end

  @impl true
  def handle_continue({:stream_response, from}, %{model: model, history: history, tools: tools} = state) do
    IO.puts("Streaming response...\n")

    case Core.stream_with_tools(model, history, tools, temperature: 0.0) do
      {:ok, %{assistant_text: text, tool_calls: calls}} ->
        IO.write("\n")
        state = update_in(state.history, &Context.append(&1, assistant(text, tool_calls: calls)))

        if calls == [] do
          GenServer.reply(from, {:ok, text})
          {:noreply, state}
        else
          {:noreply, state, {:continue, {:execute_tools_parallel, from, calls}}}
        end

      {:error, error} ->
        IO.puts("\nStream error: #{inspect(error)}\n")
        GenServer.reply(from, {:error, error})
        {:noreply, state}
    end
  end

  @impl true
  def handle_continue({:finalize_response, from}, %{model: model, history: history} = state) do
    IO.puts("Generating final answer...\n")

    case Core.finalize(model, history, max_tokens: 256, temperature: 0.0) do
      {:ok, final_text} ->
        IO.puts(final_text)
        IO.puts("")
        state = update_in(state.history, &Context.append(&1, assistant(final_text)))
        GenServer.reply(from, {:ok, final_text})
        {:noreply, state}

      {:error, err} ->
        IO.puts("Error: Final generate_text error: #{inspect(err)}\n")
        GenServer.reply(from, {:error, err})
        {:noreply, state}
    end
  end

  @impl true
  def handle_continue({:execute_tools_parallel, from, tool_calls}, %{tools: tools, supervisor: supervisor} = state) do
    IO.puts("Executing #{length(tool_calls)} tool call(s) in parallel...\n")

    start_time = System.monotonic_time(:millisecond)

    results = run_tools_parallel(tool_calls, tools, supervisor, @default_tool_timeout)

    total_elapsed = System.monotonic_time(:millisecond) - start_time

    state =
      Enum.reduce(results, state, fn {result, elapsed}, acc_state ->
        case result do
          {:ok, call, tool_result} ->
            IO.puts("Success: #{call.name}(#{inspect(call.arguments)}) → #{inspect(tool_result)} (#{elapsed}ms)")
            tool_msg = Context.tool_result_message(call.name, call.id, tool_result)
            update_in(acc_state.history, &Context.append(&1, tool_msg))

          {:error, %{} = call, reason} ->
            error_str = if is_binary(reason), do: reason, else: inspect(reason)
            IO.puts("Error: #{call.name} error: #{error_str} (#{elapsed}ms)")
            tool_msg = Context.tool_result_message(call.name, call.id, %{error: error_str})
            update_in(acc_state.history, &Context.append(&1, tool_msg))

          {:error, nil, reason} ->
            error_str = if is_binary(reason), do: reason, else: inspect(reason)
            IO.puts("Error: Tool execution timeout: #{error_str} (#{elapsed}ms)")
            acc_state
        end
      end)

    IO.puts("\nTime: Total parallel execution time: #{total_elapsed}ms")
    IO.puts("Note: Sequential would have taken ~#{Enum.sum(Enum.map(results, fn {_, e} -> e end))}ms\n")

    {:noreply, state, {:continue, {:finalize_response, from}}}
  end

  @impl true
  def handle_continue(unknown_action, state) do
    IO.puts("Warning: Unknown continue action: #{inspect(unknown_action)}")
    {:noreply, state}
  end

  defp run_tools_parallel(tool_calls, tools, supervisor, timeout_ms) do
    Task.Supervisor.async_stream_nolink(
      supervisor,
      tool_calls,
      fn call ->
        tool_start = System.monotonic_time(:millisecond)
        tool = Enum.find(tools, &(&1.name == call.name))

        result =
          if tool do
            case Tool.execute(tool, call.arguments) do
              {:ok, value} -> {:ok, call, value}
              {:error, reason} -> {:error, call, reason}
            end
          else
            {:error, call, "Tool not found: #{call.name}"}
          end

        elapsed = System.monotonic_time(:millisecond) - tool_start
        {result, elapsed}
      end,
      timeout: timeout_ms,
      on_timeout: :kill_task,
      max_concurrency: System.schedulers_online()
    )
    |> Enum.map(fn
      {:ok, {result, elapsed}} ->
        {result, elapsed}

      {:exit, :timeout} ->
        {{:error, nil, "Tool execution timeout (#{timeout_ms}ms)"}, timeout_ms}
    end)
  end

end

model = System.get_env("REQ_LLM_MODEL") || "anthropic:claude-sonnet-4-5"

IO.puts("=== SimpleAgent V5 - Parallel Tool Execution Demo ===")
IO.puts("Pattern: Task.Supervisor.async_stream for concurrent tool calls\n")
IO.puts("Model: #{model}")
IO.puts("Temperature: 0.0 (for deterministic tool behavior)")
IO.puts("Tool timeout: 5000ms per tool\n")
IO.puts(String.duplicate("=", 80))

{:ok, pid} = SimpleAgent.V5.start_link(model: model)

IO.puts("\nQuestion 1: What is (15 * 7 + 23) / 2?\n")
IO.puts(String.duplicate("-", 80))
{:ok, _response} = SimpleAgent.V5.ask(pid, "What is (15 * 7 + 23) / 2?")
IO.puts(String.duplicate("=", 80))

IO.puts("\nQuestion 2: Can you calculate both sqrt(144) and 10 * 5 for me?\n")
IO.puts(String.duplicate("-", 80))
{:ok, _response} = SimpleAgent.V5.ask(pid, "Can you calculate both sqrt(144) and 10 * 5 for me?")
IO.puts(String.duplicate("=", 80))

IO.puts("\nV5 Demo Complete!")
IO.puts("\nKey Features:")
IO.puts("  - Parallel execution: Multiple tools run concurrently")
IO.puts("  - Per-tool timeouts: Each tool has 5s limit (configurable)")
IO.puts("  - Non-blocking: Server processes phases asynchronously")
IO.puts("  - Error isolation: One tool failure doesn't block others")
IO.puts("  - Performance metrics: Shows parallel vs sequential timing")

# tutorial/agents/10_agent_task_tools.exs
#
# Chapter 11: Offloading Tools to Tasks
# Goal: Run tools in separate Tasks to avoid blocking the GenServer.
#       This is critical for slow tools or network requests.
#
# Run with:
#   mix run tutorial/agents/10_agent_task_tools.exs

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

defmodule SimpleAgent.TaskTools do
  use GenServer

  import ReqLLM.Context

  alias ReqLLM.{Context, Tool, ToolCall}

  # --- TOOLS ---
  def calculator_tool do
    Tool.new!(
      name: "calculator",
      description: "Safely evaluate math.",
      parameter_schema: [expression: [type: :string, required: true]],
      callback: fn args ->
        expr = args[:expression] || args["expression"]
        if is_binary(expr), do: Abacus.eval(expr), else: {:error, "Missing expr"}
      end
    )
  end

  def slow_calculator_tool do
    Tool.new!(
      name: "slow_calculator",
      description: "Calculator that sleeps 2s (simulates slow API)",
      parameter_schema: [expression: [type: :string, required: true]],
      callback: fn args ->
        Process.sleep(2_000)
        expr = args[:expression] || args["expression"]
        if is_binary(expr), do: Abacus.eval(expr), else: {:error, "Missing expr"}
      end
    )
  end

  # --- STATE ---
  defstruct [:model, :context, :tools, :reply_to]

  # --- API ---
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask(pid, text), do: GenServer.call(pid, {:ask, text}, 120_000)

  # --- CALLBACKS ---
  @impl true
  def init(opts) do
    model = Keyword.get(opts, :model)
    tools = [calculator_tool(), slow_calculator_tool()]
    ctx = Context.new([system("You are a helpful assistant using a calculator.")])
    {:ok, %__MODULE__{model: model, context: ctx, tools: tools}}
  end

  @impl true
  def handle_call({:ask, text}, from, state) do
    ctx = Context.append(state.context, user(text))
    {:noreply, %{state | context: ctx, reply_to: from}, {:continue, :phase_1_ask_model}}
  end

  # --- PHASES ---

  @impl true
  def handle_continue(:phase_1_ask_model, state) do
    IO.puts("   [OTP] Phase 1: Generating text/tool calls...")

    {:ok, response} =
      ReqLLM.generate_text(
        state.model,
        state.context.messages,
        tools: state.tools
      )

    usage = response.usage
    calls = ReqLLM.Response.tool_calls(response)
    updated_ctx = Context.append(state.context, response.message)

    if calls == [] do
      GenServer.reply(state.reply_to, {:ok, ReqLLM.Response.text(response)})
      {:noreply, %{state | context: updated_ctx, reply_to: nil}}
    else
      {:noreply, %{state | context: updated_ctx},
       {:continue, {:phase_2_execute_tools, calls, usage}}}
    end
  end

  @impl true
  def handle_continue({:phase_2_execute_tools, calls, phase1_usage}, state) do
    IO.puts("   [OTP] Phase 2: Executing #{length(calls)} tool(s) with Tasks...")

    final_ctx =
      Enum.reduce(calls, state.context, fn call, ctx ->
        tool = find_tool(state.tools, ToolCall.name(call))
        args = ToolCall.args_map(call)

        IO.puts("      -> Starting Task for #{ToolCall.name(call)}")
        IO.puts("         GenServer PID: #{inspect(self())}")

        # Spawn Task
        task =
          Task.async(fn ->
            IO.puts("         Task PID: #{inspect(self())}")
            start = System.monotonic_time(:millisecond)
            result = Tool.execute(tool, args)
            elapsed = System.monotonic_time(:millisecond) - start
            {result, elapsed}
          end)

        # Await with timeout
        {result, elapsed} =
          try do
            Task.await(task, 3_000)
          catch
            :exit, {:timeout, _} ->
              IO.puts("         Task TIMEOUT")
              {{:error, :timeout}, 3_000}
          end

        IO.puts("         Completed in #{elapsed}ms")

        # Append result
        content =
          case result do
            {:ok, value} -> to_string(value)
            {:error, :timeout} -> "Tool timed out after 3s"
            {:error, reason} -> "Tool error: #{inspect(reason)}"
          end

        Context.append(ctx, Context.tool_result(call.id, content))
      end)

    {:noreply, %{state | context: final_ctx}, {:continue, {:phase_3_final_answer, phase1_usage}}}
  end

  @impl true
  def handle_continue({:phase_3_final_answer, _usage}, state) do
    IO.puts("   [OTP] Phase 3: Finalizing (streaming)...")

    {:ok, stream_response} =
      ReqLLM.stream_text(
        state.model,
        state.context.messages,
        tools: []
      )

    IO.write("assistant> ")

    final_text =
      stream_response.stream
      |> Enum.reduce("", fn chunk, acc ->
        if chunk.type == :content, do: IO.write(chunk.text)
        acc <> (chunk.text || "")
      end)

    IO.write("\n\n")

    updated_ctx = Context.append(state.context, assistant(final_text))
    GenServer.reply(state.reply_to, {:ok, final_text})
    {:noreply, %{state | context: updated_ctx, reply_to: nil}}
  end

  defp find_tool(tools, name) do
    Enum.find(tools, fn t -> t.name == name end)
  end
end

# --- MAIN ---
model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")
IO.puts("=== Chapter 11: Task-Based Tool Execution ===\n")

{:ok, pid} = SimpleAgent.TaskTools.start_link(model: model)

IO.puts(">> Calculate slow: 5 * 7")
SimpleAgent.TaskTools.ask(pid, "Calculate slow: 5 * 7")

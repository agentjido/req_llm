# tutorial/agents/11_agent_parallel_tools.exs
#
# Chapter 12: Parallel Tool Execution
# Goal: Execute independent tool calls in parallel using Task.Supervisor.
#
# Run with:
#   mix run tutorial/agents/11_agent_parallel_tools.exs

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

defmodule SimpleAgent.Parallel do
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
  defstruct [:model, :context, :tools, :reply_to, :task_sup]

  # --- API ---
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask(pid, text), do: GenServer.call(pid, {:ask, text}, 120_000)

  # --- CALLBACKS ---
  @impl true
  def init(opts) do
    model = Keyword.get(opts, :model)
    {:ok, task_sup} = Task.Supervisor.start_link()

    tools = [calculator_tool(), slow_calculator_tool()]
    ctx = Context.new([system("You are a helpful assistant using a calculator.")])

    {:ok,
     %__MODULE__{
       model: model,
       context: ctx,
       tools: tools,
       task_sup: task_sup
     }}
  end

  @impl true
  def handle_call({:ask, text}, from, state) do
    ctx = Context.append(state.context, user(text))
    {:noreply, %{state | context: ctx, reply_to: from}, {:continue, :phase_1_ask_model}}
  end

  @impl true
  def handle_continue(:phase_1_ask_model, state) do
    IO.puts("   [OTP] Phase 1: Generating text/tool calls...")

    {:ok, response} =
      ReqLLM.generate_text(state.model, state.context.messages, tools: state.tools)

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
    IO.puts("   [OTP] Phase 2: Executing #{length(calls)} tool(s) IN PARALLEL...")

    wall_start = System.monotonic_time(:millisecond)

    results =
      Task.Supervisor.async_stream_nolink(
        state.task_sup,
        calls,
        fn call ->
          tool = find_tool(state.tools, ToolCall.name(call))
          args = ToolCall.args_map(call)
          start = System.monotonic_time(:millisecond)

          IO.puts("      -> [#{ToolCall.name(call)}] Starting (PID: #{inspect(self())})")

          result =
            case tool do
              nil ->
                {:error, call, "Unknown tool"}

              _ ->
                case Tool.execute(tool, args) do
                  {:ok, value} -> {:ok, call, value}
                  {:error, reason} -> {:error, call, reason}
                end
            end

          elapsed = System.monotonic_time(:millisecond) - start
          IO.puts("      -> [#{ToolCall.name(call)}] Completed in #{elapsed}ms")

          {result, elapsed}
        end,
        timeout: 5_000,
        max_concurrency: System.schedulers_online()
      )
      |> Enum.to_list()

    wall_elapsed = System.monotonic_time(:millisecond) - wall_start

    # Compute total sequential time
    sequential_time =
      results
      |> Enum.map(fn
        {:ok, {_result, elapsed}} -> elapsed
        _ -> 0
      end)
      |> Enum.sum()

    IO.puts("      -> Wall clock: #{wall_elapsed}ms, Sequential would be: #{sequential_time}ms")

    # Fold results into context
    new_ctx =
      Enum.reduce(results, state.context, fn
        {:ok, {{:ok, call, value}, _elapsed}}, ctx ->
          Context.append(ctx, Context.tool_result(call.id, to_string(value)))

        {:ok, {{:error, call, reason}, _elapsed}}, ctx ->
          Context.append(ctx, Context.tool_result(call.id, "Error: #{inspect(reason)}"))

        {:exit, :timeout}, ctx ->
          IO.puts("      -> Task TIMEOUT")
          # NOTE: Ideally we'd add a tool error here too
          ctx
      end)

    {:noreply, %{state | context: new_ctx}, {:continue, {:phase_3_final_answer, phase1_usage}}}
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
IO.puts("=== Chapter 12: Parallel Tool Execution ===\n")

{:ok, pid} = SimpleAgent.Parallel.start_link(model: model)

IO.puts(">> Calculate 5 * 7 and also slow: 10 + 2")
SimpleAgent.Parallel.ask(pid, "Calculate 5 * 7 and also slow: 10 + 2")

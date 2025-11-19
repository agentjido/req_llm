# tutorial/agents/05_agent_phased.exs
#
# Chapter 4.1: Phased OTP Agent (Standalone)
# Goal: Break the loop into phases using {:continue, ...}
#       This keeps the GenServer responsive to system messages and allows
#       observability between phases.
#
# Run with:
#   mix run tutorial/agents/05_agent_phased.exs

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

defmodule SimpleAgent.Phased do
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

  defstruct [:model, :context, :tools, :reply_to]

  # --- API ---
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  # We use a simplified call that waits for the final result,
  # but internally the server processes it in steps.
  def ask(pid, text), do: GenServer.call(pid, {:ask, text}, 120_000)

  # --- CALLBACKS ---
  @impl true
  def init(opts) do
    model = Keyword.get(opts, :model)
    tools = [calculator_tool()]
    ctx = Context.new([system("You are a helpful assistant using a calculator.")])
    {:ok, %__MODULE__{model: model, context: ctx, tools: tools}}
  end

  @impl true
  def handle_call({:ask, text}, from, state) do
    # 1. Append user message
    new_ctx = Context.append(state.context, user(text))

    # 2. Schedule Phase 1 via continue
    #    We don't reply yet. We store 'from' to reply later.
    {:noreply, %{state | context: new_ctx, reply_to: from}, {:continue, :phase_1_ask_model}}
  end

  @impl true
  def handle_continue(:phase_1_ask_model, state) do
    IO.puts("   [OTP] Phase 1: Generating text/tool calls...")

    # For standalone simplicity, using generate_text (blocking call inside the continue phase)
    # In a real async app, you might use Task.async here to avoid blocking the GenServer.
    {:ok, response} =
      ReqLLM.generate_text(state.model, state.context.messages, tools: state.tools)

    calls = ReqLLM.Response.tool_calls(response)
    updated_ctx = Context.append(state.context, response.message)

    if calls == [] do
      # No tools -> Done. Reply to user.
      GenServer.reply(state.reply_to, {:ok, ReqLLM.Response.text(response)})
      {:noreply, %{state | context: updated_ctx, reply_to: nil}}
    else
      # Tools found -> Schedule Phase 2
      {:noreply, %{state | context: updated_ctx}, {:continue, {:phase_2_execute_tools, calls}}}
    end
  end

  @impl true
  def handle_continue({:phase_2_execute_tools, calls}, state) do
    IO.puts("   [OTP] Phase 2: Executing #{length(calls)} tool(s)...")

    # Execute sequentially
    final_ctx =
      Enum.reduce(calls, state.context, fn call, ctx ->
        args = ToolCall.args_map(call)
        IO.puts("      -> Executing #{ToolCall.name(call)} with #{inspect(args)}")

        res =
          case Tool.execute(calculator_tool(), args) do
            {:ok, val} -> val
            {:error, reason} -> "Tool error: #{inspect(reason)}"
          end

        Context.append(ctx, Context.tool_result(call.id, to_string(res)))
      end)

    # Schedule Phase 3
    {:noreply, %{state | context: final_ctx}, {:continue, :phase_3_final_answer}}
  end

  @impl true
  def handle_continue(:phase_3_final_answer, state) do
    IO.puts("   [OTP] Phase 3: Finalizing...")

    {:ok, response} = ReqLLM.generate_text(state.model, state.context.messages, tools: [])
    text = ReqLLM.Response.text(response)

    updated_ctx = Context.append(state.context, response.message)

    # Reply to the original caller
    GenServer.reply(state.reply_to, {:ok, text})

    {:noreply, %{state | context: updated_ctx, reply_to: nil}}
  end
end

# --- MAIN ---
model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")
IO.puts("=== Chapter 4.1: Phased OTP Agent (Standalone) ===\n")

{:ok, pid} = SimpleAgent.Phased.start_link(model: model)

# Complex multi-step math
q = "Calculate (10 + 2) * 5, and then take the square root of 144."
IO.puts(">> User: #{q}")

{:ok, ans} = SimpleAgent.Phased.ask(pid, q)
IO.puts("\n>> Final Answer: #{ans}")

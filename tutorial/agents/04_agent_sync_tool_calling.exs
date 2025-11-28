# tutorial/agents/04_agent_sync_tool_calling.exs
#
# Chapter 3.2: Sync Tool Calling Agent (Standalone)
# Goal: Wrap the tool loop in a GenServer.
#       This demonstrates the "V2" pattern: Blocking call, internal loop.
#
# Run with:
#   mix run tutorial/agents/04_agent_sync_tool_calling.exs

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

defmodule SimpleAgent.Sync do
  use GenServer

  import ReqLLM.Context

  alias ReqLLM.{Context, Tool, ToolCall}

  # --- TOOLS (Inlined) ---
  def calculator_tool do
    Tool.new!(
      name: "calculator",
      description: "Safely evaluate a math expression.",
      parameter_schema: [expression: [type: :string, required: true]],
      callback: fn args ->
        expr = args[:expression] || args["expression"]
        if is_binary(expr), do: Abacus.eval(expr), else: {:error, "Missing expr"}
      end
    )
  end

  # --- STATE ---
  defstruct [:model, :context, :tools]

  # --- API ---
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask(pid, text), do: GenServer.call(pid, {:ask, text}, 120_000)

  # --- CALLBACKS ---
  @impl true
  def init(opts) do
    model = Keyword.get(opts, :model)
    tools = [calculator_tool()]

    prompt = """
    You are a helpful assistant. Use the calculator for math.
    Provide only valid JSON arguments.
    """

    context = Context.new([system(prompt)])
    {:ok, %__MODULE__{model: model, context: context, tools: tools}}
  end

  @impl true
  def handle_call({:ask, user_text}, _from, state) do
    # Add user message
    ctx = Context.append(state.context, user(user_text))

    # Run the 3-phase loop
    {final_ctx, final_text} = run_tool_loop(state.model, ctx, state.tools)

    {:reply, {:ok, final_text}, %{state | context: final_ctx}}
  end

  # --- PRIVATE LOOP LOGIC ---

  defp run_tool_loop(model, context, tools) do
    # Phase 1: Ask model (synchronous)
    IO.puts(">> [Phase 1] Asking model...")
    {:ok, response} = ReqLLM.generate_text(model, context.messages, tools: tools)
    tool_calls = ReqLLM.Response.tool_calls(response)

    if tool_calls == [] do
      # No tools, we are done.
      {Context.append(context, response.message), ReqLLM.Response.text(response)}
    else
      IO.puts(">> [Phase 2] Executing #{length(tool_calls)} tool(s)...")
      context2 = Context.append(context, response.message)

      context3 =
        Enum.reduce(tool_calls, context2, fn call, acc ->
          args = ToolCall.args_map(call)
          IO.puts("   -> Tool: #{ToolCall.name(call)} args: #{inspect(args)}")

          res =
            case Tool.execute(calculator_tool(), args) do
              {:ok, val} -> val
              {:error, reason} -> "Tool error: #{inspect(reason)}"
            end

          IO.puts("      Result: #{inspect(res)}")
          Context.append(acc, Context.tool_result(call.id, to_string(res)))
        end)

      IO.puts(">> [Phase 3] Final answer...")
      {:ok, final_resp} = ReqLLM.generate_text(model, context3.messages, tools: [])
      text = ReqLLM.Response.text(final_resp)
      IO.puts(text)

      {Context.append(context3, final_resp.message), text}
    end
  end
end

# --- MAIN ---
model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")
IO.puts("=== Chapter 3.2: Sync Tool Agent (Standalone) ===\n")

{:ok, pid} = SimpleAgent.Sync.start_link(model: model)

# 1. Simple math
IO.puts("\n>> Q1: Calculate 50 * 3 + 10.")
SimpleAgent.Sync.ask(pid, "Calculate 50 * 3 + 10.")

# 2. Follow up
IO.puts("\n>> Q2: Now divide that by 2.")
SimpleAgent.Sync.ask(pid, "Now divide that by 2.")

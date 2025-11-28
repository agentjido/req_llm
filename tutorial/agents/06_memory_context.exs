# tutorial/agents/06_memory_context.exs
#
# Chapter 7: Memory and Context Management
# Goal: Implement a sliding window context to manage memory usage.
#       This prevents the context from growing indefinitely.
#
# Run with:
#   mix run tutorial/agents/06_memory_context.exs

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

defmodule SimpleAgent.WithMemory do
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

  # --- STATE ---
  defstruct [:model, :context, :tools, :reply_to, :max_messages]

  # --- API ---
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask(pid, text), do: GenServer.call(pid, {:ask, text}, 120_000)
  def reset(pid), do: GenServer.call(pid, :reset)

  # --- CALLBACKS ---
  @impl true
  def init(opts) do
    model = Keyword.get(opts, :model)
    max_messages = Keyword.get(opts, :max_messages, 20)
    tools = [calculator_tool()]

    ctx = Context.new([system("You are a helpful assistant using a calculator.")])

    {:ok,
     %__MODULE__{
       model: model,
       context: ctx,
       tools: tools,
       max_messages: max_messages
     }}
  end

  @impl true
  def handle_call({:ask, text}, from, state) do
    # 1. Append user message
    ctx = Context.append(state.context, user(text))

    # 2. Truncate before processing
    ctx = maybe_truncate_context(ctx, state.max_messages)
    IO.puts("   [Context] #{length(ctx.messages)} messages in context")

    # 3. Schedule Phase 1 via continue
    {:noreply, %{state | context: ctx, reply_to: from}, {:continue, :phase_1_ask_model}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    # Clear context but keep system prompt
    [system_msg | _] = state.context.messages
    new_ctx = %{state.context | messages: [system_msg]}
    IO.puts("   [Reset] Context cleared")
    {:reply, :ok, %{state | context: new_ctx}}
  end

  # --- PHASES (Same as Phased Agent) ---

  @impl true
  def handle_continue(:phase_1_ask_model, state) do
    IO.puts("   [OTP] Phase 1: Generating text/tool calls...")

    {:ok, response} =
      ReqLLM.generate_text(state.model, state.context.messages, tools: state.tools)

    calls = ReqLLM.Response.tool_calls(response)
    updated_ctx = Context.append(state.context, response.message)

    if calls == [] do
      GenServer.reply(state.reply_to, {:ok, ReqLLM.Response.text(response)})
      {:noreply, %{state | context: updated_ctx, reply_to: nil}}
    else
      {:noreply, %{state | context: updated_ctx}, {:continue, {:phase_2_execute_tools, calls}}}
    end
  end

  @impl true
  def handle_continue({:phase_2_execute_tools, calls}, state) do
    IO.puts("   [OTP] Phase 2: Executing #{length(calls)} tool(s)...")

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

    {:noreply, %{state | context: final_ctx}, {:continue, :phase_3_final_answer}}
  end

  @impl true
  def handle_continue(:phase_3_final_answer, state) do
    IO.puts("   [OTP] Phase 3: Finalizing...")

    {:ok, response} = ReqLLM.generate_text(state.model, state.context.messages, tools: [])
    text = ReqLLM.Response.text(response)
    updated_ctx = Context.append(state.context, response.message)

    GenServer.reply(state.reply_to, {:ok, text})
    {:noreply, %{state | context: updated_ctx, reply_to: nil}}
  end

  # --- PRIVATE HELPERS ---

  defp maybe_truncate_context(context, max_messages) do
    messages = context.messages

    if length(messages) > max_messages do
      IO.puts("   [Truncate] Reducing from #{length(messages)} to #{max_messages} messages")

      # Keep system message (first one) + recent messages
      [system_msg | rest] = messages
      # We need to keep (max_messages - 1) from the end of rest
      recent = Enum.take(rest, -(max_messages - 1))

      %{context | messages: [system_msg | recent]}
    else
      context
    end
  end
end

# --- MAIN ---
model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")
IO.puts("=== Chapter 7: Memory and Context Management ===\n")

{:ok, pid} =
  SimpleAgent.WithMemory.start_link(
    model: model,
    # Small limit for demo
    max_messages: 6
  )

# Ask many questions to trigger truncation
for i <- 1..5 do
  IO.puts("\n>> Q#{i}: What is #{i} * 10?")
  {:ok, ans} = SimpleAgent.WithMemory.ask(pid, "What is #{i} * 10?")
  IO.puts("   Answer: #{ans}")
end

IO.puts("\n>> Testing memory: What did I ask you first?")
{:ok, ans} = SimpleAgent.WithMemory.ask(pid, "What did I ask you first?")
IO.puts("   Answer: #{ans}")

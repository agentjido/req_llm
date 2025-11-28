# tutorial/agents/14_router_agent.exs
#
# Chapter 15: Router Agent
# Goal: Route requests to specialized agents based on intent.
#       This demonstrates the "Supervisor/Worker" pattern for agents.
#
# Run with:
#   mix run tutorial/agents/14_router_agent.exs

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

defmodule MathAgent do
  use GenServer

  import ReqLLM.Context

  alias ReqLLM.{Context, Tool, ToolCall}

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

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask(pid, text), do: GenServer.call(pid, {:ask, text}, 60_000)

  @impl true
  def init(opts) do
    model = Keyword.fetch!(opts, :model)
    ctx = Context.new([system("You are a math expert. Use the calculator tool.")])
    {:ok, %{model: model, context: ctx, tools: [calculator_tool()]}}
  end

  @impl true
  def handle_call({:ask, text}, _from, state) do
    IO.puts("   [MathAgent] Using calculator...")
    ctx = Context.append(state.context, user(text))

    # Simplified synchronous execution for demo
    {:ok, response} = ReqLLM.generate_text(state.model, ctx.messages, tools: state.tools)
    calls = ReqLLM.Response.tool_calls(response)
    ctx2 = Context.append(ctx, response.message)

    ctx3 =
      Enum.reduce(calls, ctx2, fn call, acc ->
        args = ToolCall.args_map(call)
        res = Tool.execute(calculator_tool(), args) |> elem(1)
        Context.append(acc, Context.tool_result(call.id, to_string(res)))
      end)

    {:ok, final} = ReqLLM.generate_text(state.model, ctx3.messages, tools: [])
    reply = ReqLLM.Response.text(final)

    {:reply, {:ok, reply}, %{state | context: Context.append(ctx3, final.message)}}
  end
end

defmodule ChatAgent do
  use GenServer

  import ReqLLM.Context
  alias ReqLLM.Context

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask(pid, text), do: GenServer.call(pid, {:ask, text}, 60_000)

  @impl true
  def init(opts) do
    model = Keyword.fetch!(opts, :model)
    ctx = Context.new([system("You are a friendly chat assistant.")])
    {:ok, %{model: model, context: ctx}}
  end

  @impl true
  def handle_call({:ask, text}, _from, state) do
    IO.puts("   [ChatAgent] Responding...")
    ctx = Context.append(state.context, user(text))
    {:ok, response} = ReqLLM.generate_text(state.model, ctx.messages)
    reply = ReqLLM.Response.text(response)
    {:reply, {:ok, reply}, %{state | context: Context.append(ctx, response.message)}}
  end
end

defmodule RouterAgent do
  use GenServer

  defstruct [:math_agent, :chat_agent]

  # --- API ---
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask(pid, text), do: GenServer.call(pid, {:ask, text}, 60_000)

  # --- CALLBACKS ---
  @impl true
  def init(opts) do
    model = Keyword.fetch!(opts, :model)
    {:ok, math} = MathAgent.start_link(model: model)
    {:ok, chat} = ChatAgent.start_link(model: model)
    {:ok, %__MODULE__{math_agent: math, chat_agent: chat}}
  end

  @impl true
  def handle_call({:ask, text}, _from, state) do
    # Simple routing heuristic
    target =
      if contains_math?(text) do
        IO.puts("   [Router] → Math Agent")
        state.math_agent
      else
        IO.puts("   [Router] → Chat Agent")
        state.chat_agent
      end

    # Delegate to specialist
    # Note: In a real system we might want to use `ReqLLM.generate_text` 
    # with a "routing" prompt to decide which agent to call.
    # Both agents share the same ask signature
    {:ok, reply} = MathAgent.ask(target, text)

    {:reply, {:ok, reply}, state}
  end

  defp contains_math?(text) do
    String.match?(text, ~r/\d/) or
      String.match?(text, ~r/(calculate|compute|plus|minus|times|divide)/i)
  end
end

# --- MAIN ---
model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")
IO.puts("=== Chapter 15: Router Agent ===\n")

{:ok, router} = RouterAgent.start_link(model: model)

# Test routing
IO.puts(">> Q1: What is 5 * 7?")
{:ok, ans1} = RouterAgent.ask(router, "What is 5 * 7?")
IO.puts("assistant> #{ans1}")

IO.puts("\n>> Q2: Tell me about Elixir")
{:ok, ans2} = RouterAgent.ask(router, "Tell me about Elixir")
IO.puts("assistant> #{ans2}")

# tutorial/agents/08_agent_streaming_finalize.exs
#
# Chapter 9: Streaming Phased Agent
# Goal: Stream the final answer token-by-token for better UX.
#       Tools still execute silently in Phase 2.
#
# Run with:
#   mix run tutorial/agents/08_agent_streaming_finalize.exs

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

defmodule SimpleAgent.StreamingPhased do
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
  defstruct [:model, :context, :tools, :reply_to]

  # --- API ---
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask(pid, text), do: GenServer.call(pid, {:ask, text}, 120_000)
  def reset(pid), do: GenServer.call(pid, :reset)

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
    ctx = Context.append(state.context, user(text))

    # 2. Schedule Phase 1 via continue
    {:noreply, %{state | context: ctx, reply_to: from}, {:continue, :phase_1_ask_model}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    [system_msg | _] = state.context.messages
    new_ctx = %{state.context | messages: [system_msg]}
    IO.puts("   [Reset] Context cleared")
    {:reply, :ok, %{state | context: new_ctx}}
  end

  # --- PHASES ---

  @impl true
  def handle_continue(:phase_1_ask_model, state) do
    IO.puts("   [OTP] Phase 1: Generating text/tool calls...")

    {:ok, response} =
      ReqLLM.generate_text(state.model, state.context.messages, tools: state.tools)

    calls = ReqLLM.Response.tool_calls(response)
    updated_ctx = Context.append(state.context, response.message)

    if calls == [] do
      # If no tools, we can stream the output directly? 
      # But here we already got a non-streaming response.
      # In a fully optimized agent, we might stream Phase 1 too.
      # For this lesson, we just return the text if no tools.
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
    IO.puts("   [OTP] Phase 3: Finalizing (streaming)...")

    # Here is the key difference: stream_text instead of generate_text
    {:ok, stream_response} =
      ReqLLM.stream_text(
        state.model,
        state.context.messages,
        tools: []
      )

    IO.write("assistant> ")

    # Consume stream and print tokens
    final_text =
      stream_response.stream
      |> Enum.reduce("", fn chunk, acc ->
        case chunk.type do
          :content ->
            IO.write(chunk.text)
            acc <> chunk.text

          _ ->
            acc
        end
      end)

    IO.write("\n\n")

    # Update context and reply
    new_ctx = Context.append(state.context, assistant(final_text))
    GenServer.reply(state.reply_to, {:ok, final_text})

    {:noreply, %{state | context: new_ctx, reply_to: nil}}
  end
end

# --- CLI MODULE (Same as Lesson 8) ---

defmodule CLI do
  def loop(pid) do
    case IO.gets("you> ") do
      nil ->
        IO.puts("\nGoodbye!")
        :ok

      line ->
        line = String.trim(line)

        case line do
          "" ->
            loop(pid)

          "/quit" ->
            IO.puts("Goodbye!")

          "/reset" ->
            SimpleAgent.StreamingPhased.reset(pid)
            loop(pid)

          text ->
            # We don't print "assistant> " here because the agent streams it
            case SimpleAgent.StreamingPhased.ask(pid, text) do
              {:ok, _full_text} ->
                # Loop again
                loop(pid)

              {:error, reason} ->
                IO.puts("   [Error] #{inspect(reason)}\n")
                loop(pid)
            end
        end
    end
  end
end

# --- MAIN ---
model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")

IO.puts("""
=== Chapter 9: Streaming Phased Agent ===
Model: #{model}

Watch the final answer stream token-by-token!
Type /quit to exit.
""")

{:ok, pid} = SimpleAgent.StreamingPhased.start_link(model: model)

CLI.loop(pid)

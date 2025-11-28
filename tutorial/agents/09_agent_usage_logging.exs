# tutorial/agents/09_agent_usage_logging.exs
#
# Chapter 10: Usage Logging and Observability
# Goal: Track and log token usage across all phases.
#       This helps monitor costs and performance.
#
# Run with:
#   mix run tutorial/agents/09_agent_usage_logging.exs

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

defmodule SimpleAgent.Observable do
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

    # LOG USAGE
    usage = response.usage
    IO.puts("   [Usage Phase 1] input: #{usage[:input_tokens]}, output: #{usage[:output_tokens]}")

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
    IO.puts("   [OTP] Phase 2: Executing #{length(calls)} tool(s)...")

    final_ctx =
      Enum.reduce(calls, state.context, fn call, ctx ->
        args = ToolCall.args_map(call)
        # IO.puts("      -> Executing #{ToolCall.name(call)} with #{inspect(args)}")

        res =
          case Tool.execute(calculator_tool(), args) do
            {:ok, val} -> val
            {:error, reason} -> "Tool error: #{inspect(reason)}"
          end

        Context.append(ctx, Context.tool_result(call.id, to_string(res)))
      end)

    {:noreply, %{state | context: final_ctx}, {:continue, {:phase_3_final_answer, phase1_usage}}}
  end

  @impl true
  def handle_continue({:phase_3_final_answer, phase1_usage}, state) do
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
        case chunk.type do
          :content ->
            IO.write(chunk.text)
            acc <> chunk.text

          _ ->
            acc
        end
      end)

    IO.write("\n\n")

    # LOG USAGE
    usage3 = ReqLLM.StreamResponse.usage(stream_response)
    finish_reason = ReqLLM.StreamResponse.finish_reason(stream_response)

    IO.puts(
      "   [Usage Phase 3] input: #{usage3[:input_tokens]}, output: #{usage3[:output_tokens]}"
    )

    IO.puts("   [Finish Reason] #{inspect(finish_reason)}")

    # LOG TOTAL
    total_input = (phase1_usage[:input_tokens] || 0) + (usage3[:input_tokens] || 0)
    total_output = (phase1_usage[:output_tokens] || 0) + (usage3[:output_tokens] || 0)
    IO.puts("   [Total Usage] input: #{total_input}, output: #{total_output}")

    updated_ctx = Context.append(state.context, assistant(final_text))
    GenServer.reply(state.reply_to, {:ok, final_text})

    {:noreply, %{state | context: updated_ctx, reply_to: nil}}
  end
end

# --- CLI MODULE ---
defmodule CLI do
  def loop(pid) do
    case IO.gets("you> ") do
      nil ->
        :ok

      line ->
        case String.trim(line) do
          "" ->
            loop(pid)

          "/quit" ->
            IO.puts("Goodbye!")

          text ->
            SimpleAgent.Observable.ask(pid, text)
            loop(pid)
        end
    end
  end
end

# --- MAIN ---
model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")
IO.puts("=== Chapter 10: Usage Logging and Observability ===\n")

{:ok, pid} = SimpleAgent.Observable.start_link(model: model)

IO.puts(">> Calculate 5 * 7")
SimpleAgent.Observable.ask(pid, "Calculate 5 * 7")

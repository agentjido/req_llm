# tutorial/agents/12_agent_tool_retries.exs
#
# Chapter 13: Tool Retries with Backoff
# Goal: Implement resilience by retrying failed tool calls.
#       Uses exponential backoff to be polite to APIs.
#
# Run with:
#   mix run tutorial/agents/12_agent_tool_retries.exs

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

defmodule SimpleAgent.Resilient do
  use GenServer

  import ReqLLM.Context

  alias ReqLLM.{Context, Tool, ToolCall}

  # --- TOOLS ---
  def flaky_tool do
    Tool.new!(
      name: "flaky",
      description: "Fails randomly 50% of the time",
      parameter_schema: [value: [type: :integer, required: true]],
      callback: fn args ->
        if :rand.uniform() > 0.5 do
          {:ok, args[:value] || args["value"]}
        else
          {:error, "Random failure"}
        end
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
    tools = [flaky_tool()]
    ctx = Context.new([system("You are a helpful assistant.")])
    {:ok, %__MODULE__{model: model, context: ctx, tools: tools, task_sup: task_sup}}
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
    IO.puts("   [OTP] Phase 2: Executing #{length(calls)} tool(s) with retries...")

    results =
      Task.Supervisor.async_stream_nolink(
        state.task_sup,
        calls,
        fn call ->
          tool = find_tool(state.tools, ToolCall.name(call))
          args = ToolCall.args_map(call)

          IO.puts("      -> [#{ToolCall.name(call)}] Starting")

          # Use retry wrapper
          result =
            case tool do
              nil ->
                {:error, call, "Unknown tool"}

              _ ->
                case execute_with_retries(tool, args) do
                  {:ok, value} -> {:ok, call, value}
                  {:error, reason} -> {:error, call, reason}
                end
            end

          {result, 0}
        end,
        # Longer for retries
        timeout: 10_000,
        max_concurrency: System.schedulers_online()
      )
      |> Enum.to_list()

    # Fold results into context
    new_ctx =
      Enum.reduce(results, state.context, fn
        {:ok, {{:ok, call, value}, _elapsed}}, ctx ->
          Context.append(ctx, Context.tool_result(call.id, to_string(value)))

        {:ok, {{:error, call, reason}, _elapsed}}, ctx ->
          Context.append(ctx, Context.tool_result(call.id, "Error: #{inspect(reason)}"))

        {:exit, :timeout}, ctx ->
          IO.puts("      -> Task TIMEOUT")
          ctx
      end)

    {:noreply, %{state | context: new_ctx}, {:continue, {:phase_3_final_answer, phase1_usage}}}
  end

  @impl true
  def handle_continue({:phase_3_final_answer, _usage}, state) do
    IO.puts("   [OTP] Phase 3: Finalizing (streaming)...")
    {:ok, stream_response} = ReqLLM.stream_text(state.model, state.context.messages, tools: [])
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

  # --- RETRY LOGIC ---

  defp execute_with_retries(tool, args, max_attempts \\ 3, base_delay \\ 200) do
    do_execute(tool, args, max_attempts, base_delay, 1)
  end

  defp do_execute(tool, args, max, base_delay, attempt) when attempt <= max do
    case Tool.execute(tool, args) do
      {:ok, value} ->
        if attempt > 1 do
          IO.puts("         [Retry] Succeeded on attempt #{attempt}")
        end

        {:ok, value}

      {:error, reason} ->
        if attempt == max do
          IO.puts("         [Retry] Failed after #{max} attempts: #{inspect(reason)}")
          {:error, reason}
        else
          delay = base_delay * attempt
          IO.puts("         [Retry] Attempt #{attempt} failed, retrying in #{delay}ms...")
          Process.sleep(delay)
          do_execute(tool, args, max, base_delay, attempt + 1)
        end
    end
  end

  defp find_tool(tools, name) do
    Enum.find(tools, fn t -> t.name == name end)
  end
end

# --- MAIN ---
model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")
IO.puts("=== Chapter 13: Tool Retries ===\n")

{:ok, pid} = SimpleAgent.Resilient.start_link(model: model)

IO.puts(">> Use flaky tool with value 42")
SimpleAgent.Resilient.ask(pid, "Use flaky tool with value 42")

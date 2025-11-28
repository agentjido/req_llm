# tutorial/agents/16_agent_persistence.exs
#
# Chapter 17: Persisting Conversation History
# Goal: Save and load agent state to/from disk.
#       This allows resuming conversations after a restart.
#
# Run with:
#   mix run tutorial/agents/16_agent_persistence.exs

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

defmodule AgentConfig do
  defstruct [:model, :temperature, :system_prompt, :max_tokens]
end

defmodule SimpleAgent.Persistent do
  use GenServer

  import ReqLLM.Context

  alias ReqLLM.Context

  defstruct [:config, :context]

  # --- API ---
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask(pid, text), do: GenServer.call(pid, {:ask, text}, 60_000)

  def save(pid, path) do
    GenServer.call(pid, {:save, path})
  end

  def load(pid, path) do
    GenServer.call(pid, {:load, path})
  end

  # --- CALLBACKS ---
  @impl true
  def init(opts) do
    model = Keyword.get(opts, :model)

    config = %AgentConfig{
      model: model,
      temperature: 0.0,
      system_prompt: "You are a helpful assistant.",
      max_tokens: 500
    }

    context = Context.new([system(config.system_prompt)])
    {:ok, %__MODULE__{config: config, context: context}}
  end

  @impl true
  def handle_call({:ask, text}, _from, state) do
    ctx = Context.append(state.context, user(text))
    {:ok, response} = ReqLLM.generate_text(state.config.model, ctx.messages)
    reply = ReqLLM.Response.text(response)
    {:reply, {:ok, reply}, %{state | context: Context.append(ctx, response.message)}}
  end

  @impl true
  def handle_call({:save, path}, _from, state) do
    bin = :erlang.term_to_binary(state.context)
    File.write!(path, bin)
    IO.puts("   [Persistence] Saved to #{path}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:load, path}, _from, state) do
    IO.puts("   [Persistence] Loading from #{path}")

    if File.exists?(path) do
      bin = File.read!(path)
      context = :erlang.binary_to_term(bin)
      {:reply, :ok, %{state | context: context}}
    else
      {:reply, {:error, :enoent}, state}
    end
  end
end

# --- CLI ---
defmodule CLI do
  def loop(pid) do
    case IO.gets("you> ") do
      nil ->
        :ok

      line ->
        case String.trim(line) do
          "/save " <> path ->
            SimpleAgent.Persistent.save(pid, String.trim(path))
            loop(pid)

          "/load " <> path ->
            SimpleAgent.Persistent.load(pid, String.trim(path))
            loop(pid)

          "/quit" ->
            :ok

          "" ->
            loop(pid)

          text ->
            {:ok, reply} = SimpleAgent.Persistent.ask(pid, text)
            IO.puts("assistant> #{reply}\n")
            loop(pid)
        end
    end
  end
end

# --- MAIN ---
model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")

IO.puts("""
=== Chapter 17: Persistent Conversations ===

Commands:
  /save <path>  - Save conversation to file
  /load <path>  - Load conversation from file
  /quit         - Exit

""")

{:ok, pid} = SimpleAgent.Persistent.start_link(model: model)
CLI.loop(pid)

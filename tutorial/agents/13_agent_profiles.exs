# tutorial/agents/13_agent_profiles.exs
#
# Chapter 14: Configurable Agent Profiles
# Goal: Switch between different agent personas/configurations at runtime.
#
# Run with:
#   mix run tutorial/agents/13_agent_profiles.exs

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

defmodule AgentConfig do
  defstruct [:model, :temperature, :system_prompt, :max_tokens]

  def profiles do
    %{
      teacher: %__MODULE__{
        model: "anthropic:claude-haiku-4.5",
        temperature: 0.3,
        system_prompt: """
        You are a patient teacher. Explain concepts clearly with examples.
        Keep explanations concise but thorough.
        """,
        max_tokens: 500
      },
      concise: %__MODULE__{
        model: "anthropic:claude-haiku-4.5",
        temperature: 0.0,
        system_prompt: """
        Answer in a single short paragraph. Be direct and concise.
        """,
        max_tokens: 150
      },
      coder: %__MODULE__{
        model: "anthropic:claude-haiku-4.5",
        temperature: 0.2,
        system_prompt: """
        You are an Elixir coding assistant. Provide working code examples.
        Focus on idiomatic Elixir patterns.
        """,
        max_tokens: 800
      }
    }
  end
end

defmodule SimpleAgent.Configurable do
  use GenServer

  import ReqLLM.Context

  alias ReqLLM.{Context}

  defstruct [:config, :context, :tools]

  # --- API ---
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def ask(pid, text), do: GenServer.call(pid, {:ask, text}, 60_000)

  def set_profile(pid, profile_name) do
    GenServer.call(pid, {:set_profile, profile_name})
  end

  def get_profile(pid) do
    GenServer.call(pid, :get_profile)
  end

  # --- CALLBACKS ---
  @impl true
  def init(opts) do
    profile_name = Keyword.get(opts, :profile, :teacher)
    config = Map.fetch!(AgentConfig.profiles(), profile_name)

    context = Context.new([system(config.system_prompt)])
    {:ok, %__MODULE__{config: config, context: context, tools: []}}
  end

  @impl true
  def handle_call({:set_profile, profile_name}, _from, state) do
    new_config = Map.fetch!(AgentConfig.profiles(), profile_name)

    # Rebuild context with new system prompt
    [_old_system | conversation] = state.context.messages
    new_context = Context.new([system(new_config.system_prompt) | conversation])

    IO.puts("   [Profile] Switched to :#{profile_name}")

    {:reply, :ok, %{state | config: new_config, context: new_context}}
  end

  @impl true
  def handle_call(:get_profile, _from, state) do
    current =
      AgentConfig.profiles()
      |> Enum.find(fn {_name, config} -> config == state.config end)
      |> elem(0)

    {:reply, current, state}
  end

  @impl true
  def handle_call({:ask, user_text}, _from, state) do
    ctx = Context.append(state.context, user(user_text))

    {:ok, response} =
      ReqLLM.generate_text(
        state.config.model,
        ctx.messages,
        temperature: state.config.temperature,
        max_tokens: state.config.max_tokens
      )

    text = ReqLLM.Response.text(response)
    new_ctx = Context.append(ctx, assistant(text))

    {:reply, {:ok, text}, %{state | context: new_ctx}}
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
          "/profile " <> profile_name ->
            profile = String.to_atom(profile_name)
            SimpleAgent.Configurable.set_profile(pid, profile)
            loop(pid)

          "/profile" ->
            current = SimpleAgent.Configurable.get_profile(pid)
            IO.puts("   Current profile: #{current}")
            IO.puts("   Available: teacher, concise, coder")
            loop(pid)

          "/quit" ->
            :ok

          "" ->
            loop(pid)

          text ->
            {:ok, reply} = SimpleAgent.Configurable.ask(pid, text)
            IO.puts("assistant> #{reply}\n")
            loop(pid)
        end
    end
  end
end

# --- MAIN ---
IO.puts("""
=== Chapter 14: Configurable Agent Profiles ===

Commands:
  /profile          - Show current profile
  /profile <name>   - Switch profile (teacher, concise, coder)
  /quit             - Exit

""")

{:ok, pid} = SimpleAgent.Configurable.start_link(profile: :teacher)
CLI.loop(pid)

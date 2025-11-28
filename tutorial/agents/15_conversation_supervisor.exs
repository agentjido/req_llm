# tutorial/agents/15_conversation_supervisor.exs
#
# Chapter 16: Conversation Supervision
# Goal: Manage multiple independent conversations using a DynamicSupervisor.
#       This ensures that if one agent crashes, others are unaffected.
#
# Run with:
#   mix run tutorial/agents/15_conversation_supervisor.exs

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

# Reuse the Configurable Agent from Lesson 14
defmodule AgentConfig do
  defstruct [:model, :temperature, :system_prompt, :max_tokens]

  def profiles do
    %{
      teacher: %__MODULE__{
        model: "anthropic:claude-haiku-4.5",
        temperature: 0.3,
        system_prompt: "You are a patient teacher.",
        max_tokens: 500
      },
      concise: %__MODULE__{
        model: "anthropic:claude-haiku-4.5",
        temperature: 0.0,
        system_prompt: "Answer in a single short sentence.",
        max_tokens: 150
      },
      coder: %__MODULE__{
        model: "anthropic:claude-haiku-4.5",
        temperature: 0.2,
        system_prompt: "You are an Elixir coding assistant.",
        max_tokens: 800
      }
    }
  end
end

defmodule SimpleAgent.Configurable do
  use GenServer

  import ReqLLM.Context

  alias ReqLLM.Context

  defstruct [:config, :context]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask(pid, text), do: GenServer.call(pid, {:ask, text}, 60_000)

  @impl true
  def init(opts) do
    profile_name = Keyword.get(opts, :profile, :teacher)
    # Handle model override if needed, otherwise use profile default
    model_override = Keyword.get(opts, :model)

    base_config = Map.fetch!(AgentConfig.profiles(), profile_name)
    config = if model_override, do: %{base_config | model: model_override}, else: base_config

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
end

defmodule ConversationSupervisor do
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_conversation(opts \\ []) do
    DynamicSupervisor.start_child(__MODULE__, {SimpleAgent.Configurable, opts})
  end

  def count_conversations do
    DynamicSupervisor.count_children(__MODULE__)
  end
end

# --- MAIN ---
model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")
IO.puts("=== Chapter 16: Conversation Supervision ===\n")

# Start supervisor
{:ok, _sup} = ConversationSupervisor.start_link([])

# Start multiple conversations
IO.puts(">> Starting 3 conversations...")
{:ok, conv1} = ConversationSupervisor.start_conversation(model: model, profile: :teacher)
{:ok, conv2} = ConversationSupervisor.start_conversation(model: model, profile: :concise)
{:ok, conv3} = ConversationSupervisor.start_conversation(model: model, profile: :coder)

IO.puts("   Conversation 1: #{inspect(conv1)}")
IO.puts("   Conversation 2: #{inspect(conv2)}")
IO.puts("   Conversation 3: #{inspect(conv3)}")

# Show they're independent
IO.puts("\n>> Testing independence...")
IO.write("   [Conv1] ")
{:ok, ans1} = SimpleAgent.Configurable.ask(conv1, "What is 2+2?")
IO.puts(ans1)

IO.write("   [Conv2] ")
{:ok, ans2} = SimpleAgent.Configurable.ask(conv2, "What is 2+2?")
IO.puts(ans2)

# Show supervisor state
count = ConversationSupervisor.count_conversations()
IO.puts("\n>> Active conversations: #{count.active}")

# Demonstrate crash recovery
IO.puts("\n>> Killing conv1...")
Process.exit(conv1, :kill)
Process.sleep(100)

IO.puts("   Checking supervisor...")
count = ConversationSupervisor.count_conversations()
IO.puts("   Active conversations: #{count.active} (supervisor doesn't restart)")

IO.puts("\nNote: one_for_one means crashed agents aren't restarted automatically here.")

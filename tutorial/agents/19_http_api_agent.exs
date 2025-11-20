# tutorial/agents/19_http_api_agent.exs
#
# Chapter 20: HTTP JSON API
# Goal: Expose the agent over HTTP using Plug and Cowboy.
#       Supports multiple user sessions via an Agent registry.
#
# Run with:
#   mix run tutorial/agents/19_http_api_agent.exs

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

# --- AGENT CONFIG (From Lesson 14) ---
defmodule AgentConfig do
  defstruct [:model, :temperature, :system_prompt, :max_tokens]

  def profiles do
    %{
      teacher: %__MODULE__{
        model: "anthropic:claude-haiku-4.5",
        temperature: 0.3,
        system_prompt: "You are a patient teacher.",
        max_tokens: 500
      }
    }
  end
end

# --- AGENT (Configurable) ---
defmodule SimpleAgent.Configurable do
  use GenServer

  import ReqLLM.Context

  alias ReqLLM.Context

  defstruct [:config, :context]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask(pid, text), do: GenServer.call(pid, {:ask, text}, 60_000)

  @impl true
  def init(opts) do
    model = Keyword.get(opts, :model)
    # Use teacher profile as default
    config = %{Map.fetch!(AgentConfig.profiles(), :teacher) | model: model}
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

# --- SESSION REGISTRY ---
defmodule SessionRegistry do
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def get_or_create(session_id, model) do
    Agent.get_and_update(__MODULE__, fn sessions ->
      case Map.get(sessions, session_id) do
        nil ->
          # Create new agent
          {:ok, pid} = SimpleAgent.Configurable.start_link(model: model)
          IO.puts("   [Registry] New session: #{session_id}")
          {pid, Map.put(sessions, session_id, pid)}

        pid ->
          {pid, sessions}
      end
    end)
  end
end

# --- HTTP ROUTER ---
defmodule ChatRouter do
  use Plug.Router

  import Plug.Conn

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  post "/chat" do
    %{"message" => message, "session_id" => session_id} = conn.body_params
    model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")

    pid = SessionRegistry.get_or_create(session_id, model)

    {:ok, reply} = SimpleAgent.Configurable.ask(pid, message)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        reply: reply,
        session_id: session_id
      })
    )
  end

  get "/health" do
    send_resp(conn, 200, "OK")
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end
end

# --- MAIN ---
model = System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")

IO.puts("""
=== Chapter 20: HTTP JSON API ===

Starting server on http://localhost:4001

Test with:
  curl -XPOST http://localhost:4001/chat \\
    -H "Content-Type: application/json" \\
    -d '{"session_id":"user123","message":"Hello"}'

Press Ctrl+C to stop.
""")

# Start registry and server
{:ok, _registry} = SessionRegistry.start_link([])
{:ok, _server} = Bandit.start_link(plug: ChatRouter, port: 4001)

# Keep running
Process.sleep(:infinity)

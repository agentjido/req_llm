# tutorial/agents/20_liveview_chat_agent.exs
#
# Chapter 21: LiveView Streaming Chat UI
# Goal: Build a real-time chat UI with Phoenix LiveView.
#       Streams responses token-by-token to the browser.
#
# Run with:
#   mix run tutorial/agents/20_liveview_chat_agent.exs

# Install dependencies dynamically for the single-file script
Mix.install([
  # Path to local req_llm
  {:req_llm, path: "../.."},
  {:phoenix_playground, "~> 0.1.8"},
  {:jason, "~> 1.4"},
  {:dotenvy, "~> 0.8"}
])

# Ensure dotenvy loads .env file if present
_ = Dotenvy.source(".env")
Logger.configure(level: :warning)

# --- AGENT (Streaming Phased) ---
defmodule SimpleAgent.StreamingPhased do
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
  def ask(pid, text), do: GenServer.call(pid, {:ask, text}, 120_000)

  @impl true
  def init(opts) do
    model = Keyword.get(opts, :model)
    tools = [calculator_tool()]
    ctx = Context.new([system("You are a helpful assistant using a calculator.")])
    {:ok, %{model: model, context: ctx, tools: tools, reply_to: nil}}
  end

  @impl true
  def handle_call({:ask, text}, from, state) do
    ctx = Context.append(state.context, user(text))
    {:noreply, %{state | context: ctx, reply_to: from}, {:continue, :phase_1}}
  end

  @impl true
  def handle_continue(:phase_1, state) do
    {:ok, response} =
      ReqLLM.generate_text(state.model, state.context.messages, tools: state.tools)

    calls = ReqLLM.Response.tool_calls(response)
    ctx = Context.append(state.context, response.message)

    if calls == [] do
      GenServer.reply(state.reply_to, {:ok, ReqLLM.Response.text(response)})
      {:noreply, %{state | context: ctx, reply_to: nil}}
    else
      {:noreply, %{state | context: ctx}, {:continue, {:phase_2, calls}}}
    end
  end

  @impl true
  def handle_continue({:phase_2, calls}, state) do
    ctx =
      Enum.reduce(calls, state.context, fn call, acc ->
        args = ToolCall.args_map(call)
        res = Tool.execute(calculator_tool(), args) |> elem(1)
        Context.append(acc, Context.tool_result(call.id, to_string(res)))
      end)

    {:noreply, %{state | context: ctx}, {:continue, :phase_3}}
  end

  @impl true
  def handle_continue(:phase_3, state) do
    caller = state.reply_to

    {:ok, stream_response} = ReqLLM.stream_text(state.model, state.context.messages, tools: [])

    # Notify caller about chunks if caller is a PID (LiveView process)
    # But GenServer.call expects a single reply.
    # To support streaming to LiveView, we need a different approach.
    # For this demo, we'll just stream to the caller process via messages
    # and then return the final text as the call result.

    # We need to know the caller PID to send messages.
    # 'from' in handle_call is {pid, tag}.
    {caller_pid, _tag} = caller

    final_text =
      stream_response.stream
      |> Enum.reduce("", fn chunk, acc ->
        if chunk.type == :content do
          send(caller_pid, {:chunk, chunk.text})
          acc <> chunk.text
        else
          acc
        end
      end)

    updated_ctx = Context.append(state.context, assistant(final_text))
    GenServer.reply(state.reply_to, {:ok, final_text})
    {:noreply, %{state | context: updated_ctx, reply_to: nil}}
  end
end

# --- LIVEVIEW ---
defmodule ChatLive do
  use Phoenix.LiveView

  @model System.get_env("REQ_LLM_MODEL", "anthropic:claude-haiku-4.5")

  def mount(_params, _session, socket) do
    {:ok, agent} = SimpleAgent.StreamingPhased.start_link(model: @model)

    {:ok,
     assign(socket,
       messages: [],
       agent: agent,
       input: "",
       streaming: false
     )}
  end

  def handle_event("send", %{"message" => text}, socket) do
    if text == "" do
      {:noreply, socket}
      # Add user message

      # Add placeholder for assistant

      # Start streaming task
      # We use Task.async to make the GenServer call, but the GenServer
      # will send us {:chunk, text} messages directly during execution.

      # We need to call the agent from the LiveView process or tell the agent our PID.
      # But the agent is designed to reply to the caller. 
      # The SimpleAgent.StreamingPhased above uses the caller's PID from 'from'.
      # Since Task.async runs in a new process, the agent would send chunks to the Task, not the LiveView.
      # So we run the blocking call inside a Task, but we need the agent to send chunks to US (parent).
      #
      # HACK for demo: We'll just run the call in a Task, but the agent implementation 
      # above sends to `caller_pid`. If `caller_pid` is the Task, we need the Task to forward to LiveView.

      # Actually, let's modify the agent slightly to support this pattern?
      # Or simpler: Just use `send(parent, ...)` in the Task if the agent returned chunks.
      # BUT the agent streams *during* the call.

      # Let's assume the agent implementation sends to the *GenServer caller*.
      # If we call from a Task, the Task receives messages.

      # This task acts as the caller. It receives chunks.
      # It needs to forward them to the LiveView (parent).

      # We need to start a custom process that calls the agent,
      # receives messages, and forwards them.

      # Using a special wrapper to intercept messages

      # Start a process to make the call

      # Loop to receive chunks
    else
      messages = socket.assigns.messages ++ [%{role: :user, content: text}]
      messages = messages ++ [%{role: :assistant, content: "", streaming: true}]
      parent = self()

      Task.start(fn ->
        me = self()

        spawn(fn ->
          SimpleAgent.StreamingPhased.ask(socket.assigns.agent, text)
          send(me, :done)
        end)

        listen_loop(parent)
      end)

      {:noreply,
       assign(socket,
         messages: messages,
         input: "",
         streaming: true
       )}
    end
  end

  defp listen_loop(parent) do
    receive do
      {:chunk, text} ->
        send(parent, {:chunk, text})
        listen_loop(parent)

      :done ->
        send(parent, {:complete, nil})

      msg ->
        # Forward unexpected messages?
        listen_loop(parent)
    end
  end

  def handle_event("update_input", %{"value" => value}, socket) do
    {:noreply, assign(socket, input: value)}
  end

  def handle_info({:chunk, chunk}, socket) do
    # Update last message with chunk
    messages =
      List.update_at(socket.assigns.messages, -1, fn msg ->
        %{msg | content: msg.content <> chunk}
      end)

    {:noreply, assign(socket, messages: messages)}
  end

  def handle_info({:complete, _reply}, socket) do
    # Mark streaming complete
    messages =
      List.update_at(socket.assigns.messages, -1, fn msg ->
        Map.delete(msg, :streaming)
      end)

    {:noreply, assign(socket, messages: messages, streaming: false)}
  end

  def render(assigns) do
    ~H"""
    <div style="max-width: 800px; margin: 0 auto; padding: 20px; font-family: sans-serif;">
      <h1>LLM Chat Agent</h1>

      <div style="border: 1px solid #ccc; padding: 10px; height: 400px; overflow-y: scroll; margin-bottom: 10px;">
        <%= for msg <- @messages do %>
          <div style={"margin: 10px 0; padding: 10px; border-radius: 5px; background: #{if msg.role == :user, do: "#e3f2fd", else: "#f5f5f5"}"}>
            <strong><%= if msg.role == :user, do: "You", else: "Assistant" %>:</strong>
            <div><%= msg.content %></div>
            <%= if Map.get(msg, :streaming) do %>
              <span style="color: #999;">●</span>
            <% end %>
          </div>
        <% end %>
      </div>

      <form phx-submit="send" style="display: flex; gap: 10px;">
        <input
          type="text"
          name="message"
          value={@input}
          phx-change="update_input"
          placeholder="Type your message..."
          disabled={@streaming}
          style="flex: 1; padding: 10px; font-size: 14px;"
        />
        <button
          type="submit"
          disabled={@streaming}
          style="padding: 10px 20px; font-size: 14px;"
        >
          Send
        </button>
      </form>

      <p style="color: #666; font-size: 12px;">
        Model: <%= @model %>
      </p>
    </div>
    """
  end
end

# --- MAIN ---
IO.puts("""
=== Chapter 21: LiveView Streaming Chat ===

Starting LiveView on http://localhost:4000

Open in your browser to see the streaming chat UI!
""")

PhoenixPlayground.start(live: ChatLive, open_browser: true)

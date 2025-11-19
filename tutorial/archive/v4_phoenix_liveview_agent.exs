#!/usr/bin/env elixir

Mix.install([
  {:req_llm, path: "../.."},
  {:phoenix_playground, "~> 0.1.8"},
  {:abacus, "~> 2.0"},
  {:jason, "~> 1.4"},
  {:mdex, "~> 0.2"}
])

Logger.configure(level: :warning)

Code.require_file("simple_agent_parser.ex", __DIR__)
Code.require_file("simple_agent_tools.ex", __DIR__)
Code.require_file("simple_agent_prompts.ex", __DIR__)

defmodule SimpleAgent.V4 do
  @moduledoc """
  Phoenix LiveView agent with streaming AI responses.

  This version demonstrates:
  - Single-file Phoenix LiveView application with phoenix_playground
  - Real-time streaming of AI responses to the browser
  - Tool calling with visual feedback
  - Conversation history display
  - Markdown rendering with MDEx
  """

  use Phoenix.LiveView

  import ReqLLM.Context

  alias ReqLLM.{Context, Tool}
  alias SimpleAgent.{Parser, Prompts}

  @model System.get_env("REQ_LLM_MODEL") || "anthropic:claude-sonnet-4-5"

  def mount(_params, _session, socket) do
    tools = [SimpleAgent.Tools.calculator_tool()]
    history = Context.new([system(Prompts.tool_prompt())])

    socket =
      socket
      |> assign(:history, history)
      |> assign(:tools, tools)
      |> assign(:model, @model)
      |> assign(:input, "")
      |> assign(:streaming, false)
      |> assign(:current_message_id, nil)
      |> Phoenix.LiveView.stream(:messages, [])

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="container">
      <h1>SimpleAgent V4 - Phoenix LiveView</h1>
      <p class="subtitle">Model: <%= @model %></p>

      <div class="chat-container">
        <div class="messages" id="messages" phx-update="stream">
          <%= for {id, msg} <- @streams.messages do %>
            <div class={"message #{msg.role}"} id={id}>
              <div class="role"><%= msg.role %></div>
              <div class="content">
                <%= if msg.type == :tool_call do %>
                  <div class="tool-call">
                    <code><%= msg.name %>(<%= Jason.encode!(msg.arguments) %>)</code>
                    <%= if msg.result do %>
                      <div class="tool-result"><%= inspect(msg.result) %></div>
                    <% end %>
                  </div>
                <% else %>
                  <div class="markdown"><%= Phoenix.HTML.raw(msg.html) %></div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>

        <form phx-submit="send_message" class="input-form">
          <input
            type="text"
            name="message"
            value={@input}
            placeholder="Ask me anything..."
            disabled={@streaming}
            autocomplete="off"
            id="message-input"
          />
          <button type="submit" disabled={@streaming}>
            <%= if @streaming, do: "Thinking...", else: "Send" %>
          </button>
        </form>
      </div>

      <style type="text/css">
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
          margin: 0;
          padding: 0;
          background: #f5f5f5;
        }
        .container {
          max-width: 800px;
          margin: 0 auto;
          padding: 2rem;
        }
        h1 {
          color: #2d3748;
          margin-bottom: 0.5rem;
        }
        .subtitle {
          color: #718096;
          margin-bottom: 2rem;
          font-size: 0.875rem;
        }
        .chat-container {
          background: white;
          border-radius: 8px;
          box-shadow: 0 2px 4px rgba(0,0,0,0.1);
          overflow: hidden;
        }
        .messages {
          height: 500px;
          overflow-y: auto;
          padding: 1rem;
        }
        .message {
          margin-bottom: 1rem;
          padding: 0.75rem;
          border-radius: 8px;
        }
        .message.user {
          background: #e3f2fd;
          margin-left: 2rem;
        }
        .message.assistant {
          background: #f3f4f6;
          margin-right: 2rem;
        }
        .message.tool {
          background: #fff3cd;
          border-left: 3px solid #ffc107;
          font-size: 0.875rem;
        }
        .role {
          font-weight: 600;
          font-size: 0.75rem;
          text-transform: uppercase;
          color: #718096;
          margin-bottom: 0.5rem;
        }
        .content {
          color: #2d3748;
          line-height: 1.6;
        }
        .markdown {
          font-size: 0.95rem;
        }
        .markdown p {
          margin: 0.5rem 0;
        }
        .markdown code {
          background: #f1f5f9;
          padding: 0.125rem 0.25rem;
          border-radius: 3px;
          font-size: 0.875em;
        }
        .markdown pre {
          background: #1e293b;
          color: #e2e8f0;
          padding: 1rem;
          border-radius: 6px;
          overflow-x: auto;
        }
        .markdown pre code {
          background: transparent;
          padding: 0;
        }
        .markdown ul, .markdown ol {
          margin: 0.5rem 0;
          padding-left: 1.5rem;
        }
        .markdown strong {
          font-weight: 600;
        }
        .tool-call code {
          background: #f59e0b;
          color: #78350f;
          padding: 0.25rem 0.5rem;
          border-radius: 4px;
          font-size: 0.875rem;
        }
        .tool-result {
          margin-top: 0.5rem;
          color: #059669;
          font-family: 'Monaco', 'Courier New', monospace;
          font-size: 0.875rem;
        }
        .input-form {
          display: flex;
          padding: 1rem;
          border-top: 1px solid #e2e8f0;
        }
        input[type="text"] {
          flex: 1;
          padding: 0.75rem;
          border: 1px solid #cbd5e0;
          border-radius: 4px;
          font-size: 1rem;
        }
        input[type="text"]:disabled {
          background: #f7fafc;
          cursor: not-allowed;
        }
        button {
          margin-left: 0.5rem;
          padding: 0.75rem 1.5rem;
          background: #4299e1;
          color: white;
          border: none;
          border-radius: 4px;
          font-size: 1rem;
          cursor: pointer;
        }
        button:hover:not(:disabled) {
          background: #3182ce;
        }
        button:disabled {
          background: #a0aec0;
          cursor: not-allowed;
        }
      </style>
    </div>
    """
  end

  def handle_event("send_message", %{"message" => message}, socket) when message != "" do
    user_msg = %{
      id: generate_id(),
      role: :user,
      text: message,
      html: MDEx.to_html!(message),
      type: :text
    }

    socket =
      socket
      |> Phoenix.LiveView.stream_insert(:messages, user_msg)
      |> assign(:input, "")
      |> assign(:streaming, true)

    history = Context.append(socket.assigns.history, user(message))

    send(self(), {:stream_response, history})

    {:noreply, socket}
  end

  def handle_event("send_message", _params, socket), do: {:noreply, socket}

  def handle_info({:stream_response, history}, socket) do
    assistant_id = generate_id()
    parent = self()

    Task.start(fn ->
      stream_to_liveview(
        parent,
        assistant_id,
        socket.assigns.model,
        history,
        socket.assigns.tools
      )
    end)

    {:noreply, assign(socket, :current_message_id, assistant_id)}
  end

  def handle_info({:stream_chunk, assistant_id, text, html}, socket) do
    msg = %{
      id: assistant_id,
      role: :assistant,
      text: text,
      html: html,
      type: :text
    }

    {:noreply, Phoenix.LiveView.stream_insert(socket, :messages, msg)}
  end

  def handle_info({:stream_done, assistant_id, assistant_text, tool_calls}, socket) do
    history = socket.assigns.history

    if tool_calls == [] do
      history = Context.append(history, assistant(assistant_text))

      socket =
        socket
        |> assign(:history, history)
        |> assign(:streaming, false)
        |> assign(:current_message_id, nil)

      {:noreply, socket}
    else
      history = Context.append(history, assistant(assistant_text, tool_calls: tool_calls))
      socket = execute_tools(socket, history, tool_calls)
      {:noreply, socket}
    end
  end

  def handle_info({:stream_error, error}, socket) do
    error_text = "Error: #{inspect(error)}"

    error_msg = %{
      id: generate_id(),
      role: :assistant,
      text: error_text,
      html: MDEx.to_html!(error_text),
      type: :text
    }

    socket =
      socket
      |> Phoenix.LiveView.stream_insert(:messages, error_msg)
      |> assign(:streaming, false)
      |> assign(:current_message_id, nil)

    {:noreply, socket}
  end

  defp stream_to_liveview(parent, assistant_id, model, history, tools) do
    case ReqLLM.stream_text(model, history.messages,
           tools: tools,
           temperature: 0.0
         ) do
      {:ok, stream_response} ->
        {assistant_text, tool_call_chunks} =
          Enum.reduce(stream_response.stream, {"", []}, fn chunk, {text, calls} ->
            case chunk.type do
              :content when is_binary(chunk.text) ->
                new_text = text <> chunk.text
                html = MDEx.to_html!(new_text)
                send(parent, {:stream_chunk, assistant_id, new_text, html})
                {new_text, calls}

              :tool_call ->
                {text, calls ++ [chunk]}

              _ ->
                {text, calls}
            end
          end)

        tool_calls = Parser.tool_calls_from_chunks(tool_call_chunks)
        send(parent, {:stream_done, assistant_id, assistant_text, tool_calls})

      {:error, error} ->
        send(parent, {:stream_error, error})
    end
  end

  def handle_info({:finalize_response, history}, socket) do
    case ReqLLM.generate_text(socket.assigns.model, history.messages,
           max_tokens: 256,
           temperature: 0.0
         )
         |> Parser.normalize_final_text() do
      {:ok, final_text} ->
        final_msg = %{
          id: generate_id(),
          role: :assistant,
          text: final_text,
          html: MDEx.to_html!(final_text),
          type: :text
        }

        history = Context.append(history, assistant(final_text))

        socket =
          socket
          |> Phoenix.LiveView.stream_insert(:messages, final_msg)
          |> assign(:history, history)
          |> assign(:streaming, false)
          |> assign(:current_message_id, nil)

        {:noreply, socket}

      {:error, err} ->
        error_text = "Error: #{inspect(err)}"

        error_msg = %{
          id: generate_id(),
          role: :assistant,
          text: error_text,
          html: MDEx.to_html!(error_text),
          type: :text
        }

        socket =
          socket
          |> Phoenix.LiveView.stream_insert(:messages, error_msg)
          |> assign(:streaming, false)
          |> assign(:current_message_id, nil)

        {:noreply, socket}
    end
  end

  defp execute_tools(socket, history, tool_calls) do
    {tool_messages, history} =
      Enum.map_reduce(tool_calls, history, fn call, ctx ->
        tool = Enum.find(socket.assigns.tools, &(&1.name == call.name))

        {result, history2} =
          if tool do
            case Tool.execute(tool, call.arguments) do
              {:ok, value} ->
                tool_msg = Context.tool_result_message(call.name, call.id, value)
                {value, Context.append(ctx, tool_msg)}

              {:error, error} ->
                error_payload = %{error: "Tool execution failed: #{inspect(error)}"}
                tool_msg = Context.tool_result_message(call.name, call.id, error_payload)
                {error_payload, Context.append(ctx, tool_msg)}
            end
          else
            error_payload = %{error: "Tool not found"}
            {error_payload, ctx}
          end

        ui_message = %{
          id: generate_id(),
          role: :tool,
          name: call.name,
          arguments: call.arguments,
          result: result,
          type: :tool_call,
          html: ""
        }

        {ui_message, history2}
      end)

    socket =
      Enum.reduce(tool_messages, socket, fn msg, sock ->
        Phoenix.LiveView.stream_insert(sock, :messages, msg)
      end)

    send(self(), {:finalize_response, history})

    socket
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

IO.puts("=== SimpleAgent V4 - Phoenix LiveView Streaming Demo ===\n")
IO.puts("Starting Phoenix LiveView server...")
IO.puts("Open your browser to http://localhost:4000\n")
IO.puts("Press Ctrl+C twice to stop\n")

PhoenixPlayground.start(live: SimpleAgent.V4)

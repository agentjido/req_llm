defmodule PetalProWeb.StreamingChatLive do
  @moduledoc """
  LiveView for a streaming AI chat interface.

  This implementation demonstrates best practices for handling real-time
  AI responses using a unified message structure that transitions smoothly
  from streaming to completed states.
  """
  use PetalProWeb, :live_view
  import PetalProWeb.Components.StreamingChatComponents

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Streaming AI Chat",
        form: to_form(%{}, as: :form),
        messages: []
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("submit", %{"form" => %{"message" => message}}, socket) do
    case PetalPro.AI.StreamingChat.validate_message(message) do
      {:ok, clean_message} ->
        # Add user message
        user_message = %{role: "user", content: clean_message}

        # Add empty streaming assistant message
        assistant_message = %{role: "assistant", content: "", streaming: true}
        messages = socket.assigns.messages ++ [user_message, assistant_message]

        # Get conversation history (only completed messages)
        conversation = get_conversation_history(socket.assigns.messages ++ [user_message])

        # Start streaming task
        parent_pid = self()
        Task.start(fn ->
          PetalPro.AI.StreamingChat.stream_response(conversation, parent_pid,
            model: "gpt-4o-mini",
            temperature: 0.7
          )
        end)

        socket =
          socket
          |> assign(messages: messages, form: to_form(%{}, as: :form))

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def handle_event("clear", _params, socket) do
    {:noreply, assign(socket, messages: [])}
  end

  @impl true
  def handle_info({:stream_chunk, chunk}, socket) do
    # Update the last message (which is streaming)
    messages =
      List.update_at(socket.assigns.messages, -1, fn msg ->
        %{msg | content: msg.content <> chunk}
      end)

    {:noreply, assign(socket, messages: messages)}
  end

  @impl true
  def handle_info(:stream_done, socket) do
    # Mark the last message as no longer streaming
    messages =
      List.update_at(socket.assigns.messages, -1, fn msg ->
        if msg.content != "" do
          Map.delete(msg, :streaming)
        else
          msg
        end
      end)

    # If the last message is still empty, remove it and show error
    last_message = List.last(messages)

    if last_message.content == "" do
      socket =
        socket
        |> assign(messages: Enum.drop(messages, -1))
        |> put_flash(:error, "No response received from AI. Please try again.")

      {:noreply, socket}
    else
      {:noreply, assign(socket, messages: messages)}
    end
  end

  @impl true
  def handle_info({:stream_error, error}, socket) do
    message = error_to_message(error)

    # Remove the streaming message
    messages = Enum.drop(socket.assigns.messages, -1)

    socket =
      socket
      |> assign(messages: messages)
      |> put_flash(:error, message)

    {:noreply, socket}
  end

  # Private functions

  defp streaming?(messages) do
    Enum.any?(messages, &Map.get(&1, :streaming, false))
  end

  defp get_conversation_history(messages) do
    # Extract just role and content for API calls, excluding streaming messages
    messages
    |> Enum.reject(&Map.get(&1, :streaming, false))
    |> Enum.map(&Map.take(&1, [:role, :content]))
  end

  defp error_to_message({:api_error, error}) do
    error_str = inspect(error)

    cond do
      String.contains?(error_str, "closed") ->
        "Connection closed by server. You may have hit OpenAI's rate limit. Please wait a few seconds before sending another message."

      String.contains?(error_str, ["timeout", "Timeout"]) ->
        "Request timed out. Please try again."

      true ->
        "API Error: #{error_str}"
    end
  end

  defp error_to_message({:timeout, _reason}) do
    "Request timed out. Please try again."
  end

  defp error_to_message({:exit, _reason}) do
    "Connection lost. Please try again."
  end

  defp error_to_message({:unexpected, reason}) do
    "An error occurred: #{reason}"
  end

  defp error_to_message(error) do
    "Error: #{inspect(error)}"
  end
end

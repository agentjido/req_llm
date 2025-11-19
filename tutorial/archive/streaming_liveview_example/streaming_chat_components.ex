defmodule PetalProWeb.Components.StreamingChatComponents do
  @moduledoc """
  Components for rendering streaming chat messages.

  These components handle the display of chat messages including real-time
  streaming updates from AI assistants.
  """
  use PetalProWeb, :component

  @doc """
  Renders a single chat message.

  ## Attributes
  - `:message` - A map with `:role`, `:content`, and optionally `:streaming` fields
  - `:role` can be "user" or "assistant"
  - `:streaming` indicates if the message is currently being streamed
  """
  attr :message, :map, required: true

  def chat_message(assigns) do
    ~H"""
    <div class="flex gap-3">
      <%!-- Spacer for user messages (right-aligned) --%>
      <div :if={@message.role == "user"} class="flex-1"></div>

      <div class={[
        "flex gap-3 max-w-[85%]",
        @message.role == "user" && "flex-row-reverse"
      ]}>
        <%!-- Avatar --%>
        <div class={[
          "flex-shrink-0 w-8 h-8 rounded-full flex items-center justify-center",
          @message.role == "user" && "bg-primary-500",
          @message.role == "assistant" && "bg-gray-700"
        ]}>
          <.icon
            name={if @message.role == "user", do: "hero-user", else: "hero-cpu-chip"}
            class="w-5 h-5 text-white"
          />
        </div>

        <%!-- Message bubble --%>
        <div class={[
          "px-4 py-3 rounded-lg",
          @message.role == "user" && "bg-primary-500 text-white",
          @message.role == "assistant" &&
            "bg-gray-200 dark:bg-gray-700 text-gray-900 dark:text-gray-100"
        ]}>
          <%= if Map.get(@message, :streaming) && (@message.content == "" || @message.content == nil) do %>
            <%!-- Show spinner while waiting for first chunk --%>
            <.icon name="hero-cog-6-tooth-solid" class="w-4 h-4 text-gray-400 animate-spin" />
          <% else %>
            <div class="text-sm whitespace-pre-wrap">{@message.content}</div>
          <% end %>
        </div>
      </div>

      <%!-- Spacer for assistant messages (left-aligned) --%>
      <div :if={@message.role == "assistant"} class="flex-1"></div>
    </div>
    """
  end

  @doc """
  Renders a scrollable container for chat messages.

  ## Attributes
  - `:messages` - List of message maps to display
  - `:empty_state` - Optional slot for custom empty state content
  """
  attr :messages, :list, required: true
  slot :empty_state

  def messages_container(assigns) do
    ~H"""
    <div
      class="space-y-4 min-h-[300px] max-h-[350px] overflow-y-auto p-4"
      id="chat-messages"
    >
      <%= if @messages == [] do %>
        <%= if @empty_state != [] do %>
          <%= render_slot(@empty_state) %>
        <% else %>
          <div class="flex items-center justify-center h-[300px]">
            <div class="text-center text-gray-500 dark:text-gray-400">
              <.icon name="hero-chat-bubble-left-right" class="w-16 h-16 mx-auto mb-4 opacity-50" />
              <p class="text-lg font-medium">Start a conversation</p>
              <p class="text-sm">Ask me anything!</p>
            </div>
          </div>
        <% end %>
      <% else %>
        <div :for={{message, index} <- Enum.with_index(@messages)} id={"message-#{index}"}>
          <.chat_message message={message} />
        </div>
      <% end %>
    </div>
    """
  end
end

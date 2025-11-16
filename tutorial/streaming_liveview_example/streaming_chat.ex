defmodule PetalPro.AI.StreamingChat do
  @moduledoc """
  Handles streaming chat responses with proper message validation.
  """

  def stream_response(messages, parent, opts \\ []) do
    system_message = %{
      role: "system",
      content: "You are a helpful AI assistant."
    }

    conversation = [system_message | messages]
    model = Keyword.get(opts, :model, "gpt-4o-mini")
    temperature = Keyword.get(opts, :temperature, 0.7)

    case PetalPro.AI.OpenAI.chat_stream(conversation,
           model: model, temperature: temperature) do
      {:ok, stream} ->
        stream
        |> Enum.each(fn chunk ->
          send(parent, {:stream_chunk, chunk})
        end)

        send(parent, :stream_done)

      {:error, error} ->
        send(parent, {:stream_error, error})
    end
  end

  def validate_message(content) when is_binary(content) do
    trimmed = String.trim(content)

    if byte_size(trimmed) == 0 do
      {:error, "Message cannot be empty"}
    else
      {:ok, trimmed}
    end
  end

  def validate_message(_), do: {:error, "Invalid message format"}
end

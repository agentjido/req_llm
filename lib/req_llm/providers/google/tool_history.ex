defmodule ReqLLM.Providers.Google.ToolHistory do
  @moduledoc false

  alias ReqLLM.Message

  @metadata_key "google_tool_history"

  @doc """
  Selects the complete Gemini turn when it has server tool parts or a native
  function call ID. Replay keeps signatures on their original parts and lets
  a later function result refer to the original call.
  """
  def replay_parts(parts) do
    if Enum.any?(parts, &tool_history_part?/1), do: parts
  end

  def preserve(%{message: %Message{} = message} = response, [_ | _] = parts) do
    history = %{"parts" => parts, "fingerprint" => fingerprint(message)}
    metadata = Map.put(message.metadata, @metadata_key, history)
    %{response | message: %{message | metadata: metadata}}
  end

  def preserve(response, _parts), do: response

  def parts(%Message{role: :assistant, metadata: metadata} = message) do
    with %{"parts" => [_ | _] = parts, "fingerprint" => stored} when is_binary(stored) <-
           Map.get(metadata, @metadata_key),
         ^stored <- fingerprint(message) do
      parts
    else
      _ -> nil
    end
  end

  def parts(_message), do: nil

  defp fingerprint(message) do
    fields = [message.content, message.tool_calls, message.reasoning_details]

    with {:ok, json} <- Jason.encode(fields),
         {:ok, normalized} <- Jason.decode(json) do
      :sha256
      |> :crypto.hash(:erlang.term_to_binary(normalized, [:deterministic]))
      |> Base.encode64()
    else
      _ -> nil
    end
  end

  def server_tools?(parts), do: Enum.any?(parts, &server_tool_part?/1)

  defp server_tool_part?(%{"toolCall" => %{}}), do: true
  defp server_tool_part?(%{"toolResponse" => %{}}), do: true
  defp server_tool_part?(_part), do: false

  defp tool_history_part?(%{"functionCall" => %{"id" => id}})
       when is_binary(id) and id != "",
       do: true

  defp tool_history_part?(part), do: server_tool_part?(part)
end

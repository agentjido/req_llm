defmodule ReqLLM.Providers.Google.ToolHistory do
  @moduledoc false

  alias ReqLLM.Message

  @doc """
  Selects the complete Gemini turn when it has server tool parts or a native
  function call ID. Replay keeps signatures on their original parts and lets
  a later function result refer to the original call.
  """
  def replay_parts(parts) do
    if Enum.any?(parts, &tool_history_part?/1), do: parts
  end

  def preserve(%{message: %Message{} = message} = response, [_ | _] = parts) do
    metadata = Map.put(message.metadata, "google_tool_history", parts)
    %{response | message: %{message | metadata: metadata}}
  end

  def preserve(response, _parts), do: response

  def server_tools?(parts), do: Enum.any?(parts, &server_tool_part?/1)

  defp server_tool_part?(%{"toolCall" => %{}}), do: true
  defp server_tool_part?(%{"toolResponse" => %{}}), do: true
  defp server_tool_part?(_part), do: false

  defp tool_history_part?(%{"functionCall" => %{"id" => id}})
       when is_binary(id) and id != "",
       do: true

  defp tool_history_part?(part), do: server_tool_part?(part)
end

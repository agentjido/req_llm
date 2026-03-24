defmodule ReqLLM.Streaming.WebSocketProtocol do
  @moduledoc false

  @terminal_types ["response.completed", "response.incomplete"]

  @spec parse_message(binary(), binary()) ::
          {:ok, [map()], binary()} | {:incomplete, binary()} | {:error, term()}
  def parse_message(chunk, buffer \\ "")

  def parse_message(chunk, buffer) when is_binary(chunk) and is_binary(buffer) do
    payload = buffer <> chunk

    case Jason.decode(payload) do
      {:ok, data} when is_map(data) ->
        {:ok, [%{data: data, event: event_type(data)}], ""}

      {:ok, data} ->
        {:ok, [%{data: data}], ""}

      {:error, %Jason.DecodeError{position: position}} when position >= byte_size(payload) ->
        {:incomplete, payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def parse_message(_chunk, buffer), do: {:incomplete, buffer}

  @spec terminal_message?(binary()) :: boolean()
  def terminal_message?(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, data} when is_map(data) ->
        terminal_event?(%{data: data})

      _ ->
        false
    end
  end

  @spec error_message?(binary()) :: boolean()
  def error_message?(message) when is_binary(message) do
    case Jason.decode(message) do
      {:ok, data} when is_map(data) ->
        error_event?(%{data: data})

      _ ->
        false
    end
  end

  @spec decode_message(binary()) :: {:ok, map()} | {:error, term()}
  def decode_message(message) when is_binary(message) do
    Jason.decode(message)
  end

  @spec event_type(map()) :: String.t() | nil
  def event_type(data) when is_map(data) do
    data["event"] || data["type"]
  end

  @spec terminal_event?(map()) :: boolean()
  def terminal_event?(%{data: %{"type" => type}}), do: type in @terminal_types
  def terminal_event?(%{data: %{"event" => type}}), do: type in @terminal_types
  def terminal_event?(_event), do: false

  @spec error_event?(map()) :: boolean()
  def error_event?(%{data: %{"type" => "error"}}), do: true
  def error_event?(%{data: %{"event" => "error"}}), do: true
  def error_event?(%{data: %{"error" => _error}}), do: true
  def error_event?(_event), do: false
end

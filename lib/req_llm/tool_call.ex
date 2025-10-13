defmodule ReqLLM.ToolCall do
  @moduledoc """
  Represents a single tool call from an assistant message.

  This struct matches the OpenAI Chat Completions API wire format:

      {
        "id": "call_abc123",
        "type": "function",
        "function": {
          "name": "get_weather",
          "arguments": "{\"location\":\"Paris\"}"
        }
      }

  ## Fields

  - `id` - Unique call identifier (auto-generated if nil)
  - `type` - Always "function" (reserved for future extensibility)
  - `function` - Map with `name` (string) and `arguments` (JSON string)

  ## Examples

      iex> ToolCall.new("call_abc", "get_weather", ~s({"location":"Paris"}))
      %ReqLLM.ToolCall{
        id: "call_abc",
        type: "function",
        function: %{name: "get_weather", arguments: ~s({"location":"Paris"})}
      }

      iex> ToolCall.new(nil, "get_time", "{}")
      %ReqLLM.ToolCall{
        id: "call_..." # auto-generated
        type: "function",
        function: %{name: "get_time", arguments: "{}"}
      }
  """

  use TypedStruct

  typedstruct enforce: true do
    field(:id, String.t(), enforce: true)
    field(:type, String.t(), default: "function", enforce: true)
    field(:function, %{name: String.t(), arguments: String.t()}, enforce: true)
  end

  @doc """
  Create a new ToolCall with OpenAI-compatible structure.

  ## Parameters

  - `id` - Unique identifier (generates "call_<uuid>" if nil)
  - `name` - Function name
  - `arguments_json` - Arguments as JSON-encoded string

  ## Examples

      ToolCall.new("call_123", "get_weather", ~s({"location":"SF"}))
      ToolCall.new(nil, "get_time", "{}")
  """
  @spec new(String.t() | nil, String.t(), String.t()) :: t()
  def new(id, name, arguments_json) do
    %__MODULE__{
      id: id || generate_id(),
      type: "function",
      function: %{
        name: name,
        arguments: arguments_json
      }
    }
  end

  defp generate_id do
    "call_#{Uniq.UUID.uuid7()}"
  end

  defimpl Jason.Encoder do
    def encode(%{id: id, type: type, function: function}, opts) do
      Jason.Encode.map(
        %{
          "id" => id,
          "type" => type,
          "function" => %{
            "name" => function.name,
            "arguments" => function.arguments
          }
        },
        opts
      )
    end
  end

  defimpl Inspect do
    def inspect(%{id: id, function: %{name: name, arguments: args}}, _opts) do
      "#ToolCall<#{id}: #{name}(#{args})>"
    end
  end
end

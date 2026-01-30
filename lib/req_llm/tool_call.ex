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

  @schema Zoi.struct(__MODULE__, %{
            id: Zoi.string(),
            type: Zoi.string() |> Zoi.default("function"),
            function: Zoi.map()
          })

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for this module"
  def schema, do: @schema

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

  @doc """
  Extract the function name from a ToolCall.
  """
  @spec name(t()) :: String.t()
  def name(%__MODULE__{function: %{name: n}}), do: n

  @doc """
  Extract the arguments JSON string from a ToolCall.
  """
  @spec args_json(t()) :: String.t()
  def args_json(%__MODULE__{function: %{arguments: a}}), do: a

  @doc """
  Extract and decode the arguments as a map from a ToolCall.
  Returns nil if decoding fails.
  """
  @spec args_map(t()) :: map() | nil
  def args_map(%__MODULE__{function: %{arguments: json}}) do
    case Jason.decode(json) do
      {:ok, map} -> map
      {:error, _} -> nil
    end
  end

  @doc """
  Check if a ToolCall matches the given function name.
  """
  @spec matches_name?(t(), String.t()) :: boolean()
  def matches_name?(%__MODULE__{function: %{name: n}}, expected_name), do: n == expected_name

  @doc """
  Find the first tool call matching the given name and return its decoded arguments.
  Returns nil if no match found or if arguments cannot be decoded.
  """
  @spec find_args([t()], String.t()) :: map() | nil
  def find_args(tool_calls, name) do
    tool_calls
    |> Enum.find(&matches_name?(&1, name))
    |> case do
      nil -> nil
      call -> args_map(call)
    end
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

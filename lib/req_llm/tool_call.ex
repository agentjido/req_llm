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

  `ToolCall` is a struct, not an `Access`-compatible map. Read fields with
  `call.id`, `call.function.name`, and `call.function.arguments`, or use
  `to_map/1` when a plain map with decoded arguments is more convenient.

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

  @doc """
  Create a ToolCall representing a server-side builtin invocation that the
  provider executed on the model's behalf (e.g. OpenAI Responses API
  `web_search_call`, `file_search_call`).

  These calls are exposed in `message.tool_calls` for inspection and
  observability — the OTel GenAI bridge surfaces them as `tool_call` parts
  in `gen_ai.output.messages`. They are **not replayable**: the provider
  already executed them, and the OpenAI Responses request schema rejects
  them in `input`. Request encoders, `finish_reason` derivation, and tool
  call ID sanitisers must skip entries where `builtin?(tc)` is true.

  `arguments_json` should be a JSON-encoded string capturing whatever
  per-call payload the provider returned (action, query, result URLs, etc.).
  """
  @spec new_builtin(String.t() | nil, String.t(), String.t()) :: t()
  def new_builtin(id, name, arguments_json) do
    %__MODULE__{
      id: id || generate_id(),
      type: "function",
      function: %{
        name: name,
        arguments: arguments_json,
        builtin?: true
      }
    }
  end

  @doc """
  Returns true when the ToolCall (or tool-call-shaped map) represents a
  server-side builtin invocation. Handles both OpenAI-shaped wrappers and
  bare maps: unwraps a nested `:function` map when present.

  Prefer this over `flagged_builtin?/1` whenever you have a `%ToolCall{}`
  or a map that may carry the OpenAI `function:` nesting.
  """
  @spec builtin?(t() | map()) :: boolean()
  def builtin?(%__MODULE__{function: function}) when is_map(function),
    do: flagged_builtin?(function)

  def builtin?(map) when is_map(map) do
    function = Map.get(map, :function) || Map.get(map, "function") || %{}
    flagged_builtin?(map) or flagged_builtin?(function)
  end

  def builtin?(_), do: false

  @doc """
  Returns true when the given map carries a truthy `:builtin?` (or
  `"builtin?"`) flag **directly on it**. Does not unwrap a nested
  `:function` map — use it for chunk metadata or raw tool-call shapes
  that don't have the OpenAI `function` nesting.

  For structured `%ToolCall{}` or OpenAI-wrapped maps, prefer `builtin?/1`.
  """
  @spec flagged_builtin?(any()) :: boolean()
  def flagged_builtin?(map) when is_map(map) do
    Map.get(map, :builtin?) == true or Map.get(map, "builtin?") == true
  end

  def flagged_builtin?(_), do: false

  @deprecated "Use flagged_builtin?/1 instead — the rename makes the flag-only semantics explicit"
  @spec builtin_flag?(any()) :: boolean()
  def builtin_flag?(map), do: flagged_builtin?(map)

  @doc """
  Sets `:builtin? => true` on `map` when `flag` is `true`; otherwise returns
  `map` unchanged. Used by stream/response builders that propagate the
  builtin marker onto plain tool-call maps before they reach `new_builtin/3`.
  """
  @spec put_builtin_flag(map(), boolean()) :: map()
  def put_builtin_flag(map, true), do: Map.put(map, :builtin?, true)
  def put_builtin_flag(map, _), do: map

  @doc """
  Returns metadata attached to a tool call or tool-call-shaped map.
  """
  @spec metadata(term()) :: map()
  def metadata(%__MODULE__{function: function}) when is_map(function), do: metadata(function)
  def metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  def metadata(%{"metadata" => metadata}) when is_map(metadata), do: metadata
  def metadata(%{function: function}) when is_map(function), do: metadata(function)
  def metadata(%{"function" => function}) when is_map(function), do: metadata(function)
  def metadata(_), do: %{}

  @doc """
  Attaches metadata to a ToolCall without changing provider wire encoding.
  """
  @spec put_metadata(t(), map()) :: t()
  def put_metadata(%__MODULE__{} = call, metadata)
      when is_map(metadata) and map_size(metadata) > 0 do
    function =
      Map.update(call.function, :metadata, metadata, fn
        existing when is_map(existing) -> Map.merge(existing, metadata)
        _existing -> metadata
      end)

    %{call | function: function}
  end

  def put_metadata(%__MODULE__{} = call, _metadata), do: call

  defp generate_id do
    "call_#{ReqLLM.ID.uuid7()}"
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
  @spec args_map(t(), keyword()) :: map() | nil
  def args_map(%__MODULE__{function: %{arguments: json}}, opts \\ []) do
    case ReqLLM.JSON.decode(json, opts) do
      {:ok, map} -> map
      {:error, _} -> nil
    end
  end

  @doc """
  Convert a ToolCall to a flat map with decoded arguments.

  Returns a map with `:id`, `:name`, and `:arguments` keys.
  Arguments are decoded from JSON; returns empty map if decoding fails.

  ## Examples

      iex> tc = ToolCall.new("call_123", "get_weather", ~s({"location":"Paris"}))
      iex> ToolCall.to_map(tc)
      %{id: "call_123", name: "get_weather", arguments: %{"location" => "Paris"}}

      iex> tc = ToolCall.new("call_456", "get_time", "{}")
      iex> ToolCall.to_map(tc)
      %{id: "call_456", name: "get_time", arguments: %{}}
  """
  @spec to_map(t(), keyword()) :: %{id: String.t(), name: String.t(), arguments: map()}
  def to_map(%__MODULE__{id: id, function: %{name: name}} = tc, opts \\ []) do
    %{
      id: id,
      name: name,
      arguments: args_map(tc, opts) || %{}
    }
    |> maybe_put_metadata(metadata(tc))
  end

  @doc """
  Normalize a map or ToolCall to the standard `%{id, name, arguments}` format.

  Accepts ToolCall structs or plain maps with atom/string keys.
  Arguments are decoded from JSON if provided as a string.

  ## Examples

      iex> ToolCall.from_map(%{"id" => "call_123", "name" => "get_weather", "arguments" => ~s({"location":"Paris"})})
      %{id: "call_123", name: "get_weather", arguments: %{"location" => "Paris"}}

      iex> tc = ToolCall.new("call_456", "get_time", "{}")
      iex> ToolCall.from_map(tc)
      %{id: "call_456", name: "get_time", arguments: %{}}
  """
  @spec from_map(t() | map(), keyword()) :: %{id: String.t(), name: String.t(), arguments: map()}
  def from_map(tool_call, opts \\ [])

  def from_map(%__MODULE__{} = tc, opts), do: to_map(tc, opts)

  def from_map(%{"name" => _} = map, opts) do
    %{
      id: map["id"] || generate_id(),
      name: map["name"],
      arguments: parse_arguments(map["arguments"] || %{}, opts)
    }
    |> maybe_put_metadata(metadata(map))
  end

  def from_map(map, opts) when is_map(map) do
    %{
      id: map[:id] || generate_id(),
      name: map[:name],
      arguments: parse_arguments(map[:arguments] || %{}, opts)
    }
    |> maybe_put_metadata(metadata(map))
  end

  defp maybe_put_metadata(map, metadata) when is_map(metadata) and map_size(metadata) > 0 do
    Map.put(map, :metadata, metadata)
  end

  defp maybe_put_metadata(map, _metadata), do: map

  defp parse_arguments(args, opts) when is_binary(args) do
    case ReqLLM.JSON.decode(args, opts) do
      {:ok, parsed} -> parsed
      {:error, _} -> %{}
    end
  end

  defp parse_arguments(args, _opts) when is_map(args), do: args
  defp parse_arguments(_, _opts), do: %{}

  @doc """
  Check if a ToolCall matches the given function name.
  """
  @spec matches_name?(t(), String.t()) :: boolean()
  def matches_name?(%__MODULE__{function: %{name: n}}, expected_name), do: n == expected_name

  @doc """
  Find the first tool call matching the given name and return its decoded arguments.
  Returns nil if no match found or if arguments cannot be decoded.
  """
  @spec find_args([t()], String.t(), keyword()) :: map() | nil
  def find_args(tool_calls, name, opts \\ []) do
    tool_calls
    |> Enum.find(&matches_name?(&1, name))
    |> case do
      nil -> nil
      call -> args_map(call, opts)
    end
  end

  defimpl Jason.Encoder do
    def encode(%{id: id, type: type, function: function}, opts) do
      function_map =
        %{
          "name" => function.name,
          "arguments" => function.arguments
        }
        |> maybe_put_builtin(function)

      Jason.Encode.map(
        %{
          "id" => id,
          "type" => type,
          "function" => function_map
        },
        opts
      )
    end

    defp maybe_put_builtin(map, function) when is_map(function) do
      if Map.get(function, :builtin?) == true or Map.get(function, "builtin?") == true do
        Map.put(map, "builtin?", true)
      else
        map
      end
    end
  end

  defimpl Inspect do
    def inspect(%{id: id, function: %{name: name, arguments: args}}, _opts) do
      "#ToolCall<#{id}: #{name}(#{args})>"
    end
  end
end

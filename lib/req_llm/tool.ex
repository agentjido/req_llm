defmodule ReqLLM.Tool do
  @moduledoc """
  Tool definition for AI model function calling.

  Tools enable AI models to call external functions, perform actions, and retrieve information.
  Each tool has a name, description, parameters schema, and a callback function to execute.

  ## Basic Usage

      # Create a simple tool
      {:ok, tool} = ReqLLM.Tool.new(
        name: "get_weather",
        description: "Get current weather for a location",
        parameter_schema: [
          location: [type: :string, required: true, doc: "City name"]
        ],
        callback: {WeatherService, :get_current_weather}
      )

      # Execute the tool
      {:ok, result} = ReqLLM.Tool.execute(tool, %{location: "San Francisco"})

      # Get provider-specific schema
      anthropic_schema = ReqLLM.Tool.to_schema(tool, :anthropic)

  ## Parameters Schema

  Parameters are defined using NimbleOptions-compatible keyword lists:

      parameter_schema: [
        location: [type: :string, required: true, doc: "City name"],
        units: [type: :string, default: "celsius", doc: "Temperature units"]
      ]

  ## Callback Formats

  Multiple callback formats are supported:

      # Module and function (args passed as single argument)
      callback: {MyModule, :my_function}

      # Module, function, and additional args (prepended to input)
      callback: {MyModule, :my_function, [:extra, :args]}

      # Anonymous function
      callback: fn args -> {:ok, "result"} end

  ## Provider Schema Formats

  Tools can be converted to provider-specific formats:

      # Anthropic tool format
      anthropic_schema = ReqLLM.Tool.to_schema(tool, :anthropic)

  ## Functions

    * `new/1` - Creates a new Tool from the given options
    * `new!/1` - Creates a new Tool from the given options, raising on error
    * `execute/2` - Executes a tool with the given input parameters
    * `to_schema/2` - Converts a Tool to provider-specific schema format
    * `to_json_schema/1` - Converts a Tool to JSON Schema format for LLM integration
    * `valid_name?/1` - Validates a tool name for compliance with function calling standards

  """

  @type callback_mfa :: {module(), atom()} | {module(), atom(), list()}
  @type callback_fun :: (map() -> {:ok, term()} | {:error, term()})
  @type callback :: callback_mfa() | callback_fun()

  @schema Zoi.struct(__MODULE__, %{
            name: Zoi.string() |> Zoi.required(),
            description: Zoi.string() |> Zoi.required(),
            parameter_schema: Zoi.any() |> Zoi.default([]),
            compiled: Zoi.any() |> Zoi.default(nil),
            callback: Zoi.any() |> Zoi.required(),
            strict: Zoi.boolean() |> Zoi.default(false)
          })

  @typedoc "A tool definition for AI model function calling"
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema

  @type tool_opts :: [
          name: String.t(),
          description: String.t(),
          parameter_schema: keyword() | map(),
          callback: callback(),
          strict: boolean()
        ]

  # NimbleOptions schema for tool creation validation
  @tool_schema NimbleOptions.new!(
                 name: [
                   type: :string,
                   required: true,
                   doc: "Tool name (must be valid identifier)"
                 ],
                 description: [
                   type: :string,
                   required: true,
                   doc: "Tool description for AI model"
                 ],
                 parameter_schema: [
                   type: :any,
                   default: [],
                   doc: "Parameter schema as keyword list (NimbleOptions) or map (JSON Schema)"
                 ],
                 callback: [
                   type: :any,
                   required: true,
                   doc: "Callback function or MFA tuple"
                 ],
                 strict: [
                   type: :boolean,
                   default: false,
                   doc: "Enable strict mode for OpenAI structured outputs"
                 ]
               )

  @doc """
  Creates a new Tool from the given options.

  ## Parameters

    * `opts` - Tool options as keyword list

  ## Options

    * `:name` - Tool name (required, must be valid identifier)
    * `:description` - Tool description for AI model (required)
    * `:parameter_schema` - Parameter schema as NimbleOptions keyword list or JSON Schema map (optional)
    * `:callback` - Callback function or MFA tuple (required)

  ## Examples

      # Using NimbleOptions keyword list
      {:ok, tool} = ReqLLM.Tool.new(
        name: "get_weather",
        description: "Get current weather",
        parameter_schema: [
          location: [type: :string, required: true]
        ],
        callback: {WeatherService, :get_weather}
      )

      # Using raw JSON Schema map
      {:ok, tool} = ReqLLM.Tool.new(
        name: "get_weather",
        description: "Get current weather",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "location" => %{"type" => "string"}
          },
          "required" => ["location"]
        },
        callback: {WeatherService, :get_weather}
      )

      # Using Elixir typespec syntax via JSONSpec (https://hex.pm/packages/json_spec)
      import JSONSpec

      {:ok, tool} = ReqLLM.Tool.new(
        name: "get_weather",
        description: "Get current weather",
        parameter_schema: schema(
          %{required(:location) => String.t(), optional(:units) => :celsius | :fahrenheit},
          doc: [location: "City name", units: "Temperature units"]
        ),
        callback: {WeatherService, :get_weather}
      )

  """
  @spec new(tool_opts()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with {:ok, validated_opts} <- NimbleOptions.validate(opts, @tool_schema),
         :ok <- validate_name(validated_opts[:name]),
         :ok <- validate_parameter_schema(validated_opts[:parameter_schema]),
         :ok <- validate_callback(validated_opts[:callback]),
         {:ok, compiled_schema} <- compile_parameter_schema(validated_opts[:parameter_schema]) do
      tool = %__MODULE__{
        name: validated_opts[:name],
        description: validated_opts[:description],
        parameter_schema: validated_opts[:parameter_schema],
        compiled: compiled_schema,
        callback: validated_opts[:callback],
        strict: validated_opts[:strict] || false
      }

      {:ok, tool}
    else
      {:error, %NimbleOptions.ValidationError{} = error} ->
        {:error,
         ReqLLM.Error.Validation.Error.exception(
           tag: :invalid_options,
           reason: Exception.message(error),
           context: []
         )}

      {:error, reason} when is_binary(reason) ->
        {:error, ReqLLM.Error.Invalid.Parameter.exception(parameter: reason)}

      error ->
        error
    end
  end

  def new(_) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(parameter: "Tool options must be a keyword list")}
  end

  @doc """
  Creates a new Tool from the given options, raising on error.

  See `new/1` for details.

  ## Examples

      tool = ReqLLM.Tool.new!(
        name: "get_weather",
        description: "Get current weather",
        callback: {WeatherService, :get_weather}
      )

  """
  @spec new!(tool_opts()) :: t() | no_return()
  def new!(opts) do
    case new(opts) do
      {:ok, tool} -> tool
      {:error, error} -> raise error
    end
  end

  @doc """
  Executes a tool with the given input parameters.

  Validates input parameters against the tool's schema and calls the callback function.
  The callback is expected to return `{:ok, result}` or `{:error, reason}`.
  Tool results can be plain text, structured data, content parts, or a `ReqLLM.ToolResult`.

  ## Parameters

    * `tool` - Tool struct
    * `input` - Input parameters as map

  ## Examples

      {:ok, result} = ReqLLM.Tool.execute(tool, %{location: "San Francisco"})
      #=> {:ok, %{temperature: 72, conditions: "sunny"}}

      {:error, reason} = ReqLLM.Tool.execute(tool, %{invalid: "params"})
      #=> {:error, %ReqLLM.Error.Validation.Error{...}}

  """
  @spec execute(t(), map()) :: {:ok, term()} | {:error, term()}
  def execute(%__MODULE__{} = tool, input) when is_map(input) do
    with {:ok, validated_input} <- validate_input(tool, input) do
      call_callback(tool.callback, validated_input)
    end
  end

  def execute(%__MODULE__{}, input) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "Input must be a map, got: #{inspect(input)}"
     )}
  end

  @doc """
  Converts a Tool to provider-specific schema format.

  Returns a map containing the provider's expected tool format with
  tool name, description, and parameter definitions.

  ## Parameters

    * `tool` - Tool struct
    * `provider` - Provider atom (`:anthropic`, `:openai`, `:google`, `:amazon_bedrock_converse`)

  ## Examples

      # Anthropic tool format
      anthropic_schema = ReqLLM.Tool.to_schema(tool, :anthropic)
      #=> %{
      #     "name" => "get_weather",
      #     "description" => "Get current weather",
      #     "input_schema" => %{...}
      #   }

      # Bedrock Converse tool format
      bedrock_schema = ReqLLM.Tool.to_schema(tool, :amazon_bedrock_converse)
      #=> %{
      #     "toolSpec" => %{
      #       "name" => "get_weather",
      #       "description" => "Get current weather",
      #       "inputSchema" => %{"json" => %{...}}
      #     }
      #   }

  """
  @spec to_schema(t(), atom()) :: map()
  def to_schema(%__MODULE__{} = tool, provider \\ :openai) do
    case provider do
      :anthropic -> ReqLLM.Schema.to_anthropic_format(tool)
      :openai -> ReqLLM.Schema.to_openai_format(tool)
      :google -> ReqLLM.Schema.to_google_format(tool)
      :amazon_bedrock_converse -> ReqLLM.Schema.to_bedrock_converse_format(tool)
      other -> raise ArgumentError, "Unknown provider #{inspect(other)}"
    end
  end

  @doc """
  Converts a Tool to JSON Schema format for LLM integration.

  Backward compatibility function that defaults to OpenAI format.
  Use `to_schema/2` for explicit provider selection.

  ## Examples

      json_schema = ReqLLM.Tool.to_json_schema(tool)
      # Equivalent to: ReqLLM.Tool.to_schema(tool, :openai)

  """
  @spec to_json_schema(t()) :: map()
  def to_json_schema(%__MODULE__{} = tool) do
    to_schema(tool, :openai)
  end

  @doc """
  Validates a tool name for compliance with function calling standards.

  Tool names must be valid identifiers (alphanumeric, underscores, or hyphens, start with letter/underscore).

  ## Examples

      ReqLLM.Tool.valid_name?("get_weather")
      #=> true

      ReqLLM.Tool.valid_name?("get-weather")
      #=> true

      ReqLLM.Tool.valid_name?("123invalid")
      #=> false

  """
  @spec valid_name?(String.t()) :: boolean()
  def valid_name?(name) when is_binary(name) do
    Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*(-[a-zA-Z0-9_]+)*$/, name) and
      String.length(name) <= 64
  end

  def valid_name?(_), do: false

  # Private functions

  defp validate_name(name) do
    if valid_name?(name) do
      :ok
    else
      {:error,
       "Invalid tool name: #{inspect(name)}. Must be valid identifier (alphanumeric, underscore, or hyphen, max 64 chars)"}
    end
  end

  defp validate_parameter_schema(schema) when is_list(schema) or is_map(schema), do: :ok

  defp validate_parameter_schema(schema) do
    {:error,
     "Invalid parameter_schema: #{inspect(schema)}. Must be a keyword list (NimbleOptions) or map (JSON Schema)"}
  end

  defp validate_callback({module, function}) when is_atom(module) and is_atom(function) do
    if function_exported?(module, function, 1) do
      :ok
    else
      {:error, "Callback function #{module}.#{function}/1 does not exist"}
    end
  end

  defp validate_callback({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    arity = length(args) + 1

    if function_exported?(module, function, arity) do
      :ok
    else
      {:error, "Callback function #{module}.#{function}/#{arity} does not exist"}
    end
  end

  defp validate_callback(fun) when is_function(fun, 1), do: :ok

  defp validate_callback(callback) do
    {:error,
     "Invalid callback: #{inspect(callback)}. Must be {module, function}, {module, function, args}, or function/1"}
  end

  defp compile_parameter_schema([]), do: {:ok, nil}

  defp compile_parameter_schema(parameter_schema) do
    with {:ok, compiled_result} <- ReqLLM.Schema.compile(parameter_schema) do
      # Return just the compiled NimbleOptions schema (or nil for maps)
      {:ok, compiled_result.compiled}
    end
  end

  defp validate_input(%__MODULE__{compiled: nil}, input), do: {:ok, input}

  defp validate_input(%__MODULE__{compiled: schema, parameter_schema: parameter_schema}, input) do
    normalized_input = normalize_input_keys(input, parameter_schema)

    try do
      case NimbleOptions.validate(normalized_input, schema) do
        {:ok, validated_input} ->
          {:ok, validated_input}

        {:error, error} ->
          {:error,
           ReqLLM.Error.Validation.Error.exception(
             tag: :parameter_validation,
             reason: Exception.message(error),
             context: [input: input]
           )}
      end
    rescue
      error ->
        {:error,
         ReqLLM.Error.Validation.Error.exception(
           tag: :parameter_validation,
           reason: Exception.message(error),
           context: [input: input]
         )}
    end
  end

  defp normalize_input_keys(input, parameter_schema)
       when is_map(input) and is_list(parameter_schema) do
    schema_entries =
      parameter_schema
      |> Enum.filter(fn
        {key, opts} when is_atom(key) and is_list(opts) -> true
        _ -> false
      end)
      |> Map.new()

    schema_key_map =
      schema_entries
      |> Map.keys()
      |> Map.new(fn key -> {Atom.to_string(key), key} end)

    Map.new(input, fn {key, value} ->
      {normalized_key, field_opts} =
        normalize_key_and_field_opts(key, schema_key_map, schema_entries)

      {normalized_key, normalize_typed_value(value, field_opts)}
    end)
  end

  defp normalize_input_keys(input, _parameter_schema), do: input

  defp normalize_key_and_field_opts(key, schema_key_map, schema_entries) when is_binary(key) do
    case Map.fetch(schema_key_map, key) do
      {:ok, atom_key} -> {atom_key, Map.get(schema_entries, atom_key)}
      :error -> {key, nil}
    end
  end

  defp normalize_key_and_field_opts(key, _schema_key_map, schema_entries) when is_atom(key) do
    {key, Map.get(schema_entries, key)}
  end

  defp normalize_key_and_field_opts(key, _schema_key_map, _schema_entries), do: {key, nil}

  defp normalize_typed_value(value, opts) when is_list(opts) do
    normalize_typed_value(value, Keyword.get(opts, :type), opts)
  end

  defp normalize_typed_value(value, _opts), do: value

  defp normalize_typed_value(value, :map, opts) when is_map(value) do
    case nested_map_schema(opts) do
      schema when is_list(schema) -> normalize_input_keys(value, schema)
      _ -> normalize_existing_atom_map(value)
    end
  end

  defp normalize_typed_value(value, {:map, schema}, _opts)
       when is_map(value) and is_list(schema) do
    normalize_input_keys(value, schema)
  end

  defp normalize_typed_value(value, {:map, key_type, value_type}, _opts) when is_map(value) do
    normalize_typed_map(value, key_type, value_type)
  end

  defp normalize_typed_value(value, {:list, :map}, opts) when is_list(value) do
    case nested_map_schema(opts) do
      schema when is_list(schema) ->
        Enum.map(value, &normalize_map_with_schema(&1, schema))

      _ ->
        Enum.map(value, &normalize_list_item(&1, :map))
    end
  end

  defp normalize_typed_value(value, {:list, {:map, schema}}, _opts)
       when is_list(value) and is_list(schema) do
    Enum.map(value, &normalize_map_with_schema(&1, schema))
  end

  defp normalize_typed_value(value, {:list, inner_type}, _opts) when is_list(value) do
    Enum.map(value, &normalize_list_item(&1, inner_type))
  end

  defp normalize_typed_value(value, {:or, subtypes}, opts) when is_list(subtypes) do
    Enum.reduce(subtypes, value, fn subtype, acc ->
      normalize_typed_value(acc, subtype, opts)
    end)
  end

  defp normalize_typed_value(value, {:tuple, subtypes}, _opts)
       when is_tuple(value) and is_list(subtypes) do
    tuple_items = Tuple.to_list(value)

    tuple_items
    |> Enum.with_index()
    |> Enum.map(fn {item, idx} ->
      case Enum.fetch(subtypes, idx) do
        {:ok, subtype} -> normalize_list_item(item, subtype)
        :error -> item
      end
    end)
    |> List.to_tuple()
  end

  defp normalize_typed_value(value, _type, _opts), do: value

  defp normalize_map_with_schema(value, schema) when is_map(value) do
    normalize_input_keys(value, schema)
  end

  defp normalize_map_with_schema(value, _schema), do: value

  defp normalize_list_item(value, :map) when is_map(value), do: normalize_existing_atom_map(value)

  defp normalize_list_item(value, {:map, schema}) when is_map(value) and is_list(schema) do
    normalize_input_keys(value, schema)
  end

  defp normalize_list_item(value, {:map, key_type, value_type}) when is_map(value) do
    normalize_typed_map(value, key_type, value_type)
  end

  defp normalize_list_item(value, {:list, inner_type}) when is_list(value) do
    Enum.map(value, &normalize_list_item(&1, inner_type))
  end

  defp normalize_list_item(value, {:or, subtypes}) when is_list(subtypes) do
    Enum.reduce(subtypes, value, fn subtype, acc ->
      normalize_list_item(acc, subtype)
    end)
  end

  defp normalize_list_item(value, {:tuple, subtypes})
       when is_tuple(value) and is_list(subtypes) do
    tuple_items = Tuple.to_list(value)

    tuple_items
    |> Enum.with_index()
    |> Enum.map(fn {item, idx} ->
      case Enum.fetch(subtypes, idx) do
        {:ok, subtype} -> normalize_list_item(item, subtype)
        :error -> item
      end
    end)
    |> List.to_tuple()
  end

  defp normalize_list_item(value, _type), do: value

  defp normalize_typed_map(map, :atom, value_type) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        {to_existing_atom_or_original(key), normalize_list_item(value, value_type)}

      {key, value} ->
        {key, normalize_list_item(value, value_type)}
    end)
  end

  defp normalize_typed_map(map, _key_type, value_type) do
    Map.new(map, fn {key, value} ->
      {key, normalize_list_item(value, value_type)}
    end)
  end

  defp normalize_existing_atom_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        {to_existing_atom_or_original(key), normalize_existing_atom_value(value)}

      {key, value} ->
        {key, normalize_existing_atom_value(value)}
    end)
  end

  defp normalize_existing_atom_value(value) when is_map(value),
    do: normalize_existing_atom_map(value)

  defp normalize_existing_atom_value(value) when is_list(value),
    do: Enum.map(value, &normalize_existing_atom_value/1)

  defp normalize_existing_atom_value(value), do: value

  defp nested_map_schema(opts) do
    case Keyword.get(opts, :keys) do
      schema when is_list(schema) ->
        schema

      _ ->
        case Keyword.get(opts, :properties) do
          schema when is_list(schema) -> schema
          _ -> nil
        end
    end
  end

  defp to_existing_atom_or_original(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end

  defp call_callback({module, function}, input) do
    apply(module, function, [input])
  rescue
    error ->
      {:error,
       ReqLLM.Error.Unknown.Unknown.exception(
         error: "Callback execution failed: #{Exception.message(error)}"
       )}
  end

  defp call_callback({module, function, args}, input) do
    apply(module, function, args ++ [input])
  rescue
    error ->
      {:error,
       ReqLLM.Error.Unknown.Unknown.exception(
         error: "Callback execution failed: #{Exception.message(error)}"
       )}
  end

  defp call_callback(fun, input) when is_function(fun, 1) do
    fun.(input)
  rescue
    error ->
      {:error,
       ReqLLM.Error.Unknown.Unknown.exception(
         error: "Callback execution failed: #{Exception.message(error)}"
       )}
  end

  defimpl Inspect do
    def inspect(%{name: name, parameter_schema: schema}, opts) do
      param_desc =
        cond do
          # NimbleOptions format (list of keyword tuples)
          is_list(schema) ->
            param_count = length(schema)
            if param_count == 0, do: "no params", else: "#{param_count} params"

          # JSON Schema format (map)
          is_map(schema) ->
            prop_count = map_size(Map.get(schema, "properties", %{}))

            if prop_count == 0 do
              "no params (JSON Schema)"
            else
              "#{prop_count} params (JSON Schema)"
            end

          # Unknown format
          true ->
            "unknown schema format"
        end

      Inspect.Algebra.concat([
        "#Tool<",
        Inspect.Algebra.to_doc(name, opts),
        " ",
        param_desc,
        ">"
      ])
    end
  end
end

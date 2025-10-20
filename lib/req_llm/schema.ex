defmodule ReqLLM.Schema do
  @moduledoc """
  Single schema authority for NimbleOptions ↔ JSON Schema conversion.

  This module consolidates all schema conversion logic, providing unified functions
  for converting keyword schemas to both NimbleOptions compiled schemas and JSON Schema format.
  Supports all common NimbleOptions types and handles nested schemas.

  Also supports direct JSON Schema pass-through when a map is provided instead of a keyword list.

  ## Core Functions

  - `compile/1` - Convert keyword schema to NimbleOptions compiled schema, or pass through maps
  - `to_json/1` - Convert keyword schema to JSON Schema format, or pass through maps


  ## Basic Usage

      # Compile keyword schema to NimbleOptions
      {:ok, compiled} = ReqLLM.Schema.compile([
        name: [type: :string, required: true, doc: "User name"],
        age: [type: :pos_integer, doc: "User age"]
      ])

      # Convert keyword schema to JSON Schema
      json_schema = ReqLLM.Schema.to_json([
        name: [type: :string, required: true, doc: "User name"],
        age: [type: :pos_integer, doc: "User age"]
      ])
      # => %{
      #      "type" => "object",
      #      "properties" => %{
      #        "name" => %{"type" => "string", "description" => "User name"},
      #        "age" => %{"type" => "integer", "minimum" => 1, "description" => "User age"}
      #      },
      #      "required" => ["name"]
      #    }

      # Use raw JSON Schema directly (map pass-through)
      json_schema = ReqLLM.Schema.to_json(%{
        "type" => "object",
        "properties" => %{
          "location" => %{"type" => "string"},
          "units" => %{"type" => "string", "enum" => ["celsius", "fahrenheit"]}
        },
        "required" => ["location"]
      })
      # => Returns the map unchanged



  ## Supported Types

  All common NimbleOptions types are supported:

  - `:string` - String type
  - `:integer` - Integer type
  - `:pos_integer` - Positive integer (adds minimum: 1 constraint)
  - `:float` - Float/number type
  - `:number` - Generic number type
  - `:boolean` - Boolean type
  - `{:list, type}` - Array of specified type
  - `:map` - Object type
  - Custom types fall back to string

  ## Nested Schemas

  Nested schemas are supported through recursive type handling:

      schema = [
        user: [
          type: {:list, :map},
          doc: "List of user objects",
          properties: [
            name: [type: :string, required: true],
            email: [type: :string, required: true]
          ]
        ]
      ]

  """

  @doc """
  Compiles a keyword schema to a NimbleOptions compiled schema.

  Takes a keyword list representing a NimbleOptions schema and compiles it
  into a validated NimbleOptions schema that can be used for validation.

  When a map is provided (raw JSON Schema), returns a wrapper with the original schema
  and no compiled version (pass-through mode).

  ## Parameters

  - `schema` - A keyword list representing a NimbleOptions schema, or a map for raw JSON Schema

  ## Returns

  - `{:ok, compiled_result}` - Compiled schema wrapper with `:schema` and `:compiled` fields
  - `{:error, error}` - Compilation error with details

  ## Examples

      iex> {:ok, result} = ReqLLM.Schema.compile([
      ...>   name: [type: :string, required: true],
      ...>   age: [type: :pos_integer, default: 0]
      ...> ])
      iex> is_map(result) and Map.has_key?(result, :schema)
      true

      iex> {:ok, result} = ReqLLM.Schema.compile(%{"type" => "object", "properties" => %{}})
      iex> result.schema
      %{"type" => "object", "properties" => %{}}

      iex> ReqLLM.Schema.compile("invalid")
      {:error, %ReqLLM.Error.Invalid.Parameter{}}

  """
  @spec compile(keyword() | map() | any()) ::
          {:ok, %{schema: keyword() | map(), compiled: NimbleOptions.t() | nil}}
          | {:error, ReqLLM.Error.t()}
  def compile(schema) when is_map(schema) do
    {:ok, %{schema: schema, compiled: nil}}
  end

  def compile(schema) when is_list(schema) do
    compiled = NimbleOptions.new!(schema)
    {:ok, %{schema: schema, compiled: compiled}}
  rescue
    e ->
      {:error,
       ReqLLM.Error.Validation.Error.exception(
         tag: :invalid_schema,
         reason: "Invalid schema: #{Exception.message(e)}",
         context: [schema: schema]
       )}
  end

  def compile(schema) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "Schema must be a keyword list or map, got: #{inspect(schema)}"
     )}
  end

  @doc """
  Converts a keyword schema to JSON Schema format.

  Takes a keyword list of parameter definitions and converts them to
  a JSON Schema object suitable for LLM tool definitions or structured data schemas.

  When a map is provided (raw JSON Schema), returns it unchanged (pass-through mode).

  ## Parameters

  - `schema` - Keyword list of parameter definitions, or a map for raw JSON Schema

  ## Returns

  A map representing the JSON Schema object with properties and required fields.

  ## Examples

      iex> ReqLLM.Schema.to_json([
      ...>   name: [type: :string, required: true, doc: "User name"],
      ...>   age: [type: :integer, doc: "User age"],
      ...>   tags: [type: {:list, :string}, default: [], doc: "User tags"]
      ...> ])
      %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "User name"},
          "age" => %{"type" => "integer", "description" => "User age"},
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "User tags"
          }
        },
        "required" => ["name"]
      }

      iex> ReqLLM.Schema.to_json([])
      %{"type" => "object", "properties" => %{}}

      iex> ReqLLM.Schema.to_json(%{"type" => "object", "properties" => %{"foo" => %{"type" => "string"}}})
      %{"type" => "object", "properties" => %{"foo" => %{"type" => "string"}}}

  """
  @spec to_json(keyword() | map()) :: map()
  def to_json(schema) when is_map(schema), do: schema

  def to_json([]), do: %{"type" => "object", "properties" => %{}}

  def to_json(schema) when is_list(schema) do
    {properties, required} =
      Enum.reduce(schema, {%{}, []}, fn {key, opts}, {props_acc, req_acc} ->
        property_name = to_string(key)
        json_prop = nimble_type_to_json_schema(opts[:type] || :string, opts)

        new_props = Map.put(props_acc, property_name, json_prop)
        new_req = if opts[:required], do: [property_name | req_acc], else: req_acc

        {new_props, new_req}
      end)

    schema_object = %{
      "type" => "object",
      "properties" => properties,
      "additionalProperties" => false
    }

    if required == [] do
      schema_object
    else
      Map.put(schema_object, "required", Enum.reverse(required))
    end
  end

  # Private helper functions

  @doc """
  Converts a NimbleOptions type to JSON Schema property definition.

  Takes a NimbleOptions type atom and options, converting them to the
  corresponding JSON Schema property definition with proper type mapping.

  ## Parameters

  - `type` - The NimbleOptions type atom (e.g., `:string`, `:integer`, `{:list, :string}`)
  - `opts` - Additional options including `:doc` for description

  ## Returns

  A map representing the JSON Schema property definition.

  ## Examples

      iex> ReqLLM.Schema.nimble_type_to_json_schema(:string, doc: "A text field")
      %{"type" => "string", "description" => "A text field"}

      iex> ReqLLM.Schema.nimble_type_to_json_schema({:list, :integer}, [])
      %{"type" => "array", "items" => %{"type" => "integer"}}

      iex> ReqLLM.Schema.nimble_type_to_json_schema(:pos_integer, doc: "Positive number")
      %{"type" => "integer", "minimum" => 1, "description" => "Positive number"}

  """
  @spec nimble_type_to_json_schema(atom() | tuple(), keyword()) :: map()
  def nimble_type_to_json_schema(type, opts) do
    base_schema =
      case type do
        :string ->
          %{"type" => "string"}

        :integer ->
          %{"type" => "integer"}

        :pos_integer ->
          %{"type" => "integer", "minimum" => 1}

        :float ->
          %{"type" => "number"}

        :number ->
          %{"type" => "number"}

        :boolean ->
          %{"type" => "boolean"}

        {:list, :string} ->
          %{"type" => "array", "items" => %{"type" => "string"}}

        {:list, :integer} ->
          %{"type" => "array", "items" => %{"type" => "integer"}}

        {:list, :boolean} ->
          %{"type" => "array", "items" => %{"type" => "boolean"}}

        {:list, :float} ->
          %{"type" => "array", "items" => %{"type" => "number"}}

        {:list, :number} ->
          %{"type" => "array", "items" => %{"type" => "number"}}

        {:list, :pos_integer} ->
          %{"type" => "array", "items" => %{"type" => "integer", "minimum" => 1}}

        # Handle {:list, {:in, choices}} for arrays with enum constraints - must be before general {:list, item_type}
        {:list, {:in, choices}} when is_list(choices) ->
          %{"type" => "array", "items" => %{"type" => "string", "enum" => choices}}

        {:list, {:in, first..last//_step}} ->
          %{
            "type" => "array",
            "items" => %{"type" => "integer", "minimum" => first, "maximum" => last}
          }

        {:list, {:in, %MapSet{} = choices}} ->
          %{
            "type" => "array",
            "items" => %{"type" => "string", "enum" => MapSet.to_list(choices)}
          }

        {:list, {:in, choices}} when is_struct(choices) ->
          try do
            %{
              "type" => "array",
              "items" => %{"type" => "string", "enum" => Enum.to_list(choices)}
            }
          rescue
            _ -> %{"type" => "array", "items" => %{"type" => "string"}}
          end

        {:list, item_type} ->
          %{"type" => "array", "items" => nimble_type_to_json_schema(item_type, [])}

        :map ->
          %{"type" => "object"}

        {:map, _} ->
          %{"type" => "object"}

        :keyword_list ->
          %{"type" => "object"}

        :atom ->
          %{"type" => "string"}

        # Handle :in type for enums and ranges
        {:in, choices} when is_list(choices) ->
          %{"type" => "string", "enum" => choices}

        {:in, first..last//_step} ->
          %{"type" => "integer", "minimum" => first, "maximum" => last}

        {:in, %MapSet{} = choices} ->
          %{"type" => "string", "enum" => MapSet.to_list(choices)}

        {:in, choices} when is_struct(choices) ->
          try do
            %{"type" => "string", "enum" => Enum.to_list(choices)}
          rescue
            _ -> %{"type" => "string"}
          end

        # Fallback to string for unknown types
        _ ->
          %{"type" => "string"}
      end

    # Add description if provided
    case opts[:doc] do
      nil -> base_schema
      doc -> Map.put(base_schema, "description", doc)
    end
  end

  @doc """
  Format a tool into Anthropic tool schema format.

  ## Parameters

    * `tool` - A `ReqLLM.Tool.t()` struct

  ## Returns

  A map containing the Anthropic tool schema format.

  ## Examples

      iex> tool = %ReqLLM.Tool{
      ...>   name: "get_weather",
      ...>   description: "Get current weather",
      ...>   parameter_schema: [
      ...>     location: [type: :string, required: true, doc: "City name"]
      ...>   ],
      ...>   callback: fn _ -> {:ok, %{}} end
      ...> }
      iex> ReqLLM.Schema.to_anthropic_format(tool)
      %{
        "name" => "get_weather",
        "description" => "Get current weather",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "location" => %{"type" => "string", "description" => "City name"}
          },
          "required" => ["location"]
        }
      }

  """
  @spec to_anthropic_format(ReqLLM.Tool.t()) :: map()
  def to_anthropic_format(%ReqLLM.Tool{} = tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "input_schema" => to_json(tool.parameter_schema)
    }
  end

  @doc """
  Format a tool into OpenAI tool schema format.

  ## Parameters

    * `tool` - A `ReqLLM.Tool.t()` struct

  ## Returns

  A map containing the OpenAI tool schema format.

  ## Examples

      iex> tool = %ReqLLM.Tool{
      ...>   name: "get_weather",
      ...>   description: "Get current weather",
      ...>   parameter_schema: [
      ...>     location: [type: :string, required: true, doc: "City name"]
      ...>   ],
      ...>   callback: fn _ -> {:ok, %{}} end
      ...> }
      iex> ReqLLM.Schema.to_openai_format(tool)
      %{
        "type" => "function",
        "function" => %{
          "name" => "get_weather",
          "description" => "Get current weather",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "location" => %{"type" => "string", "description" => "City name"}
            },
            "required" => ["location"]
          }
        }
      }

  """
  @spec to_openai_format(ReqLLM.Tool.t()) :: map()
  def to_openai_format(%ReqLLM.Tool{} = tool) do
    function_def = %{
      "name" => tool.name,
      "description" => tool.description,
      "parameters" => to_json(tool.parameter_schema)
    }

    function_def =
      if tool.strict do
        Map.put(function_def, "strict", true)
      else
        function_def
      end

    %{
      "type" => "function",
      "function" => function_def
    }
  end

  @doc """
  Format a tool into Google tool schema format.

  ## Parameters

    * `tool` - A `ReqLLM.Tool.t()` struct

  ## Returns

  A map containing the Google tool schema format.

  ## Examples

      iex> tool = %ReqLLM.Tool{
      ...>   name: "get_weather",
      ...>   description: "Get current weather",
      ...>   parameter_schema: [
      ...>     location: [type: :string, required: true, doc: "City name"]
      ...>   ],
      ...>   callback: fn _ -> {:ok, %{}} end
      ...> }
      iex> ReqLLM.Schema.to_google_format(tool)
      %{
        "name" => "get_weather",
        "description" => "Get current weather",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "location" => %{"type" => "string", "description" => "City name"}
          },
          "required" => ["location"]
        }
      }

  """
  @spec to_google_format(ReqLLM.Tool.t()) :: map()
  def to_google_format(%ReqLLM.Tool{} = tool) do
    json_schema = to_json(tool.parameter_schema)
    parameters = Map.delete(json_schema, "additionalProperties")

    %{
      "name" => tool.name,
      "description" => tool.description,
      "parameters" => parameters
    }
  end

  @doc """
  Format a tool into AWS Bedrock Converse API tool schema format.

  ## Parameters

    * `tool` - A `ReqLLM.Tool.t()` struct

  ## Returns

  A map containing the Bedrock Converse tool schema format.

  ## Examples

      iex> tool = %ReqLLM.Tool{
      ...>   name: "get_weather",
      ...>   description: "Get current weather",
      ...>   parameter_schema: [
      ...>     location: [type: :string, required: true, doc: "City name"]
      ...>   ],
      ...>   callback: fn _ -> {:ok, %{}} end
      ...> }
      iex> ReqLLM.Schema.to_bedrock_converse_format(tool)
      %{
        "toolSpec" => %{
          "name" => "get_weather",
          "description" => "Get current weather",
          "inputSchema" => %{
            "json" => %{
              "type" => "object",
              "properties" => %{
                "location" => %{"type" => "string", "description" => "City name"}
              },
              "required" => ["location"]
            }
          }
        }
      }

  """
  @spec to_bedrock_converse_format(ReqLLM.Tool.t()) :: map()
  def to_bedrock_converse_format(%ReqLLM.Tool{} = tool) do
    %{
      "toolSpec" => %{
        "name" => tool.name,
        "description" => tool.description,
        "inputSchema" => %{
          "json" => to_json(tool.parameter_schema)
        }
      }
    }
  end

  @doc """
  Validate data against a keyword schema.

  Takes a data map and validates it against a NimbleOptions-style keyword schema.
  The data is first converted to keyword format for NimbleOptions validation.

  ## Parameters

    * `data` - Map of data to validate
    * `schema` - Keyword schema definition

  ## Returns

    * `{:ok, validated_data}` - Successfully validated data
    * `{:error, error}` - Validation error with details

  ## Examples

      iex> schema = [name: [type: :string, required: true], age: [type: :integer]]
      iex> data = %{"name" => "Alice", "age" => 30}
      iex> ReqLLM.Schema.validate(data, schema)
      {:ok, [name: "Alice", age: 30]}

      iex> schema = [name: [type: :string, required: true]]  
      iex> data = %{"age" => 30}
      iex> ReqLLM.Schema.validate(data, schema)
      {:error, %ReqLLM.Error.Validation.Error{...}}

  """
  @spec validate(map(), keyword()) :: {:ok, keyword()} | {:error, ReqLLM.Error.t()}
  def validate(data, schema) when is_map(data) and is_list(schema) do
    with {:ok, compiled_result} <- compile(schema) do
      # Convert string keys to atoms for NimbleOptions validation
      keyword_data =
        data
        |> Enum.map(fn {k, v} ->
          key = if is_binary(k), do: String.to_existing_atom(k), else: k
          {key, v}
        end)

      case NimbleOptions.validate(keyword_data, compiled_result.compiled) do
        {:ok, validated_data} ->
          {:ok, validated_data}

        {:error, %NimbleOptions.ValidationError{} = error} ->
          {:error,
           ReqLLM.Error.Validation.Error.exception(
             tag: :schema_validation_failed,
             reason: Exception.message(error),
             context: [data: data, schema: schema]
           )}
      end
    end
  rescue
    ArgumentError ->
      # Handle the case where string keys don't exist as atoms
      {:error,
       ReqLLM.Error.Validation.Error.exception(
         tag: :invalid_keys,
         reason: "Data contains keys that don't match schema field names",
         context: [data: data, schema: schema]
       )}
  end

  def validate(data, _schema) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "Data must be a map, got: #{inspect(data)}"
     )}
  end
end

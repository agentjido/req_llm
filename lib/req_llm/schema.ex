defmodule ReqLLM.Schema do
  @moduledoc """
  Single schema authority for NimbleOptions ↔ JSON Schema conversion.

  This module consolidates all schema conversion logic, providing unified functions
  for converting keyword schemas to both NimbleOptions compiled schemas and JSON Schema format.
  Supports all common NimbleOptions types and handles nested schemas.

  Also supports direct JSON Schema pass-through when a map is provided instead of a keyword list,
  and Zoi schema structs for advanced schema definitions.

  ## Core Functions

  - `compile/1` - Convert keyword schema to NimbleOptions compiled schema, or pass through maps
  - `to_json/1` - Convert keyword schema to JSON Schema format, pass through maps, or convert Zoi schemas


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

      tag_schema = {:map, [title: [type: :string, required: true], id: [type: :integer]]}

      schema = [
        tags: [type: {:list, tag_schema}],
      ]

  """

  @doc """
  Compiles a keyword schema to a NimbleOptions compiled schema.

  Takes a keyword list representing a NimbleOptions schema and compiles it
  into a validated NimbleOptions schema that can be used for validation.

  When a map is provided (raw JSON Schema), returns a wrapper with the original schema
  and no compiled version (pass-through mode).

  When a Zoi schema struct is provided, converts it to JSON Schema format.

  ## Parameters

  - `schema` - A keyword list representing a NimbleOptions schema, a map for raw JSON Schema, or a Zoi schema struct

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
  @spec compile(keyword() | map() | struct() | any()) ::
          {:ok, %{schema: keyword() | map(), compiled: NimbleOptions.t() | nil}}
          | {:error, ReqLLM.Error.t()}
  def compile(schema) when is_map(schema) and not is_struct(schema) do
    {:ok, %{schema: schema, compiled: nil}}
  end

  def compile(%_{} = schema) when is_struct(schema) do
    if zoi_schema?(schema) do
      json_schema = to_json(schema)
      {:ok, %{schema: json_schema, compiled: nil}}
    else
      {:error,
       ReqLLM.Error.Invalid.Parameter.exception(
         parameter: "Schema must be a keyword list, map, or Zoi schema, got: #{inspect(schema)}"
       )}
    end
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
       parameter: "Schema must be a keyword list, map, or Zoi schema, got: #{inspect(schema)}"
     )}
  end

  @doc """
  Converts a keyword schema to JSON Schema format.

  Takes a keyword list of parameter definitions and converts them to
  a JSON Schema object suitable for LLM tool definitions or structured data schemas.

  When a map is provided (raw JSON Schema), returns it unchanged (pass-through mode).

  When a Zoi schema struct is provided, converts it to JSON Schema.

  ## Parameters

  - `schema` - Keyword list of parameter definitions, a map for raw JSON Schema, or a Zoi schema struct

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
  @spec to_json(keyword() | map() | struct()) :: map()
  def to_json(schema) when is_map(schema) and not is_struct(schema), do: schema

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

  def to_json(%_{} = schema) when is_struct(schema) do
    schema
    |> zoi_to_json_with_metadata()
    |> normalize_json_schema()
  end

  # Private helper functions

  @doc false
  @spec zoi_schema?(any()) :: boolean()
  defp zoi_schema?(value) when is_struct(value) do
    module_name = value.__struct__ |> Module.split() |> List.first()
    module_name == "Zoi"
  end

  defp zoi_schema?(_), do: false

  @doc false
  @spec schema_kind(any()) :: :nimble | :json | :zoi | :unknown
  defp schema_kind(schema) when is_list(schema), do: :nimble

  defp schema_kind(schema) when is_map(schema) and not is_struct(schema) do
    :json
  end

  defp schema_kind(schema) when is_struct(schema) do
    if zoi_schema?(schema), do: :zoi, else: :unknown
  end

  defp schema_kind(_), do: :unknown

  @doc false
  @spec normalize_json_schema(any()) :: any()
  defp normalize_json_schema(value) when is_map(value) and not is_struct(value) do
    value
    |> Map.new(fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      {key, normalize_json_schema(v)}
    end)
  end

  defp normalize_json_schema(value) when is_list(value) do
    Enum.map(value, &normalize_json_schema/1)
  end

  defp normalize_json_schema(value) when is_atom(value) and not is_boolean(value) do
    Atom.to_string(value)
  end

  defp normalize_json_schema(value), do: value

  defp zoi_to_json_with_metadata(schema) do
    base = Zoi.to_json_schema(schema)
    inject_zoi_metadata(schema, base)
  end

  defp inject_zoi_metadata(%Zoi.Types.Object{meta: meta, fields: fields}, json) do
    properties = Map.get(json, :properties) || Map.get(json, "properties") || %{}

    updated_props =
      Enum.reduce(fields, %{}, fn {key, field_schema}, acc ->
        key_str = to_string(key)
        field_json = Map.get(properties, key) || Map.get(properties, key_str) || %{}
        Map.put(acc, key_str, inject_zoi_metadata(field_schema, field_json))
      end)

    json
    |> maybe_put_description(meta)
    |> Map.put("properties", updated_props)
  end

  defp inject_zoi_metadata(%Zoi.Types.Array{meta: meta, inner: inner}, json) do
    items = Map.get(json, :items) || Map.get(json, "items") || %{}

    json
    |> maybe_put_description(meta)
    |> Map.put("items", inject_zoi_metadata(inner, items))
  end

  defp inject_zoi_metadata(%Zoi.Types.Enum{meta: meta}, json) do
    json |> maybe_put_description(meta)
  end

  defp inject_zoi_metadata(%Zoi.Types.String{meta: meta}, json),
    do: maybe_put_description(json, meta)

  defp inject_zoi_metadata(%Zoi.Types.Number{meta: meta}, json),
    do: maybe_put_description(json, meta)

  defp inject_zoi_metadata(%Zoi.Types.Boolean{meta: meta}, json),
    do: maybe_put_description(json, meta)

  defp inject_zoi_metadata(%Zoi.Types.Map{meta: meta}, json),
    do: maybe_put_description(json, meta)

  defp inject_zoi_metadata(%Zoi.Types.Any{meta: meta}, json),
    do: maybe_put_description(json, meta)

  defp inject_zoi_metadata(_schema, json), do: normalize_json_schema(json)

  defp maybe_put_description(json, %Zoi.Types.Meta{} = meta) do
    case meta_description(meta) do
      nil -> json |> normalize_json_schema()
      desc -> json |> normalize_json_schema() |> Map.put("description", desc)
    end
  end

  defp meta_description(%Zoi.Types.Meta{metadata: metadata, description: desc}) do
    md_desc = Keyword.get(metadata, :description)

    cond do
      is_binary(md_desc) and md_desc != "" -> md_desc
      is_binary(desc) and desc != "" -> desc
      true -> nil
    end
  end

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

        {:map, opts} when is_list(opts) and opts != [] ->
          required_keys =
            opts
            |> Enum.filter(fn {_key, prop_opts} ->
              Keyword.get(prop_opts, :required, false) == true
            end)
            |> Enum.map(fn {key, _} -> to_string(key) end)

          properties =
            Map.new(opts, fn {prop_name, prop_opts} ->
              prop_type = Keyword.fetch!(prop_opts, :type)
              {to_string(prop_name), nimble_type_to_json_schema(prop_type, [])}
            end)

          map_schema = %{
            "type" => "object",
            "properties" => properties,
            "additionalProperties" => false
          }

          if required_keys == [] do
            map_schema
          else
            Map.put(map_schema, "required", required_keys)
          end

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
    base = %{
      "name" => tool.name,
      "description" => tool.description,
      "input_schema" => to_json(tool.parameter_schema)
    }

    if tool.strict do
      Map.put(base, "strict", true)
    else
      base
    end
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
  Validate data against a schema.

  Takes data and validates it against a schema. Supports multiple schema types:
  - NimbleOptions keyword schemas (expects maps)
  - Zoi schema structs (can handle maps, arrays, etc.)
  - Raw JSON Schemas (validated using JSV for JSON Schema draft 2020-12 compliance)

  ## Parameters

    * `data` - Data to validate (map, list, or other type depending on schema)
    * `schema` - Schema definition (keyword list, Zoi struct, or map)

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
  @spec validate(any(), keyword() | map() | struct()) ::
          {:ok, keyword() | map() | list() | any()} | {:error, ReqLLM.Error.t()}
  def validate(data, schema) do
    case schema_kind(schema) do
      :nimble ->
        if is_map(data) do
          validate_with_nimble(data, schema)
        else
          {:error,
           ReqLLM.Error.Invalid.Parameter.exception(
             parameter: "NimbleOptions schemas require map data, got: #{inspect(data)}"
           )}
        end

      :json ->
        validate_with_jsv(data, schema)

      :zoi ->
        validate_with_zoi(data, schema)

      :unknown ->
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter: "Unsupported schema type: #{inspect(schema)}"
         )}
    end
  end

  @doc false
  @spec validate_with_nimble(map(), keyword()) :: {:ok, keyword()} | {:error, ReqLLM.Error.t()}
  defp validate_with_nimble(data, schema) do
    with {:ok, compiled_result} <- compile(schema) do
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
      {:error,
       ReqLLM.Error.Validation.Error.exception(
         tag: :invalid_keys,
         reason: "Data contains keys that don't match schema field names",
         context: [data: data, schema: schema]
       )}
  end

  @doc false
  @spec validate_with_jsv(any(), map()) :: {:ok, any()} | {:error, ReqLLM.Error.t()}
  defp validate_with_jsv(data, schema) do
    root = get_or_build_jsv_schema(schema)

    case JSV.validate(data, root) do
      {:ok, _validated_data} ->
        # Discard JSV's cast result to preserve original data types.
        # JSV performs type coercion (e.g., 1.0 -> 1 for integer schemas),
        # but we want to maintain data fidelity.
        {:ok, data}

      {:error, validation_error} ->
        normalized_error = JSV.normalize_error(validation_error)

        {:error,
         ReqLLM.Error.Validation.Error.exception(
           tag: :json_schema_validation_failed,
           reason: format_jsv_errors(normalized_error),
           context: [data: data, schema: schema]
         )}
    end
  rescue
    e in [ArgumentError, RuntimeError, JSV.BuildError] ->
      {:error,
       ReqLLM.Error.Validation.Error.exception(
         tag: :invalid_json_schema,
         reason: "Invalid JSON Schema: #{Exception.message(e)}",
         context: [schema: schema]
       )}
  end

  defp get_or_build_jsv_schema(schema) do
    cache_key = :erlang.phash2(schema)

    case :ets.lookup(:req_llm_schema_cache, cache_key) do
      [{^cache_key, cached_root}] ->
        cached_root

      [] ->
        built = JSV.build!(schema)
        :ets.insert(:req_llm_schema_cache, {cache_key, built})
        built
    end
  end

  @doc false
  @spec validate_with_zoi(any(), struct()) ::
          {:ok, map() | list() | any()} | {:error, ReqLLM.Error.t()}
  defp validate_with_zoi(data, schema) do
    zoi_input = convert_to_zoi_format(data)

    case Zoi.parse(schema, zoi_input) do
      {:ok, parsed} ->
        {:ok, convert_from_zoi_format(parsed)}

      {:error, errors} ->
        {:error,
         ReqLLM.Error.Validation.Error.exception(
           tag: :schema_validation_failed,
           reason: format_zoi_errors(errors),
           context: [data: data, schema: schema]
         )}
    end
  end

  @doc false
  @spec convert_to_zoi_format(any()) :: any()
  defp convert_to_zoi_format(data) when is_map(data) and not is_struct(data) do
    data
    |> Map.new(fn {k, v} ->
      key = if is_binary(k), do: String.to_existing_atom(k), else: k
      {key, convert_to_zoi_format(v)}
    end)
  rescue
    ArgumentError ->
      data
  end

  defp convert_to_zoi_format(data) when is_list(data) do
    if Keyword.keyword?(data) do
      data
    else
      Enum.map(data, &convert_to_zoi_format/1)
    end
  end

  defp convert_to_zoi_format(data), do: data

  @doc false
  @spec convert_from_zoi_format(any()) :: any()
  defp convert_from_zoi_format(data) when is_map(data) and not is_struct(data) do
    data
    |> Map.new(fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: k
      {key, convert_from_zoi_format(v)}
    end)
  end

  defp convert_from_zoi_format(data) when is_list(data) do
    if Keyword.keyword?(data) do
      data
    else
      Enum.map(data, &convert_from_zoi_format/1)
    end
  end

  defp convert_from_zoi_format(data), do: data

  @doc false
  @spec format_zoi_errors([Zoi.Error.t()]) :: String.t()
  defp format_zoi_errors(errors) do
    Enum.map_join(errors, ", ", fn %Zoi.Error{path: path, message: message} ->
      case path do
        [] -> message
        _ -> "#{Enum.map_join(path, ".", &to_string/1)}: #{message}"
      end
    end)
  end

  @doc false
  @spec format_jsv_errors(map()) :: String.t()
  defp format_jsv_errors(%{details: details}) when is_list(details) do
    Enum.map_join(details, ", ", &format_jsv_error/1)
  end

  defp format_jsv_errors(error), do: inspect(error)

  @doc false
  @spec format_jsv_error(map()) :: String.t()
  defp format_jsv_error(%{"instanceLocation" => location, "error" => error}) do
    case location do
      "" -> error
      _ -> "#{location}: #{error}"
    end
  end

  defp format_jsv_error(%{"error" => error}), do: error
  defp format_jsv_error(error), do: inspect(error)
end

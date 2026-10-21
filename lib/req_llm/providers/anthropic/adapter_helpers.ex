defmodule ReqLLM.Providers.Anthropic.AdapterHelpers do
  @moduledoc """
  Shared helper functions for Anthropic model adapters (Bedrock, Vertex).

  These functions are NOT used by the native Anthropic provider - they are
  specific to adapters that wrap Anthropic's API in other platforms.
  """

  @doc """
  Conditionally add a parameter to a map if the value is not nil.
  """
  def maybe_add_param(body, _key, nil), do: body
  def maybe_add_param(body, key, value), do: Map.put(body, key, value)

  @doc """
  Prepare context and options for `:object` operations using a synthetic
  `structured_output` tool, forcing tool choice to use it.

  This is the best-effort tool-calling path. For grammar-constrained output,
  callers pass `anthropic_structured_output_mode: :json_schema`, which the
  platform adapter (e.g. Google Vertex) handles via the response-level
  `output_config.format` path instead of this tool — see
  `structured_output_mode/1` and `strict_json_schema/1`.
  """
  def prepare_structured_output_context(context, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    structured_output_tool =
      ReqLLM.Tool.new!(
        name: "structured_output",
        description: "Generate structured output matching the provided schema",
        parameter_schema: compiled_schema.schema,
        callback: fn _args -> {:ok, "structured output generated"} end
      )

    existing_tools = Map.get(context, :tools, [])
    updated_context = Map.put(context, :tools, [structured_output_tool | existing_tools])

    updated_opts =
      opts
      |> Keyword.put(:tools, [structured_output_tool | Keyword.get(opts, :tools, [])])
      |> Keyword.put(:tool_choice, %{type: "tool", name: "structured_output"})

    {updated_context, updated_opts}
  end

  @doc """
  Resolve the `anthropic_structured_output_mode` from opts (top-level or nested
  under `:provider_options`), defaulting to `:auto`.
  """
  def structured_output_mode(opts) do
    provider_opts = get_opt(opts, :provider_options) || []

    get_opt(opts, :anthropic_structured_output_mode) ||
      get_opt(provider_opts, :anthropic_structured_output_mode) ||
      :auto
  end

  @doc """
  Reduce a compiled schema to the subset that grammar-constrained
  (`output_config.format`) decoding supports: strip unsupported keywords and
  force every property required with `additionalProperties: false`. Properties
  keep the order the schema declares.

  Array length (`minItems`/`maxItems`) cannot be expressed, so callers that need
  an exact count must re-validate it on the response.
  """
  def strict_json_schema(compiled_schema) do
    compiled_schema.schema
    |> ReqLLM.Schema.to_json()
    |> normalize_schema()
    |> strip_constraints_recursive()
    |> enforce_strict_schema_requirements()
  end

  defp normalize_schema(%Jason.OrderedObject{values: entries}),
    do: entries |> Map.new(&normalize_entry/1) |> ReqLLM.Schema.apply_property_ordering()

  defp normalize_schema(%{} = schema) when not is_struct(schema),
    do: schema |> Map.new(&normalize_entry/1) |> ReqLLM.Schema.apply_property_ordering()

  defp normalize_schema(list) when is_list(list), do: Enum.map(list, &normalize_schema/1)
  defp normalize_schema(value), do: value

  defp normalize_entry({key, %Jason.OrderedObject{values: properties}})
       when key in [:properties, "properties"],
       do: {"properties", Jason.OrderedObject.new(Enum.map(properties, &normalize_entry/1))}

  defp normalize_entry({key, value}), do: {to_string(key), normalize_schema(value)}

  @doc """
  Add `output_config.format` for an `:object` request in `:json_schema` mode,
  keeping any other `output_config` field such as `effort`.
  """
  def maybe_add_output_format(body, :object, :json_schema, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    format = %{
      type: "json_schema",
      schema: strict_json_schema(compiled_schema)
    }

    Map.update(body, :output_config, %{format: format}, &Map.put(&1, :format, format))
  end

  def maybe_add_output_format(body, _operation, _mode, _opts), do: body

  @doc """
  Set the response object from the message text, where `:json_schema` mode
  returns it instead of a `structured_output` tool call.
  """
  def extract_object_from_text(response, opts) do
    object =
      case ReqLLM.JSON.decode(ReqLLM.Response.text(response), opts) do
        {:ok, decoded} -> decoded
        _ -> nil
      end

    %{response | object: object}
  end

  defp get_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp get_opt(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp get_opt(_opts, _key), do: nil

  @doc """
  Add the thinking configuration to the request body.

  Thinking that is turned off (`type: "disabled"` or `type: "between_tools"`)
  is always sent, as the bare type, since those types take no other field and
  are compatible with forced tool choice.

  Extended thinking doesn't work when tool_choice forces a specific tool.
  See: https://docs.claude.com/en/docs/build-with-claude/extended-thinking
  """
  def maybe_add_thinking(body, opts) do
    thinking_config =
      get_in(opts, [:provider_options, :additional_model_request_fields, :thinking])

    if ReqLLM.ModelHelpers.anthropic_thinking_off?(thinking_config) do
      Map.put(body, :thinking, %{type: ReqLLM.MapAccess.get(thinking_config, :type)})
    else
      maybe_add_thinking_on(body, thinking_config, opts[:tool_choice])
    end
  end

  defp maybe_add_thinking_on(body, thinking_config, tool_choice) do
    forced_tool_choice? =
      case tool_choice do
        %{type: "tool", name: _} -> true
        %{"type" => "tool", "name" => _} -> true
        _ -> false
      end

    case thinking_config do
      %{type: "enabled", budget_tokens: budget} when not forced_tool_choice? ->
        Map.put(body, :thinking, %{type: "enabled", budget_tokens: budget})

      %{"type" => "enabled", "budget_tokens" => budget} when not forced_tool_choice? ->
        Map.put(body, :thinking, %{type: "enabled", budget_tokens: budget})

      %{type: "adaptive"} = thinking when not forced_tool_choice? ->
        Map.put(body, :thinking, put_adaptive_display(thinking))

      %{"type" => "adaptive"} = thinking when not forced_tool_choice? ->
        Map.put(body, :thinking, put_adaptive_display(thinking))

      _ ->
        body
    end
  end

  @doc """
  Adds platform output configuration while preserving existing body entries.
  """
  def maybe_add_output_config(body, opts) do
    case get_in(opts, [:provider_options, :additional_model_request_fields, :output_config]) do
      config when is_map(config) ->
        Map.update(body, :output_config, config, &Map.merge(&1, config))

      _ ->
        body
    end
  end

  defp put_adaptive_display(%{display: _} = thinking), do: thinking
  defp put_adaptive_display(%{"display" => _} = thinking), do: thinking

  defp put_adaptive_display(%{"type" => _} = thinking),
    do: Map.put(thinking, "display", "summarized")

  defp put_adaptive_display(thinking), do: Map.put(thinking, :display, "summarized")

  @doc """
  Extract structured output from tool calls in response.

  Used for :object operations to get the final structured output.
  """
  def extract_and_set_object(response) do
    extracted_object =
      response
      |> ReqLLM.Response.tool_calls()
      |> ReqLLM.ToolCall.find_args("structured_output")

    %{response | object: extracted_object}
  end

  @doc """
  Extract stub tool definitions from messages when tools are needed but none provided.

  Bedrock and Azure are strict about tool validation in multi-turn conversations.
  If the conversation history contains tool_use or tool_result blocks, the API
  requires corresponding tool definitions. This function extracts tool names
  from the messages and creates minimal stub definitions.
  """
  @spec extract_stub_tools_from_messages(map()) :: [map()]
  def extract_stub_tools_from_messages(body) do
    messages = Map.get(body, :messages, [])

    tool_names =
      messages
      |> Enum.flat_map(fn msg ->
        case msg do
          %{content: content} when is_list(content) ->
            content
            |> Enum.filter(fn
              %{type: "tool_use", name: _} -> true
              %{"type" => "tool_use", "name" => _} -> true
              %{type: "tool_result", tool_use_id: _} -> true
              %{"type" => "tool_result", "toolUseId" => _} -> true
              _ -> false
            end)
            |> Enum.map(fn
              %{name: name} -> name
              %{"name" => name} -> name
              _ -> "__tool_result_placeholder__"
            end)

          _ ->
            []
        end
      end)
      |> Enum.uniq()

    Enum.map(tool_names, fn name ->
      %{
        name: name,
        description: "Tool stub for multi-turn conversation",
        input_schema: %{type: "object", properties: %{}}
      }
    end)
  end

  @doc """
  Recursively remove JSON Schema keywords that strict (grammar-constrained)
  decoding does not support.

  Strips numeric/length/array constraints (`minimum`, `maximum`, `minLength`,
  `maxLength`, `minItems`, `maxItems`) and the Gemini-style `propertyOrdering`
  annotation (which `ReqLLM.Schema.to_json/1` emits but Anthropic's strict tool
  rejects) from the schema and every nested `properties`/`items` subschema.
  """
  def strip_constraints_recursive(schema) when is_map(schema) do
    schema
    |> Map.drop([
      "minimum",
      "maximum",
      "minLength",
      "maxLength",
      "minItems",
      "maxItems",
      "propertyOrdering"
    ])
    |> Map.new(fn
      {"properties", props} when is_map(props) ->
        {"properties", strip_properties(props)}

      {"items", items} when is_map(items) ->
        {"items", strip_constraints_recursive(items)}

      {k, v} when is_map(v) ->
        {k, strip_constraints_recursive(v)}

      {k, v} ->
        {k, v}
    end)
  end

  def strip_constraints_recursive(value), do: value

  defp strip_properties(%Jason.OrderedObject{values: values} = properties),
    do: %{properties | values: Enum.map(values, &strip_property/1)}

  defp strip_properties(properties), do: Map.new(properties, &strip_property/1)

  defp strip_property({name, schema}), do: {name, strip_constraints_recursive(schema)}

  @doc """
  Apply the object-level requirements strict decoding mandates to every object
  in the schema: every property is marked required and `additionalProperties`
  is set to `false`.
  """
  def enforce_strict_schema_requirements(%{} = schema) when not is_struct(schema) do
    schema
    |> Map.new(&enforce_entry/1)
    |> require_every_property()
  end

  def enforce_strict_schema_requirements(list) when is_list(list),
    do: Enum.map(list, &enforce_strict_schema_requirements/1)

  def enforce_strict_schema_requirements(value), do: value

  defp enforce_entry({"properties", %Jason.OrderedObject{values: values} = properties}),
    do: {"properties", %{properties | values: Enum.map(values, &enforce_property/1)}}

  defp enforce_entry({"properties", %{} = properties}),
    do: {"properties", Map.new(properties, &enforce_property/1)}

  defp enforce_entry({key, value}), do: {key, enforce_strict_schema_requirements(value)}

  defp enforce_property({name, schema}), do: {name, enforce_strict_schema_requirements(schema)}

  defp require_every_property(%{"type" => "object", "properties" => properties} = schema) do
    schema
    |> Map.put("required", Enum.map(properties, &elem(&1, 0)))
    |> Map.put("additionalProperties", false)
  end

  defp require_every_property(schema), do: schema
end

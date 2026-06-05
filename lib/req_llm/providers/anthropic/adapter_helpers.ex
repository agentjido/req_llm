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
  force every property required with `additionalProperties: false`.

  Array length (`minItems`/`maxItems`) cannot be expressed, so callers that need
  an exact count must re-validate it on the response.
  """
  def strict_json_schema(compiled_schema) do
    compiled_schema.schema
    |> ReqLLM.Schema.to_json()
    |> strip_constraints_recursive()
    |> enforce_strict_schema_requirements()
  end

  defp get_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp get_opt(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp get_opt(_opts, _key), do: nil

  @doc """
  Add extended thinking configuration to request body if enabled.

  Extended thinking doesn't work when tool_choice forces a specific tool.
  See: https://docs.claude.com/en/docs/build-with-claude/extended-thinking
  """
  def maybe_add_thinking(body, opts) do
    # Check if additional_model_request_fields has thinking config
    thinking_config =
      get_in(opts, [:provider_options, :additional_model_request_fields, :thinking])

    tool_choice = opts[:tool_choice]

    # Extended thinking doesn't work when tool_choice forces a specific tool
    forced_tool_choice? =
      case tool_choice do
        %{type: "tool", name: _} -> true
        %{"type" => "tool", "name" => _} -> true
        _ -> false
      end

    case thinking_config do
      %{type: "enabled", budget_tokens: budget} when not forced_tool_choice? ->
        Map.put(body, :thinking, %{type: "enabled", budget_tokens: budget})

      _ ->
        body
    end
  end

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
        {"properties", Map.new(props, fn {k, v} -> {k, strip_constraints_recursive(v)} end)}

      {"items", items} when is_map(items) ->
        {"items", strip_constraints_recursive(items)}

      {k, v} when is_map(v) ->
        {k, strip_constraints_recursive(v)}

      {k, v} ->
        {k, v}
    end)
  end

  def strip_constraints_recursive(value), do: value

  @doc """
  Apply the object-level requirements strict decoding mandates: every property
  is marked required and `additionalProperties` is set to `false`.
  """
  def enforce_strict_schema_requirements(
        %{"type" => "object", "properties" => properties} = schema
      ) do
    schema
    |> Map.put("required", Map.keys(properties))
    |> Map.put("additionalProperties", false)
  end

  def enforce_strict_schema_requirements(schema), do: schema
end

defmodule ReqLLM.ModelHelpers do
  @moduledoc """
  Helper functions for querying LLMDB.Model capabilities.

  Defines helper functions for common capability checks, centralizing knowledge
  of the model capability structure.

  These helpers ensure consistency when checking model capabilities across the codebase
  and provide a single source of truth for capability access patterns.
  """

  # Define helper functions for common capability checks
  # Pattern: capabilities.category.field
  @capability_checks [
    # Reasoning capability
    {:reasoning_enabled?, [:reasoning, :enabled]},

    # JSON capabilities
    {:json_native?, [:json, :native]},
    {:json_schema?, [:json, :schema]},
    {:json_strict?, [:json, :strict]},

    # Tool capabilities
    {:tools_enabled?, [:tools, :enabled]},
    {:tools_strict?, [:tools, :strict]},
    {:tools_parallel?, [:tools, :parallel]},
    {:tools_streaming?, [:tools, :streaming]},

    # Streaming capabilities
    {:streaming_text?, [:streaming, :text]},
    {:streaming_tool_calls?, [:streaming, :tool_calls]},

    # Chat capability (direct boolean)
    {:chat?, [:chat]}
  ]

  @bedrock_inference_prefixes ~w(us eu ap apac ca au jp in us-gov global)

  @anthropic_thinking_off_types ["disabled", "between_tools"]

  for {function_name, path} <- @capability_checks do
    path_str = Enum.map_join(path, ".", &to_string/1)
    example_path = Enum.map_join(path, ": %{", fn key -> "#{key}" end)
    example_close = String.duplicate("}", length(path) - 1)

    @doc """
    Check if model has `#{path_str}` capability.

    Returns `true` if `model.capabilities.#{path_str}` is `true`.

    ## Examples

        iex> model = %LLMDB.Model{capabilities: %{#{example_path}: true#{example_close}}}
        iex> ReqLLM.ModelHelpers.#{function_name}(model)
        true

        iex> model = %LLMDB.Model{capabilities: %{}}
        iex> ReqLLM.ModelHelpers.#{function_name}(model)
        false
    """
    def unquote(function_name)(%LLMDB.Model{} = model) do
      get_in(model.capabilities, unquote(path)) == true
    end

    def unquote(function_name)(_), do: false
  end

  @doc """
  List all available capability helper functions.

  Useful for debugging and understanding what capabilities can be queried.

  ## Examples

      iex> ReqLLM.ModelHelpers.list_helpers()
      [:chat?, :json_native?, :json_schema?, :json_strict?, :reasoning_enabled?, ...]
  """
  def list_helpers do
    @capability_checks
    |> Enum.map(fn {name, _path} -> name end)
    |> Enum.sort()
  end

  @doc """
  Check if the model's thinking request must use the `adaptive` type.

  Used to select the correct `type: "adaptive"` form for models that do not support
  the standard `enabled` thinking type.

  ## Examples

      iex> model = %LLMDB.Model{extra: %{capabilities: %{thinking: %{types: %{adaptive: %{supported: true}, enabled: %{supported: false}}}}}}
      iex> ReqLLM.ModelHelpers.adaptive_thinking_required?(model)
      true
  """
  def adaptive_thinking_required?(%LLMDB.Model{} = model) do
    model_adaptive_thinking_required?(model) or
      hosted_anthropic_adaptive_thinking_required?(model)
  end

  def adaptive_thinking_required?(_), do: false

  @doc """
  Fills missing hosted Claude effort metadata from the native Anthropic model.
  Explicit platform effort capabilities take precedence.
  """
  @spec with_anthropic_effort_metadata(LLMDB.Model.t()) :: LLMDB.Model.t()
  def with_anthropic_effort_metadata(%LLMDB.Model{} = model) do
    configured = [
      nested_value(model.capabilities, [:reasoning, :effort]),
      nested_value(model.extra, [:provider_capabilities, :effort]),
      nested_value(model.extra, [:capabilities, :effort])
    ]

    effort =
      if Enum.all?(configured, &is_nil/1) do
        model
        |> hosted_anthropic_model_ids()
        |> Enum.find_value(fn id ->
          case LLMDB.model(:anthropic, id) do
            {:ok, native} -> nested_value(native.capabilities, [:reasoning, :effort])
            _ -> nil
          end
        end)
      end

    if is_map(effort) do
      capabilities = model.capabilities || %{}
      reasoning = nested_value(capabilities, [:reasoning]) || %{}

      %{
        model
        | capabilities: Map.put(capabilities, :reasoning, Map.put(reasoning, :effort, effort))
      }
    else
      model
    end
  end

  @doc """
  Returns the thinking types a Claude model accepts, such as `"adaptive"`,
  `"enabled"`, `"disabled"` or `"between_tools"`.

  The model's own reasoning metadata is read first. Hosted Claude models on
  Amazon Bedrock, Google Vertex AI and Azure often carry no thinking metadata,
  so the native Anthropic model is consulted when the hosted entry has none.
  Returns `[]` when no metadata is available.

  ## Examples

      iex> model = %LLMDB.Model{provider: :anthropic, id: "claude-example", capabilities: %{reasoning: %{thinking: %{types: ["adaptive", "between_tools"]}}}}
      iex> ReqLLM.ModelHelpers.anthropic_thinking_types(model)
      ["adaptive", "between_tools"]
  """
  @spec anthropic_thinking_types(LLMDB.Model.t() | term()) :: [String.t()]
  def anthropic_thinking_types(%LLMDB.Model{} = model) do
    model_thinking_types(model) || hosted_anthropic_thinking_types(model) || []
  end

  def anthropic_thinking_types(_), do: []

  @doc """
  Returns the thinking type that turns thinking off for a Claude model, or `nil`
  when the model cannot turn thinking off or its thinking types are unknown.

  `"disabled"` is preferred where the model accepts it. Claude Sonnet 5.5 turns
  thinking off with `"between_tools"` instead, and Claude Opus 5.5 cannot turn
  it off at all.

  ## Examples

      iex> model = %LLMDB.Model{provider: :anthropic, id: "claude-example", capabilities: %{reasoning: %{thinking: %{types: ["adaptive", "between_tools"]}}}}
      iex> ReqLLM.ModelHelpers.anthropic_thinking_off_type(model)
      "between_tools"

      iex> model = %LLMDB.Model{provider: :anthropic, id: "claude-example", capabilities: %{reasoning: %{thinking: %{types: ["adaptive"]}}}}
      iex> ReqLLM.ModelHelpers.anthropic_thinking_off_type(model)
      nil
  """
  @spec anthropic_thinking_off_type(LLMDB.Model.t() | term()) :: String.t() | nil
  def anthropic_thinking_off_type(model) do
    types = anthropic_thinking_types(model)
    Enum.find(@anthropic_thinking_off_types, &(&1 in types))
  end

  @doc """
  Whether an Anthropic thinking config turns thinking off, with either
  `type: "disabled"` or `type: "between_tools"`.

  ## Examples

      iex> ReqLLM.ModelHelpers.anthropic_thinking_off?(%{type: "between_tools"})
      true

      iex> ReqLLM.ModelHelpers.anthropic_thinking_off?(%{"type" => "adaptive"})
      false
  """
  @spec anthropic_thinking_off?(term()) :: boolean()
  def anthropic_thinking_off?(thinking) when is_map(thinking) do
    normalize_thinking_type(nested_value(thinking, [:type])) in @anthropic_thinking_off_types
  end

  def anthropic_thinking_off?(_thinking), do: false

  defp model_thinking_types(%LLMDB.Model{} = model) do
    [
      nested_value(model.capabilities, [:reasoning, :thinking, :types]),
      nested_value(model.extra, [:provider_capabilities, :thinking, :types]),
      nested_value(model.extra, [:capabilities, :thinking, :types])
    ]
    |> Enum.find_value(&thinking_type_names/1)
  end

  defp hosted_anthropic_thinking_types(model) do
    model
    |> hosted_anthropic_model_ids()
    |> Enum.find_value(fn id ->
      case LLMDB.model(:anthropic, id) do
        {:ok, %LLMDB.Model{} = native} -> model_thinking_types(native)
        _ -> nil
      end
    end)
  end

  defp thinking_type_names([_ | _] = types) do
    types
    |> Enum.map(&normalize_thinking_type/1)
    |> Enum.reject(&is_nil/1)
  end

  defp thinking_type_names(types) when is_map(types) and map_size(types) > 0 do
    types
    |> Map.keys()
    |> Enum.filter(&(thinking_type_supported?(types, &1) == true))
    |> Enum.map(&normalize_thinking_type/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp thinking_type_names(_types), do: nil

  defp model_adaptive_thinking_required?(%LLMDB.Model{} = model) do
    adaptive_thinking_types_required?(
      nested_value(model.capabilities, [:reasoning, :thinking, :types])
    ) or
      adaptive_thinking_types_required?(
        nested_value(model.extra, [:provider_capabilities, :thinking, :types])
      ) or
      adaptive_thinking_types_required?(
        nested_value(model.extra, [:capabilities, :thinking, :types])
      )
  end

  defp hosted_anthropic_adaptive_thinking_required?(%LLMDB.Model{} = model) do
    model
    |> hosted_anthropic_model_ids()
    |> Enum.any?(&native_anthropic_adaptive_thinking_required?/1)
  end

  defp native_anthropic_adaptive_thinking_required?(model_id) do
    case LLMDB.model(:anthropic, model_id) do
      {:ok, %LLMDB.Model{} = model} -> model_adaptive_thinking_required?(model)
      _ -> false
    end
  end

  defp adaptive_thinking_types_required?(types) when is_list(types) do
    normalized_types = Enum.map(types, &normalize_thinking_type/1)

    "adaptive" in normalized_types and "enabled" not in normalized_types
  end

  defp adaptive_thinking_types_required?(types) when is_map(types) do
    adaptive_supported = thinking_type_supported?(types, :adaptive)
    enabled_supported = thinking_type_supported?(types, :enabled)

    adaptive_supported and enabled_supported == false
  end

  defp adaptive_thinking_types_required?(_types), do: false

  defp thinking_type_supported?(types, key) do
    case nested_value(types, [key, :supported]) do
      supported when is_boolean(supported) -> supported
      _ -> direct_thinking_type_supported?(types, key)
    end
  end

  defp direct_thinking_type_supported?(types, key) do
    case nested_value(types, [key]) do
      supported when is_boolean(supported) -> supported
      _ -> nil
    end
  end

  defp normalize_thinking_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalize_thinking_type(type) when is_binary(type), do: type
  defp normalize_thinking_type(_type), do: nil

  defp hosted_anthropic_model_ids(model) do
    [model.provider_model_id, model.id, model.model]
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&native_anthropic_model_id_candidates/1)
    |> Enum.uniq()
  end

  defp native_anthropic_model_id_candidates(model_id) do
    normalized =
      model_id
      |> strip_bedrock_inference_prefix()
      |> strip_bedrock_anthropic_prefix()
      |> strip_vertex_revision()
      |> strip_bedrock_version_suffix()

    [normalized]
  end

  defp strip_bedrock_inference_prefix(model_id) do
    case String.split(model_id, ".", parts: 2) do
      [prefix, rest] when prefix in @bedrock_inference_prefixes -> rest
      _ -> model_id
    end
  end

  defp strip_bedrock_anthropic_prefix("anthropic." <> model_id), do: model_id
  defp strip_bedrock_anthropic_prefix(model_id), do: model_id

  defp strip_vertex_revision(model_id) do
    model_id
    |> String.split("@", parts: 2)
    |> hd()
  end

  defp strip_bedrock_version_suffix(model_id) do
    Regex.replace(~r/-v\d(?::\d)?$/, model_id, "")
  end

  defp nested_value(value, []), do: value

  defp nested_value(value, [key | rest]) when is_map(value) do
    cond do
      Map.has_key?(value, key) -> nested_value(Map.get(value, key), rest)
      Map.has_key?(value, to_string(key)) -> nested_value(Map.get(value, to_string(key)), rest)
      true -> nil
    end
  end

  defp nested_value(_value, _path), do: nil
end

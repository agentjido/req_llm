defmodule ReqLLM.Test.Scenarios.Capabilities do
  @moduledoc """
  Capability predicates used by provider coverage scenarios.
  """

  @spec supports_object_generation?(binary() | LLMDB.Model.t()) :: boolean()
  def supports_object_generation?(model_or_spec) do
    case model_for(model_or_spec) do
      {:ok, model} ->
        object_generation_supported?(model)

      {:error, _} ->
        false
    end
  end

  @spec supports_streaming_object_generation?(binary() | LLMDB.Model.t()) :: boolean()
  def supports_streaming_object_generation?(model_or_spec) do
    case model_for(model_or_spec) do
      {:ok, model} ->
        caps = model.capabilities || %{}

        supports_object_generation?(model) and cap(caps, [:streaming, :tool_calls]) != false

      {:error, _} ->
        false
    end
  end

  @spec supports_tool_calling?(binary() | LLMDB.Model.t()) :: boolean()
  def supports_tool_calling?(model_or_spec) do
    case model_for(model_or_spec) do
      {:ok, model} -> cap(model.capabilities || %{}, [:tools, :enabled]) == true
      {:error, _} -> false
    end
  end

  @spec supports_reasoning?(binary() | LLMDB.Model.t()) :: boolean()
  def supports_reasoning?(model_or_spec) do
    case model_for(model_or_spec) do
      {:ok, model} -> cap(model.capabilities || %{}, [:reasoning, :enabled]) == true
      {:error, _} -> false
    end
  end

  @spec supports_forced_tool_choice?(binary() | LLMDB.Model.t()) :: boolean()
  def supports_forced_tool_choice?(model_or_spec) do
    case model_for(model_or_spec) do
      {:ok, model} -> cap(model.capabilities || %{}, [:tools, :forced_choice]) != false
      {:error, _} -> true
    end
  end

  defp model_for(%LLMDB.Model{} = model), do: {:ok, model}
  defp model_for(model_spec) when is_binary(model_spec), do: ReqLLM.model(model_spec)
  defp model_for(_), do: {:error, :invalid_model}

  defp object_generation_supported?(%LLMDB.Model{} = model) do
    structured_outputs_supported?(model) and
      (execution_object_supported?(model) or
         json_output_supported?(model) or
         strict_tool_output_supported?(model) or
         tool_workaround_supported?(model))
  end

  defp execution_object_supported?(%LLMDB.Model{execution: execution}) when is_map(execution) do
    execution
    |> cap([:object])
    |> supported_entry?()
  end

  defp execution_object_supported?(_model), do: false

  defp json_output_supported?(%LLMDB.Model{capabilities: capabilities}) do
    capability_enabled?(capabilities, [:json, :native]) or
      capability_enabled?(capabilities, [:json, :schema])
  end

  defp strict_tool_output_supported?(%LLMDB.Model{capabilities: capabilities}) do
    capability_enabled?(capabilities, [:tools, :strict])
  end

  defp tool_workaround_supported?(%LLMDB.Model{provider: :anthropic}), do: false

  defp tool_workaround_supported?(%LLMDB.Model{capabilities: capabilities}) do
    capability_enabled?(capabilities, [:tools, :enabled])
  end

  defp structured_outputs_supported?(%LLMDB.Model{provider: :anthropic, extra: extra}) do
    cond do
      cap(extra || %{}, [:provider_capabilities, :structured_outputs, :supported]) == false ->
        false

      cap(extra || %{}, [:capabilities, :structured_outputs, :supported]) == false ->
        false

      true ->
        true
    end
  end

  defp structured_outputs_supported?(_model), do: true

  defp capability_enabled?(capabilities, path) do
    capabilities
    |> cap(path)
    |> enabled_value?()
  end

  defp supported_entry?(entry) when is_map(entry),
    do: entry |> cap([:supported]) |> enabled_value?()

  defp supported_entry?(_entry), do: false

  defp enabled_value?(true), do: true
  defp enabled_value?(_value), do: false

  defp cap(value, []), do: value

  defp cap(value, [key | rest]) when is_map(value) do
    value
    |> fetch_cap(key)
    |> cap(rest)
  end

  defp cap(_value, _path), do: nil

  defp fetch_cap(map, key) when is_atom(key) do
    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      Map.has_key?(map, Atom.to_string(key)) ->
        Map.get(map, Atom.to_string(key))

      true ->
        nil
    end
  end

  defp fetch_cap(map, key) when is_binary(key) do
    atom_key = existing_atom(key)

    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      not is_nil(atom_key) and Map.has_key?(map, atom_key) ->
        Map.get(map, atom_key)

      true ->
        nil
    end
  end

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end

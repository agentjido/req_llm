defmodule ReqLLM.Test.Scenarios.Capabilities do
  @moduledoc """
  Capability predicates used by provider coverage scenarios.
  """

  @spec supports_object_generation?(binary() | LLMDB.Model.t()) :: boolean()
  def supports_object_generation?(model_or_spec) do
    case model_for(model_or_spec) do
      {:ok, model} ->
        caps = model.capabilities || %{}

        structured_outputs_supported?(model) and
          (cap(caps, [:json, :native]) ||
             cap(caps, [:json, :schema]) ||
             cap(caps, [:tools, :strict]) == true ||
             cap(caps, [:tools, :enabled]) == true)

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

  defp structured_outputs_supported?(%LLMDB.Model{provider: :anthropic, extra: extra}) do
    case cap(extra || %{}, [:capabilities, :structured_outputs, :supported]) do
      false -> false
      _ -> true
    end
  end

  defp structured_outputs_supported?(_model), do: true

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

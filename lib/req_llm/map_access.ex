defmodule ReqLLM.MapAccess do
  @moduledoc false

  @spec get(map(), atom() | String.t(), any()) :: any()
  def get(map, key, default \\ nil)

  def get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
  end

  def get(map, key, default) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      case existing_atom(key) do
        nil -> default
        atom -> Map.get(map, atom) || default
      end
  end

  def get(_map, _key, default), do: default

  @spec get_raw(any(), atom() | String.t(), any()) :: any()
  def get_raw(map, key, default \\ nil)

  def get_raw(map, key, default) when is_map(map) and is_atom(key) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key), default)
      value -> value
    end
  end

  def get_raw(map, key, default) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      nil ->
        case existing_atom(key) do
          nil -> default
          atom -> Map.get(map, atom, default)
        end

      value ->
        value
    end
  end

  def get_raw(_map, _key, default), do: default

  defp existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end
end

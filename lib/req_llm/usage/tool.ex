defmodule ReqLLM.Usage.Tool do
  @moduledoc false

  alias ReqLLM.MapAccess

  @spec normalize(any()) :: map()
  def normalize(nil), do: %{}
  def normalize(usage) when is_map(usage), do: usage
  def normalize(_), do: %{}

  @spec valid_usage?(any()) :: boolean()
  def valid_usage?(nil), do: true

  def valid_usage?(usage) when is_map(usage) do
    Enum.all?(usage, fn {name, entry} ->
      (is_atom(name) or is_binary(name)) and not is_nil(name) and is_map(entry) and
        valid_count?(MapAccess.get_raw(entry, :count)) and
        valid_unit?(MapAccess.get_raw(entry, :unit))
    end)
  end

  def valid_usage?(_), do: false

  defp valid_count?(count), do: is_number(count) and count >= 0
  defp valid_unit?(unit), do: is_nil(unit) or is_atom(unit) or is_binary(unit)

  @spec entry(map(), atom() | String.t()) :: map()
  def entry(tool_usage, tool) when is_map(tool_usage) and (is_atom(tool) or is_binary(tool)) do
    tool_usage
    |> MapAccess.get(tool, %{})
    |> ensure_map()
  end

  def entry(_, _), do: %{}

  @spec count(map(), atom() | String.t(), any()) :: number()
  def count(usage, tool, component_unit) do
    tool_usage = MapAccess.get(usage, :tool_usage, %{}) |> normalize()
    entry = entry(tool_usage, tool)
    count = MapAccess.get(entry, :count, 0)
    component_unit = normalize_unit(component_unit)
    usage_unit = normalize_unit(MapAccess.get(entry, :unit))

    if unit_match?(component_unit, usage_unit) do
      count
    else
      0
    end
  end

  @spec build(atom() | String.t(), number(), any()) :: map()
  def build(tool, count, unit \\ nil)

  def build(tool, count, unit)
      when (is_atom(tool) or is_binary(tool)) and is_number(count) and count > 0 do
    %{tool => %{count: count, unit: unit || :call}}
  end

  def build(_, _, _), do: %{}

  @spec normalize_unit(any()) :: String.t() | nil
  def normalize_unit(nil), do: nil
  def normalize_unit(unit) when is_atom(unit), do: Atom.to_string(unit)
  def normalize_unit(unit) when is_binary(unit), do: unit
  def normalize_unit(_), do: nil

  @spec unit_match?(String.t() | nil, String.t() | nil) :: boolean()
  def unit_match?(component_unit, usage_unit) do
    component_unit == nil or usage_unit == nil or component_unit == usage_unit
  end

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_), do: %{}
end

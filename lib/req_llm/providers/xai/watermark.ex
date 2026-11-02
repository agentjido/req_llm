defmodule ReqLLM.Providers.XAI.Watermark do
  @moduledoc false

  @header "x-watermark"

  @spec put_provider_metadata(map(), map() | list()) :: map()
  def put_provider_metadata(provider_meta, headers) when is_map(provider_meta) do
    case header_status(headers) do
      status when is_boolean(status) -> Map.put(provider_meta, :watermarked, status)
      nil -> provider_meta
    end
  end

  defp header_status(headers) when is_map(headers) or is_list(headers) do
    values =
      headers
      |> Enum.flat_map(&watermark_values/1)
      |> Enum.map(&normalize_value/1)

    cond do
      values != [] and Enum.all?(values, &(&1 == "true")) -> true
      values != [] and Enum.all?(values, &(&1 == "false")) -> false
      true -> nil
    end
  end

  defp header_status(_headers), do: nil

  defp watermark_values({name, value}) do
    if header_name(name) == @header, do: List.wrap(value), else: []
  end

  defp watermark_values(_header), do: []

  defp header_name(name) when is_binary(name), do: String.downcase(name)
  defp header_name(name) when is_atom(name), do: name |> Atom.to_string() |> String.downcase()
  defp header_name(_name), do: nil

  defp normalize_value(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_value(_value), do: nil
end

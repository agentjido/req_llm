defmodule ReqLLM.Usage.Image do
  @moduledoc false

  alias ReqLLM.MapAccess

  @spec normalize(any()) :: map()
  def normalize(nil), do: %{}
  def normalize(usage) when is_map(usage), do: usage
  def normalize(_), do: %{}

  @spec valid_usage?(any()) :: boolean()
  def valid_usage?(nil), do: true

  def valid_usage?(usage) when is_map(usage) do
    case MapAccess.get_raw(usage, :generated) do
      nil ->
        true

      generated when is_map(generated) ->
        count = MapAccess.get_raw(generated, :count)
        is_number(count) and count >= 0

      _ ->
        false
    end
  end

  def valid_usage?(_), do: false

  @spec count_generated(map(), any()) :: number()
  def count_generated(usage, size_class \\ nil) do
    usage_map = MapAccess.get(usage, :image_usage, %{}) |> normalize()
    generated = MapAccess.get(usage_map, :generated, %{}) |> ensure_map()
    count = MapAccess.get(generated, :count, 0)

    if size_class == nil do
      count
    else
      usage_size = MapAccess.get(generated, :size_class)

      if usage_size == size_class do
        count
      else
        0
      end
    end
  end

  @spec build_generated(number(), any()) :: map()
  def build_generated(count, size_class \\ nil)

  def build_generated(count, size_class) when is_number(count) and count > 0 do
    generated =
      if size_class == nil do
        %{count: count}
      else
        %{count: count, size_class: size_class}
      end

    %{generated: generated}
  end

  def build_generated(_, _), do: %{}

  @spec count_inline_parts(any()) :: non_neg_integer()
  def count_inline_parts(parts) when is_list(parts) do
    Enum.count(parts, &inline_part?/1)
  end

  def count_inline_parts(_), do: 0

  def inline_part?(%{"inlineData" => %{"mimeType" => mime}}) when is_binary(mime) do
    String.starts_with?(mime, "image/")
  end

  def inline_part?(%{"inline_data" => %{"mime_type" => mime}}) when is_binary(mime) do
    String.starts_with?(mime, "image/")
  end

  def inline_part?(%{"inlineData" => %{}}), do: true
  def inline_part?(%{"inline_data" => %{}}), do: true
  def inline_part?(_), do: false

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_), do: %{}
end

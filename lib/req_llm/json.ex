defmodule ReqLLM.JSON do
  @moduledoc false

  @spec decode(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def decode(json, opts \\ [])

  def decode(json, opts) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, _parsed} = ok ->
        ok

      {:error, error} ->
        if json_repair_enabled?(opts) do
          repaired = repair(json)

          if repaired == json do
            {:error, error}
          else
            Jason.decode(repaired)
          end
        else
          {:error, error}
        end
    end
  end

  def decode(_json, _opts), do: {:error, :invalid_json}

  defp json_repair_enabled?(opts) when is_list(opts), do: Keyword.get(opts, :json_repair, true)
  defp json_repair_enabled?(opts) when is_map(opts), do: Map.get(opts, :json_repair, true)
  defp json_repair_enabled?(_opts), do: true

  defp repair(json) do
    json
    |> strip_bom()
    |> normalize_quotes()
    |> strip_code_fences()
    |> extract_json_payload()
    |> remove_trailing_commas()
    |> close_unbalanced_delimiters()
  end

  defp strip_bom(<<239, 187, 191, rest::binary>>), do: rest
  defp strip_bom(json), do: json

  defp normalize_quotes(json) do
    json
    |> String.replace(["\u201c", "\u201d"], "\"")
    |> String.replace(["\u2018", "\u2019"], "'")
  end

  defp strip_code_fences(json) do
    case Regex.run(~r/\A```(?:json)?\s*(.*?)\s*```\z/s, String.trim(json),
           capture: :all_but_first
         ) do
      [inner] -> inner
      _ -> json
    end
  end

  defp extract_json_payload(json) do
    trimmed = String.trim(json)

    case first_json_boundary(trimmed) do
      nil ->
        trimmed

      {start_index, _opening, closing} ->
        candidate = String.slice(trimmed, start_index..-1//1)

        case last_grapheme_index(candidate, closing) do
          nil -> candidate
          end_index -> String.slice(candidate, 0, end_index + 1)
        end
    end
  end

  defp first_json_boundary(json) do
    json
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.find_value(fn
      {"{", index} -> {index, "{", "}"}
      {"[", index} -> {index, "[", "]"}
      _ -> nil
    end)
  end

  defp last_grapheme_index(json, target) do
    json
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {^target, index}, _acc -> index
      _, acc -> acc
    end)
  end

  defp remove_trailing_commas(json) do
    Regex.replace(~r/,\s*([}\]])/, json, "\\1")
  end

  defp close_unbalanced_delimiters(json) do
    {stack, _in_string?, _escaped?} =
      json
      |> String.graphemes()
      |> Enum.reduce({[], false, false}, &track_delimiters/2)

    closing =
      stack
      |> Enum.map_join(fn
        "{" -> "}"
        "[" -> "]"
      end)

    json <> closing
  end

  defp track_delimiters("\\", {stack, true, false}), do: {stack, true, true}
  defp track_delimiters(_char, {stack, true, true}), do: {stack, true, false}
  defp track_delimiters("\"", {stack, true, false}), do: {stack, false, false}
  defp track_delimiters("\"", {stack, false, false}), do: {stack, true, false}
  defp track_delimiters("{", {stack, false, false}), do: {["{" | stack], false, false}
  defp track_delimiters("[", {stack, false, false}), do: {["[" | stack], false, false}
  defp track_delimiters("}", {["{" | rest], false, false}), do: {rest, false, false}
  defp track_delimiters("]", {["[" | rest], false, false}), do: {rest, false, false}
  defp track_delimiters(_char, state), do: state
end

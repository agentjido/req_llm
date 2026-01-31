defmodule ReqLLM.Billing do
  @moduledoc """
  Component-based billing calculator for token and tool usage.
  """

  alias ReqLLM.Billing.Component
  alias ReqLLM.MapAccess
  alias ReqLLM.Pricing
  alias ReqLLM.Usage.Image
  alias ReqLLM.Usage.Tool

  @token_id_map [
    {"token.input", :input},
    {"token.output", :output},
    {"token.reasoning", :reasoning},
    {"token.cache_read", :cache_read},
    {"token.cache_write", :cache_write},
    {"token.cache", :cache}
  ]

  @spec calculate(map(), LLMDB.Model.t() | nil) :: {:ok, map() | nil}
  def calculate(_usage, nil), do: {:ok, nil}

  def calculate(usage, %LLMDB.Model{} = model) when is_map(usage) do
    components =
      model
      |> Pricing.components()
      |> Enum.map(&Component.from/1)

    if components == [] do
      {:ok, nil}
    else
      {:ok, compute_costs(usage, components)}
    end
  end

  defp compute_costs(usage, components) do
    usage = adjust_output_for_reasoning(usage, components)

    {line_items, totals} =
      Enum.reduce(components, {[], %{tokens: 0.0, tools: 0.0, images: 0.0, storage: 0.0}}, fn
        component, {items, totals_acc} ->
          case component_cost(component, usage) do
            {:ok, count, cost, kind} ->
              updated_totals = Map.update!(totals_acc, kind, &Float.round(&1 + cost, 6))

              component_value = Component.id_string(component) || component.id

              item = %{
                id: component.id,
                count: count,
                cost: cost,
                kind: kind,
                component: component_value,
                quantity: count
              }

              {[item | items], updated_totals}

            :skip ->
              {items, totals_acc}
          end
      end)

    line_items = Enum.reverse(line_items)
    token_costs = token_cost_breakdown(line_items)

    total_cost =
      Float.round(
        totals.tokens + totals.tools + totals.images + totals.storage,
        6
      )

    %{
      tokens: totals.tokens,
      tools: totals.tools,
      images: totals.images,
      storage: totals.storage,
      total: total_cost,
      line_items: line_items,
      input_cost: token_costs.input_cost,
      output_cost: token_costs.output_cost,
      reasoning_cost: token_costs.reasoning_cost
    }
  end

  defp adjust_output_for_reasoning(usage, components) do
    add_reasoning =
      MapAccess.get(usage, :add_reasoning_to_cost) ||
        MapAccess.get(usage, "add_reasoning_to_cost")

    has_reasoning_component =
      Enum.any?(components, fn component ->
        case Component.id_string(component) do
          id when is_binary(id) -> String.starts_with?(id, "token.reasoning")
          _ -> false
        end
      end)

    if add_reasoning && not has_reasoning_component do
      output_tokens = usage_value(usage, "output_tokens")
      reasoning_tokens = usage_value(usage, "reasoning_tokens")
      Map.put(usage, :output_tokens, output_tokens + reasoning_tokens)
    else
      usage
    end
  end

  defp component_cost(%Component{} = component, usage) do
    per = component.per
    rate = component.rate

    if is_number(per) and per > 0 and is_number(rate) and component.kind != nil do
      case component_count(component, usage) do
        count when is_number(count) and count > 0 ->
          cost = Float.round(count / per * rate, 6)
          {:ok, count, cost, component.kind}

        _ ->
          :skip
      end
    else
      :skip
    end
  end

  defp component_count(%Component{} = component, usage) do
    cond do
      is_binary(component.meter) ->
        usage_value(usage, component.meter)

      component.kind == :tokens ->
        token_usage_count(component, usage)

      component.kind == :tools ->
        Tool.count(usage, component.tool, component.unit)

      component.kind == :images ->
        Image.count_generated(usage, component.size_class)

      component.kind == :storage ->
        usage_value(usage, "storage")

      true ->
        usage_value(usage, component.id)
    end
  end

  defp token_usage_count(component, usage) do
    id = Component.id_string(component) || component.id
    input_includes_cached = input_includes_cached?(usage)

    cached_read = usage_value(usage, "cached_tokens")
    cache_write = usage_value(usage, "cache_creation_tokens")

    case token_meter_for_id(id) do
      :input ->
        input_tokens = usage_value(usage, "input_tokens")

        if input_includes_cached do
          max(input_tokens - cached_read - cache_write, 0)
        else
          input_tokens
        end

      :output ->
        usage_value(usage, "output_tokens")

      :reasoning ->
        usage_value(usage, "reasoning_tokens")

      :cache_read ->
        cached_read

      :cache_write ->
        cache_write

      :cache ->
        cached_read

      nil ->
        usage_value(usage, id)
    end
  end

  defp token_meter_for_id(id) when is_binary(id) do
    Enum.find_value(@token_id_map, fn {prefix, key} ->
      if String.starts_with?(id, prefix), do: key
    end)
  end

  defp token_meter_for_id(_), do: nil

  defp usage_value(usage, key) do
    case MapAccess.get(usage, key) do
      nil -> 0
      value -> value
    end
  end

  defp input_includes_cached?(usage) do
    case Map.fetch(usage, :input_includes_cached) do
      {:ok, value} when is_boolean(value) ->
        value

      _ ->
        case Map.fetch(usage, "input_includes_cached") do
          {:ok, value} when is_boolean(value) -> value
          _ -> true
        end
    end
  end

  defp token_cost_breakdown(line_items) do
    input_cost =
      line_items
      |> Enum.filter(&token_input_item?/1)
      |> Enum.reduce(0.0, fn item, acc -> Float.round(acc + item.cost, 6) end)

    reasoning_cost =
      line_items
      |> Enum.filter(&token_reasoning_item?/1)
      |> Enum.reduce(0.0, fn item, acc -> Float.round(acc + item.cost, 6) end)

    output_cost =
      line_items
      |> Enum.filter(&token_output_item?/1)
      |> Enum.reduce(0.0, fn item, acc -> Float.round(acc + item.cost, 6) end)

    %{input_cost: input_cost, output_cost: output_cost, reasoning_cost: reasoning_cost}
  end

  defp token_input_item?(%{id: id}) when is_binary(id) do
    String.starts_with?(id, "token.input") or String.starts_with?(id, "token.cache")
  end

  defp token_input_item?(_), do: false

  defp token_reasoning_item?(%{id: id}) when is_binary(id) do
    String.starts_with?(id, "token.reasoning")
  end

  defp token_reasoning_item?(_), do: false

  defp token_output_item?(%{id: id}) when is_binary(id) do
    String.starts_with?(id, "token.output") or String.starts_with?(id, "token.reasoning")
  end

  defp token_output_item?(_), do: false
end

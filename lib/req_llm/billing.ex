defmodule ReqLLM.Billing do
  @moduledoc false

  alias ReqLLM.Billing.Component
  alias ReqLLM.MapAccess
  alias ReqLLM.Pricing
  alias ReqLLM.Usage.Image
  alias ReqLLM.Usage.Tool

  @token_meters [:input, :output, :reasoning, :cache_read, :cache_write]

  @spec calculate(map(), LLMDB.Model.t() | nil, map() | keyword()) :: {:ok, map() | nil}
  def calculate(usage, model, context \\ %{})
  def calculate(_usage, nil, _context), do: {:ok, nil}

  def calculate(usage, %LLMDB.Model{} = model, context) when is_map(usage) do
    with true <- Pricing.components(model) != [],
         {:ok, meters} <- meters(usage, model),
         {:ok, write_groups} <- cache_write_groups(usage, meters),
         {:ok, context} <- selection_context(context, meters),
         selection <- LLMDB.Pricing.components_for(model, context),
         main_meters <- if(write_groups, do: %{meters | cache_write: 0}, else: meters),
         {:ok, rates, modifiers} <- selected_components(selection, main_meters, usage),
         :ok <- validate_coverage(rates, selection, main_meters, usage),
         main_rates <-
           if(write_groups, do: Enum.reject(rates, &(meter_key(&1) == :cache_write)), else: rates),
         {:ok, items} <- price_components(main_rates, modifiers, main_meters, usage, rates),
         {:ok, write_items} <-
           price_cache_write_groups(model, context, meters, usage, write_groups) do
      {:ok, cost_summary(items ++ write_items, model)}
    else
      _ -> {:ok, nil}
    end
  end

  defp selection_context(context, meters) when is_list(context) do
    if Keyword.keyword?(context),
      do: selection_context(Map.new(context), meters),
      else: :error
  end

  defp selection_context(context, meters) when is_map(context) do
    if MapAccess.get(context, :service_tier) in ["auto", :auto] do
      :error
    else
      {:ok, context |> Map.delete("input_tokens") |> Map.put(:input_tokens, meters.prompt)}
    end
  end

  defp selection_context(_, _), do: :error

  defp meters(usage, model) do
    input = usage_number(usage, [:input_tokens, :input])
    output = usage_number(usage, [:output_tokens, :output])
    cache_read = usage_number(usage, [:cache_read_tokens, :cached_tokens, :cached_input], 0)

    cache_write =
      usage_number(usage, [:cache_write_tokens, :cache_creation_tokens, :cache_creation], 0)

    reasoning = usage_number(usage, [:reasoning_tokens, :reasoning], 0)

    includes_cached =
      Map.get(usage, :input_includes_cached, Map.get(usage, "input_includes_cached", true))

    reported = MapAccess.get(usage, :usage_reported, %{})
    complete = Map.get(usage, :billing_usage_complete, true)

    if valid_token_count?(input) and valid_token_count?(output) and
         valid_token_count?(cache_read) and valid_token_count?(cache_write) and
         valid_token_count?(reasoning) and is_boolean(includes_cached) and
         Map.get(reported, :input, Map.get(reported, "input", true)) and
         (Map.get(reported, :output, Map.get(reported, "output", true)) or
            not token_component?(model, :output)) and complete do
      uncached = if includes_cached, do: input - cache_read - cache_write, else: input
      prompt = if includes_cached, do: input, else: input + cache_read + cache_write

      if uncached >= 0 do
        {:ok,
         %{
           input: uncached,
           output: output,
           cache_read: cache_read,
           cache_write: cache_write,
           reasoning: reasoning,
           prompt: prompt,
           add_reasoning: MapAccess.get(usage, :add_reasoning_to_cost, false)
         }}
      else
        :error
      end
    else
      :error
    end
  end

  defp usage_number(usage, keys, default \\ nil),
    do: Enum.find_value(keys, default, &MapAccess.get(usage, &1))

  defp valid_count?(value), do: is_number(value) and value >= 0
  defp valid_token_count?(value), do: is_integer(value) and value >= 0

  defp token_component?(model, key) do
    model
    |> Pricing.components()
    |> Enum.map(&Component.from/1)
    |> Enum.any?(&(meter_key(&1) == key))
  end

  defp cache_write_groups(usage, meters) do
    case MapAccess.get(usage, :cache_write_tokens_by_ttl) do
      nil ->
        {:ok, nil}

      groups when is_map(groups) ->
        normalized =
          Map.new(groups, fn {ttl, count} ->
            {if(is_atom(ttl) or is_binary(ttl), do: to_string(ttl), else: nil), count}
          end)

        if map_size(normalized) == map_size(groups) and
             Enum.all?(normalized, fn {ttl, count} ->
               is_binary(ttl) and valid_token_count?(count)
             end) and
             Enum.sum(Map.values(normalized)) == meters.cache_write do
          {:ok, Map.reject(normalized, fn {_ttl, count} -> count == 0 end)}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp price_cache_write_groups(_model, _context, _meters, _usage, nil), do: {:ok, []}

  defp price_cache_write_groups(model, context, meters, usage, groups) do
    Enum.reduce_while(groups, {:ok, []}, fn {ttl, count}, {:ok, items} ->
      group_meters = %{
        meters
        | input: 0,
          output: 0,
          reasoning: 0,
          cache_read: 0,
          cache_write: count
      }

      selection = LLMDB.Pricing.components_for(model, Map.put(context, :cache_ttl, ttl))

      with {:ok, rates, modifiers} <- selected_components(selection, group_meters, usage),
           :ok <- validate_coverage(rates, selection, group_meters, usage),
           write_rates <- Enum.filter(rates, &(meter_key(&1) == :cache_write)),
           {:ok, write_items} <-
             price_components(write_rates, modifiers, group_meters, usage, rates) do
        {:cont, {:ok, items ++ write_items}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp selected_components(selection, meters, usage) do
    selected = Enum.map(selection.components, &Component.from/1)
    unresolved = Enum.map(selection.unresolved, &Component.from/1)
    rates = Enum.reject(selected, &modifier?/1)
    modifiers = Enum.filter(selected, &modifier?/1)

    billable =
      Enum.any?(selected ++ unresolved, fn component ->
        not modifier?(component) and relevant?(component, meters, usage)
      end)

    if Enum.any?(unresolved, fn component ->
         if modifier?(component), do: billable, else: relevant?(component, meters, usage)
       end) or
         Enum.any?(modifiers, &unsupported_modifier?/1) or
         Enum.any?(rates, &unsupported_rate?/1) do
      :error
    else
      {:ok, rates, modifiers}
    end
  end

  defp modifier?(%Component{kind: nil, multiplier: multiplier}) when is_number(multiplier),
    do: true

  defp modifier?(%Component{kind: nil, applies_to: targets}) when is_list(targets), do: true
  defp modifier?(%Component{kind: nil, id: "pricing." <> _}), do: true
  defp modifier?(_), do: false

  defp unsupported_modifier?(%Component{
         multiplier: multiplier,
         applies_to: targets,
         charge_scope: scope
       }) do
    not (is_number(multiplier) and multiplier >= 0 and is_list(targets) and targets != [] and
           Enum.all?(targets, &valid_modifier_target?/1) and scope in [nil, "full_request"])
  end

  defp valid_modifier_target?(target) when is_binary(target) do
    case String.split(target, "*") do
      [exact] -> exact != ""
      [prefix, ""] -> String.ends_with?(prefix, ".") and byte_size(prefix) > 1
      _ -> false
    end
  end

  defp valid_modifier_target?(_), do: false

  defp unsupported_rate?(%Component{kind: nil}), do: true

  defp unsupported_rate?(%Component{charge_scope: scope}) when scope not in [nil, "full_request"],
    do: true

  defp unsupported_rate?(_), do: false

  defp relevant?(%Component{} = component, meters, usage) do
    case meter_key(component) do
      key when key in @token_meters ->
        Map.fetch!(meters, key) > 0

      _ ->
        case component_count(component, meters, usage) do
          {:ok, count} -> count > 0
          _ -> true
        end
    end
  end

  defp validate_coverage(rates, selection, meters, usage) do
    selected_keys = Enum.map(rates, &meter_key/1)

    candidate_keys =
      Enum.map(
        selection.components ++ selection.unresolved,
        &(&1 |> Component.from() |> meter_key())
      )

    required_keys =
      @token_meters
      |> Enum.filter(&(Map.fetch!(meters, &1) > 0))
      |> Enum.reject(&(&1 == :reasoning and :reasoning not in candidate_keys))

    active_keys =
      rates
      |> Enum.filter(&relevant?(&1, meters, usage))
      |> Enum.map(&meter_key/1)

    if Enum.all?(required_keys, &(&1 in selected_keys)) and
         length(active_keys) == length(Enum.uniq(active_keys)) do
      :ok
    else
      :error
    end
  end

  defp price_components(rates, modifiers, meters, usage, resolution_rates) do
    by_id = Map.new(resolution_rates, &{Component.id_string(&1), &1})

    meters = %{
      meters
      | add_reasoning:
          meters.add_reasoning and not Enum.any?(rates, &(meter_key(&1) == :reasoning))
    }

    rates
    |> Enum.reduce_while({:ok, []}, fn component, {:ok, items} ->
      with {:ok, count} <- component_count(component, meters, usage),
           {:ok, rate, per} <- resolve_rate(component, by_id),
           {:ok, adjusted_rate} <- apply_modifiers(component, rate, modifiers) do
        item = %{
          id: component.id,
          component: Component.id_string(component) || component.id,
          count: count,
          quantity: count,
          kind: component.kind,
          rate: adjusted_rate,
          per: per,
          cost: Float.round(count / per * adjusted_rate, 6)
        }

        {:cont, {:ok, [item | items]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      :error -> :error
    end
  end

  defp resolve_rate(%Component{derives_from: nil, rate: rate, per: per}, _by_id)
       when is_number(rate) and rate >= 0 and is_number(per) and per > 0,
       do: {:ok, rate, per}

  defp resolve_rate(%Component{derives_from: base_id, multiplier: multiplier} = component, by_id)
       when is_binary(base_id) and is_number(multiplier) and multiplier >= 0 do
    case by_id[base_id] do
      %Component{derives_from: nil, rate: base_rate, per: base_per}
      when is_number(base_rate) and base_rate >= 0 and is_number(base_per) and base_per > 0 ->
        per = component.per || base_per

        if is_number(per) and per > 0,
          do: {:ok, base_rate * multiplier * per / base_per, per},
          else: :error

      _ ->
        :error
    end
  end

  defp resolve_rate(_, _), do: :error

  defp apply_modifiers(component, rate, modifiers) do
    id = Component.id_string(component)

    if is_binary(id) do
      multiplier =
        Enum.reduce(modifiers, 1.0, fn modifier, acc ->
          if Enum.any?(modifier.applies_to, &target_matches?(&1, id)),
            do: acc * modifier.multiplier,
            else: acc
        end)

      {:ok, rate * multiplier}
    else
      :error
    end
  end

  defp target_matches?(target, id) do
    case String.split(target, ".*", parts: 2) do
      [prefix, ""] -> String.starts_with?(id, prefix <> ".")
      _ -> target == id
    end
  end

  defp component_count(%Component{kind: :tokens} = component, meters, _usage) do
    case meter_key(component) do
      :output -> {:ok, meters.output + if(meters.add_reasoning, do: meters.reasoning, else: 0)}
      key when key in @token_meters -> {:ok, Map.fetch!(meters, key)}
      _ -> :error
    end
  end

  defp component_count(%Component{kind: :tools, tool: tool, unit: unit}, _meters, usage) do
    entry = usage |> MapAccess.get(:tool_usage, %{}) |> Tool.entry(tool)
    count = MapAccess.get(entry, :count, 0)
    reported_unit = Tool.normalize_unit(MapAccess.get(entry, :unit))

    if valid_count?(count) and (count == 0 or unit == nil or unit == reported_unit),
      do: {:ok, count},
      else: :error
  end

  defp component_count(%Component{kind: :images, size_class: size}, _meters, usage) do
    count = Image.count_generated(usage, size)
    if valid_count?(count), do: {:ok, count}, else: :error
  end

  defp component_count(%Component{kind: :storage, meter: meter, id: id}, _meters, usage) do
    count = MapAccess.get(usage, meter || "storage")
    count = if is_nil(count) and id != "storage.cache", do: 0, else: count
    if valid_count?(count), do: {:ok, count}, else: :error
  end

  defp component_count(_, _, _), do: :error

  defp meter_key(%Component{kind: :tokens} = component) do
    id = Component.id_string(component) || ""

    cond do
      String.starts_with?(id, "token.cache_read") or id == "token.cache" or
          String.starts_with?(id, "token.cache.") ->
        :cache_read

      String.starts_with?(id, "token.cache_write") ->
        :cache_write

      String.starts_with?(id, "token.input") ->
        :input

      String.starts_with?(id, "token.output") ->
        :output

      String.starts_with?(id, "token.reasoning") ->
        :reasoning

      true ->
        component.meter
    end
  end

  defp meter_key(%Component{kind: :tools, tool: tool, unit: unit}), do: {:tool, tool, unit}
  defp meter_key(%Component{kind: :images, size_class: size}), do: {:image, size}
  defp meter_key(%Component{kind: :storage, meter: meter}), do: {:storage, meter}
  defp meter_key(component), do: component.id

  defp cost_summary(items, model) do
    totals =
      Enum.reduce(items, %{tokens: 0.0, tools: 0.0, images: 0.0, storage: 0.0}, fn item, acc ->
        Map.update!(acc, item.kind, &Float.round(&1 + item.cost, 6))
      end)

    currency = MapAccess.get(model.pricing, :currency, "USD")
    token_items = Enum.filter(items, &(&1.kind == :tokens))

    cost_fields =
      if currency == "USD" do
        %{
          input_cost:
            sum_items(token_items, [
              "token.input",
              "token.cache_read",
              "token.cache_write",
              "token.cache"
            ]),
          output_cost: sum_items(token_items, ["token.output", "token.reasoning"]),
          reasoning_cost: sum_items(token_items, ["token.reasoning"])
        }
      else
        %{}
      end

    Map.merge(totals, %{
      currency: currency,
      total: Float.round(totals.tokens + totals.tools + totals.images + totals.storage, 6),
      line_items: items
    })
    |> Map.merge(cost_fields)
  end

  defp sum_items(items, prefixes) do
    Enum.reduce(items, 0.0, fn item, acc ->
      if Enum.any?(prefixes, &String.starts_with?(item.component, &1)),
        do: Float.round(acc + item.cost, 6),
        else: acc
    end)
  end
end

defmodule ReqLLM.Usage.Cost do
  @moduledoc false

  alias ReqLLM.MapAccess

  @spec apply(map(), LLMDB.Model.t() | nil, keyword()) :: map()
  def apply(usage, model, opts \\ [])

  def apply(usage, model, opts) when is_map(usage) do
    usage = maybe_put_total_cost(usage, Keyword.get(opts, :original_usage))

    case model do
      %LLMDB.Model{} ->
        case breakdown(usage, model) do
          {:ok, nil} -> usage
          {:ok, cost_breakdown} -> merge(usage, cost_breakdown, opts)
        end

      _ ->
        usage
    end
  end

  def apply(usage, _model, _opts), do: usage

  @spec breakdown(map(), LLMDB.Model.t()) :: {:ok, map() | nil}
  def breakdown(usage, %LLMDB.Model{} = model) when is_map(usage) do
    if tokens_numeric?(usage) do
      case ReqLLM.Billing.calculate(usage, model) do
        {:ok, nil} ->
          {:ok, nil}

        {:ok, cost} ->
          {:ok,
           %{
             input_cost: cost.input_cost,
             output_cost: cost.output_cost,
             reasoning_cost: cost.reasoning_cost,
             total_cost: cost.total,
             cost: cost
           }}
      end
    else
      {:ok, nil}
    end
  end

  def breakdown(_, _), do: {:ok, nil}

  @spec merge(map(), map() | nil, keyword()) :: map()
  def merge(usage, cost_breakdown, opts \\ [])

  def merge(usage, nil, _opts), do: usage

  def merge(usage, cost_breakdown, opts) do
    usage =
      usage
      |> Map.put(:cost, cost_breakdown.cost)
      |> Map.put(:input_cost, cost_breakdown.input_cost)
      |> Map.put(:output_cost, cost_breakdown.output_cost)
      |> Map.put(:reasoning_cost, cost_breakdown.reasoning_cost)

    if Keyword.get(opts, :preserve_total_cost, false) do
      Map.put_new(usage, :total_cost, cost_breakdown.total_cost)
    else
      Map.put(usage, :total_cost, cost_breakdown.total_cost)
    end
  end

  @spec maybe_put_total_cost(map(), map() | nil) :: map()
  def maybe_put_total_cost(usage, original_usage) when is_map(original_usage) do
    case MapAccess.get(original_usage, :total_cost) || MapAccess.get(original_usage, "total_cost") do
      value when is_number(value) -> Map.put(usage, :total_cost, value)
      _ -> usage
    end
  end

  def maybe_put_total_cost(usage, _), do: usage

  defp tokens_numeric?(usage) do
    input = MapAccess.get(usage, :input_tokens) || MapAccess.get(usage, "input_tokens")
    output = MapAccess.get(usage, :output_tokens) || MapAccess.get(usage, "output_tokens")
    total = MapAccess.get(usage, :total_tokens) || MapAccess.get(usage, "total_tokens")

    is_number(input) and is_number(output) and (total == nil or is_number(total))
  end
end

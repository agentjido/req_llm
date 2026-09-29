defmodule ReqLLM.Usage.Cost do
  @moduledoc false

  alias ReqLLM.MapAccess

  @spec apply(map(), LLMDB.Model.t() | nil, keyword()) :: map()
  def apply(usage, model, opts \\ [])

  def apply(usage, model, opts) when is_map(usage) do
    case model do
      %LLMDB.Model{} ->
        case breakdown(usage, model, Keyword.get(opts, :pricing_context)) do
          {:ok, nil} -> merge(usage, nil, opts)
          {:ok, cost_breakdown} -> merge(usage, cost_breakdown, opts)
        end

      _ ->
        usage
    end
  end

  def apply(usage, _model, _opts), do: usage

  @spec breakdown(map(), LLMDB.Model.t(), map() | keyword() | nil) :: {:ok, map() | nil}
  def breakdown(usage, model, context \\ nil)

  def breakdown(usage, %LLMDB.Model{} = model, context) when is_map(usage) do
    if tokens_numeric?(usage) do
      case ReqLLM.Billing.calculate(usage, model, context || %{}) do
        {:ok, nil} ->
          {:ok, nil}

        {:ok, %{currency: "USD"} = cost} ->
          {:ok,
           %{
             pricing: %{status: :priced, currency: "USD", total: cost.total},
             input_cost: cost.input_cost,
             output_cost: cost.output_cost,
             reasoning_cost: cost.reasoning_cost,
             total_cost: cost.total,
             cost: cost
           }}

        {:ok, cost} ->
          {:ok,
           %{pricing: %{status: :priced, currency: cost.currency, total: cost.total}, cost: cost}}
      end
    else
      {:ok, nil}
    end
  end

  def breakdown(_, _, _), do: {:ok, nil}

  @spec merge(map(), map() | nil, keyword()) :: map()
  def merge(usage, cost_breakdown, opts \\ [])

  def merge(usage, nil, _opts) do
    usage
    |> Map.drop([:cost, :input_cost, :output_cost, :reasoning_cost, :total_cost])
    |> Map.put(:pricing, %{status: :unknown})
  end

  def merge(usage, cost_breakdown, _opts) do
    if cost_breakdown.pricing.currency == "USD" do
      usage
      |> Map.put(:pricing, cost_breakdown.pricing)
      |> Map.put(:cost, cost_breakdown.cost)
      |> Map.put(:input_cost, cost_breakdown.input_cost)
      |> Map.put(:output_cost, cost_breakdown.output_cost)
      |> Map.put(:reasoning_cost, cost_breakdown.reasoning_cost)
      |> Map.put(:total_cost, cost_breakdown.total_cost)
    else
      usage
      |> Map.drop([:cost, :input_cost, :output_cost, :reasoning_cost, :total_cost])
      |> Map.put(:pricing, cost_breakdown.pricing)
    end
  end

  defp tokens_numeric?(usage) do
    input = MapAccess.get(usage, :input_tokens) || MapAccess.get(usage, "input_tokens")
    output = MapAccess.get(usage, :output_tokens) || MapAccess.get(usage, "output_tokens")
    total = MapAccess.get(usage, :total_tokens) || MapAccess.get(usage, "total_tokens")

    is_number(input) and is_number(output) and (total == nil or is_number(total))
  end
end

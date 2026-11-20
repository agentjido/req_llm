defmodule ReqLLM.Kino.Request do
  @moduledoc false

  alias ReqLLM.Kino.ModelPicker
  alias ReqLLM.Response

  def resolve!(model_spec, operation, request_options) do
    model = ReqLLM.model!(model_spec)
    options = ReqLLM.ModelInput.merge_tuple_defaults(model_spec, operation, request_options)
    {model, options}
  end

  def run(generate, {model, options}, input) do
    options = Keyword.merge(ModelPicker.request_options(model), options)

    case generate.(model, input, options) do
      {:ok, %Response{}} = result ->
        result

      {:error, %{status: status}} when status in 400..599 ->
        {:error, "Request failed (HTTP #{status})."}

      {:error, _reason} ->
        {:error, "Request failed. Check the model, provider, and API key."}
    end
  rescue
    _error -> {:error, "Could not complete the request."}
  end

  def measurements(%Response{usage: usage}) do
    usage = usage || %{}
    tokens = if is_number(usage[:total_tokens]), do: "Tokens: #{usage.total_tokens}"

    cost =
      if is_number(usage[:total_cost]) do
        "Cost: $#{:erlang.float_to_binary(usage.total_cost * 1.0, [:compact, decimals: 6])}"
      end

    Enum.reject([tokens, cost], &is_nil/1)
  end
end

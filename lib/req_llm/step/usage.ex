defmodule ReqLLM.Step.Usage do
  @moduledoc """
  Centralized Req step that extracts token usage from provider responses,
  normalizes usage values across providers, computes costs, and emits telemetry.

  This step:
  * Extracts token usage numbers from provider responses
  * Normalizes usage data across different provider formats
  * Calculates costs using ReqLLM.Model cost metadata
  * Stores usage data in `response.private[:req_llm][:usage]`
  * Emits telemetry events for monitoring

  ## Usage

      request
      |> ReqLLM.Step.Usage.attach(model)

  ## Telemetry Events

  Emits `[:req_llm, :token_usage]` events with:
  * Measurements: `%{tokens: %{input: 123, output: 456, reasoning: 64}, cost: 0.0123}`
  * Metadata: `%{model: %LLMDB.Model{}}`
  """

  alias ReqLLM.Usage.Cost

  @event [:req_llm, :token_usage]

  @doc """
  Attaches the Usage step to a Req request.

  ## Parameters

  - `req` - The Req.Request struct
  - `model` - Optional ReqLLM.Model struct for cost calculation

  ## Examples

      request
      |> ReqLLM.Step.Usage.attach(model)

  """
  @spec attach(Req.Request.t(), LLMDB.Model.t() | nil) :: Req.Request.t()
  def attach(%Req.Request{} = req, model \\ nil) do
    req
    |> Req.Request.append_response_steps(llm_usage: &__MODULE__.handle/1)
    |> then(fn r ->
      if model, do: Req.Request.put_private(r, :req_llm_model, model), else: r
    end)
  end

  @doc false
  @spec handle({Req.Request.t(), Req.Response.t()}) :: {Req.Request.t(), Req.Response.t()}
  def handle({req, resp}) do
    with {:ok, model} <- fetch_model(req),
         provider_module = provider_module_from_model(model),
         {:ok, usage} <- extract_usage(resp.body, provider_module, model),
         {:ok, cost_breakdown} <- Cost.breakdown(usage, model) do
      total_cost = cost_breakdown && cost_breakdown.total_cost
      meta = %{tokens: usage, cost: total_cost}

      meta =
        if cost_breakdown do
          Map.merge(meta, %{
            input_cost: cost_breakdown.input_cost,
            output_cost: cost_breakdown.output_cost,
            reasoning_cost: cost_breakdown.reasoning_cost,
            total_cost: cost_breakdown.total_cost
          })
        else
          meta
        end

      :telemetry.execute(@event, meta, %{model: model})

      req_llm_data = Map.get(resp.private, :req_llm, %{})
      updated_req_llm_data = Map.put(req_llm_data, :usage, meta)

      updated_resp =
        case resp.body do
          %ReqLLM.Response{usage: response_usage} when is_map(response_usage) ->
            cached_read_tokens = usage[:cached_input] || 0
            cache_creation_tokens = usage[:cache_creation] || 0

            augmented_usage =
              response_usage
              |> Map.put_new(:input_tokens, usage.input)
              |> Map.put_new(:output_tokens, usage.output)
              |> maybe_put_total_tokens(usage.total_tokens)
              |> Map.put(:reasoning_tokens, usage.reasoning)
              |> Map.put(:cached_tokens, cached_read_tokens)
              |> Map.put(:cache_creation_tokens, cache_creation_tokens)
              |> Map.put(:tool_usage, usage.tool_usage)
              |> Map.put(:image_usage, usage.image_usage)
              |> Cost.merge(cost_breakdown)

            updated_body = %{resp.body | usage: augmented_usage}
            %{resp | body: updated_body}

          _ ->
            resp
        end

      updated_resp = %{
        updated_resp
        | private: Map.put(updated_resp.private, :req_llm, updated_req_llm_data)
      }

      {req, updated_resp}
    else
      _ -> {req, resp}
    end
  end

  @spec provider_module_from_model(LLMDB.Model.t()) :: module() | nil
  defp provider_module_from_model(%LLMDB.Model{provider: provider_id}) do
    case ReqLLM.provider(provider_id) do
      {:ok, module} -> module
      _ -> nil
    end
  end

  @spec extract_usage(any, module() | nil, LLMDB.Model.t() | nil) :: {:ok, map()} | :error
  defp extract_usage(body, provider_module, model) do
    case provider_module do
      nil -> fallback_extract_usage(body)
      module -> provider_extract_usage(body, module, model) || fallback_extract_usage(body)
    end
  end

  defp provider_extract_usage(body, module, model) when is_atom(module) do
    if function_exported?(module, :extract_usage, 2) do
      case module.extract_usage(body, model) do
        {:ok, usage} -> {:ok, ReqLLM.Usage.Normalize.normalize(usage)}
        _ -> nil
      end
    end
  end

  @spec fallback_extract_usage(any) :: {:ok, map()} | :error
  defp fallback_extract_usage(%{"usage" => usage}) when is_map(usage) do
    {:ok, ReqLLM.Usage.Normalize.normalize(usage)}
  end

  defp fallback_extract_usage(%{"prompt_tokens" => input, "completion_tokens" => output}) do
    {:ok, ReqLLM.Usage.Normalize.normalize(%{input: input, output: output})}
  end

  defp fallback_extract_usage(%{"input_tokens" => input, "output_tokens" => output}) do
    {:ok, ReqLLM.Usage.Normalize.normalize(%{input: input, output: output})}
  end

  defp fallback_extract_usage(%ReqLLM.Response{usage: usage}) when is_map(usage) do
    {:ok, ReqLLM.Usage.Normalize.normalize(usage)}
  end

  defp fallback_extract_usage(_), do: :error

  defp maybe_put_total_tokens(map, total) when is_number(total) do
    Map.put_new(map, :total_tokens, total)
  end

  defp maybe_put_total_tokens(map, _total), do: map

  @spec fetch_model(Req.Request.t()) :: {:ok, LLMDB.Model.t()} | :error
  defp fetch_model(%Req.Request{private: private, options: options}) do
    case private[:req_llm_model] || options[:model] do
      %LLMDB.Model{} = model -> {:ok, model}
      _ -> :error
    end
  end
end

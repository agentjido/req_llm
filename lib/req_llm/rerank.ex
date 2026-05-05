defmodule ReqLLM.Rerank do
  @moduledoc """
  Reranking functionality for ReqLLM.

  This module provides document reranking with support for:
  - Single-query reranking against a document set
  - Automatic batching for large document collections
  - Provider-specific rerank options

  ## Usage

      {:ok, response} =
        ReqLLM.Rerank.rerank(
          "cohere:rerank-v3.5",
          query: "What is deep learning?",
          documents: ["Doc 1", "Doc 2", "Doc 3"],
          top_n: 2
        )

      response.results
      #=> [%{index: 1, relevance_score: 0.97, document: "Doc 2"}, ...]
  """

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  alias LLMDB.Model
  alias ReqLLM.RerankResponse

  @recommended_batch_size 1000

  @base_schema NimbleOptions.new!(
                 query: [
                   type: :string,
                   required: true,
                   doc: "Search query used to rank the supplied documents"
                 ],
                 documents: [
                   type: {:list, :string},
                   required: true,
                   doc: "Documents to rerank against the query"
                 ],
                 top_n: [
                   type: :pos_integer,
                   doc: "Maximum number of reranked results to return"
                 ],
                 batch_size: [
                   type: :pos_integer,
                   doc:
                     "Maximum number of documents to send per request. Defaults to 1000 when batching is needed."
                 ],
                 max_tokens_per_doc: [
                   type: :pos_integer,
                   doc: "Maximum number of tokens to consider per document"
                 ],
                 provider_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "Provider-specific options (keyword list or map)",
                   default: []
                 ],
                 req_http_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "Req-specific options (keyword list or map)",
                   default: []
                 ],
                 telemetry: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "ReqLLM telemetry options (for example, [payloads: :raw])",
                   default: []
                 ],
                 receive_timeout: [
                   type: :pos_integer,
                   doc: "Timeout for receiving HTTP responses in milliseconds"
                 ],
                 max_retries: [
                   type: :non_neg_integer,
                   default: 3,
                   doc:
                     "Maximum number of retry attempts for transient network errors. Set to 0 to disable retries."
                 ],
                 on_unsupported: [
                   type: {:in, [:warn, :error, :ignore]},
                   default: :warn,
                   doc: "How to handle provider option translation warnings"
                 ],
                 fixture: [
                   type: {:or, [:string, {:tuple, [:atom, :string]}]},
                   doc: "HTTP fixture for testing (provider inferred from model if string)"
                 ]
               )

  @doc """
  Returns the base reranking options schema.
  """
  @spec schema :: NimbleOptions.t()
  def schema, do: @base_schema

  @doc """
  Validates that a model supports reranking operations.
  """
  @spec validate_model(ReqLLM.model_input()) ::
          {:ok, Model.t()} | {:error, term()}
  def validate_model(model_spec) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, _provider_module} <- ReqLLM.provider(model.provider) do
      model_string = LLMDB.Model.spec(model)

      if rerank_capable_model?(model) do
        {:ok, model}
      else
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter: "model: #{model_string} does not support reranking operations"
         )}
      end
    end
  end

  @doc """
  Reranks documents against a query.

  Returns a `ReqLLM.RerankResponse` with results ordered from highest relevance
  to lowest relevance.
  """
  def rerank(model_spec, opts \\ [])

  @spec rerank(ReqLLM.model_input(), keyword()) :: {:ok, RerankResponse.t()} | {:error, term()}
  def rerank(model_spec, opts) when is_list(opts) do
    with :ok <- validate_query(Keyword.get(opts, :query)),
         :ok <- validate_documents(Keyword.get(opts, :documents)),
         :ok <- validate_batch_size(Keyword.get(opts, :batch_size)),
         {:ok, model} <- validate_model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, batch_responses} <-
           rerank_batches(
             provider_module,
             model,
             Keyword.fetch!(opts, :query),
             Keyword.fetch!(opts, :documents),
             opts
           ) do
      build_response(model, Keyword.fetch!(opts, :query), opts, batch_responses)
    end
  end

  def rerank(_model_spec, other) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "opts: expected a keyword list, got: #{inspect(other)}"
     )}
  end

  @doc """
  Same as `rerank/2` but raises on error.
  """
  @spec rerank!(ReqLLM.model_input(), keyword()) :: RerankResponse.t() | no_return()
  def rerank!(model_spec, opts \\ []) do
    case rerank(model_spec, opts) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end

  defp rerank_capable_model?(%Model{} = model) do
    model_id = to_string(model.provider_model_id || model.id || "")
    capabilities = model.capabilities || %{}

    (model.provider == :cohere and String.contains?(model_id, "rerank")) or
      rerank_enabled?(capabilities)
  end

  defp rerank_enabled?(capabilities) when is_map(capabilities) do
    case capabilities[:rerank] do
      true -> true
      %{enabled: true} -> true
      _ -> false
    end
  end

  defp rerank_enabled?(_), do: false

  defp validate_query(query) when is_binary(query) and query != "", do: :ok

  defp validate_query(_query) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(parameter: "query: expected a non-empty string")}
  end

  defp validate_documents(documents) when is_list(documents) and documents != [] do
    if Enum.all?(documents, &is_binary/1) do
      :ok
    else
      {:error,
       ReqLLM.Error.Invalid.Parameter.exception(
         parameter: "documents: expected a non-empty list of strings"
       )}
    end
  end

  defp validate_documents(_documents) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "documents: expected a non-empty list of strings"
     )}
  end

  defp validate_batch_size(nil), do: :ok
  defp validate_batch_size(batch_size) when is_integer(batch_size) and batch_size > 0, do: :ok

  defp validate_batch_size(_batch_size) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "batch_size: expected a positive integer"
     )}
  end

  defp rerank_batches(provider_module, model, query, documents, opts) do
    batch_size = effective_batch_size(documents, Keyword.get(opts, :batch_size))
    batched_documents = batch_documents(documents, batch_size)
    single_batch? = length(batched_documents) == 1
    request_opts = Keyword.drop(opts, [:batch_size, :query, :documents])
    request_opts = maybe_delete_top_n(request_opts, single_batch?)

    Enum.reduce_while(batched_documents, {:ok, []}, fn {batch_docs, offset}, {:ok, acc} ->
      case rerank_batch(provider_module, model, query, batch_docs, request_opts) do
        {:ok, response_body} -> {:cont, {:ok, [{response_body, offset} | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> then(fn
      {:ok, responses} -> {:ok, Enum.reverse(responses)}
      {:error, error} -> {:error, error}
    end)
  end

  defp effective_batch_size(documents, nil) when length(documents) > @recommended_batch_size do
    @recommended_batch_size
  end

  defp effective_batch_size(documents, nil), do: length(documents)
  defp effective_batch_size(_documents, batch_size), do: batch_size

  defp batch_documents(documents, batch_size) do
    documents
    |> Enum.chunk_every(batch_size)
    |> Enum.with_index()
    |> Enum.map(fn {batch_docs, batch_index} ->
      {batch_docs, batch_index * batch_size}
    end)
  end

  defp maybe_delete_top_n(opts, true), do: opts
  defp maybe_delete_top_n(opts, false), do: Keyword.delete(opts, :top_n)

  defp rerank_batch(provider_module, model, query, documents, opts) do
    with {:ok, request} <-
           provider_module.prepare_request(
             :rerank,
             model,
             %{query: query, documents: documents},
             opts
           ),
         {:ok, %Req.Response{status: status} = response} when status in 200..299 <-
           Req.request(request) do
      {:ok, response}
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Rerank request failed",
           status: status,
           response_body: body
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp build_response(model, query, opts, batch_responses) do
    documents = Keyword.fetch!(opts, :documents)
    requested_top_n = Keyword.get(opts, :top_n)

    with {:ok, parsed_batches} <- parse_batch_responses(batch_responses, documents) do
      results =
        parsed_batches
        |> Enum.flat_map(& &1.results)
        |> Enum.sort_by(fn %{index: index, relevance_score: score} -> {-score, index} end)
        |> maybe_take_top_n(requested_top_n)

      ids = Enum.map(parsed_batches, & &1.id)
      metas = Enum.map(parsed_batches, & &1.meta)

      usages =
        Enum.map(batch_responses, fn
          {%Req.Response{private: private}, _offset} -> get_in(private, [:req_llm, :usage])
          _ -> nil
        end)

      {:ok,
       %RerankResponse{
         id: merge_ids(ids),
         model: model.provider_model_id || model.id,
         query: query,
         results: results,
         meta: merge_meta(metas, length(parsed_batches), usages)
       }}
    end
  end

  defp parse_batch_responses(batch_responses, documents) do
    Enum.reduce_while(batch_responses, {:ok, []}, fn {%{body: body}, offset}, {:ok, acc} ->
      case parse_batch_response(body, offset, documents) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> then(fn
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, error} -> {:error, error}
    end)
  end

  defp parse_batch_response(body, offset, documents) do
    body = ReqLLM.Provider.Utils.ensure_parsed_body(body)

    case fetch_value(body, :results) do
      results when is_list(results) ->
        with {:ok, parsed_results} <- parse_results(results, offset, documents) do
          {:ok,
           %{
             id: fetch_value(body, :id),
             results: parsed_results,
             meta: normalize_meta(fetch_value(body, :meta))
           }}
        end

      _ ->
        {:error,
         ReqLLM.Error.API.Response.exception(
           reason: "Invalid rerank response format",
           response_body: body
         )}
    end
  end

  defp parse_results(results, offset, documents) do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, acc} ->
      case parse_result(result, offset, documents) do
        {:ok, parsed_result} -> {:cont, {:ok, [parsed_result | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> then(fn
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, error} -> {:error, error}
    end)
  end

  defp parse_result(result, offset, documents) when is_map(result) do
    index = fetch_value(result, :index)
    relevance_score = fetch_value(result, :relevance_score)

    cond do
      not is_integer(index) ->
        {:error,
         ReqLLM.Error.API.Response.exception(
           reason: "Invalid rerank response format",
           response_body: result
         )}

      not is_number(relevance_score) ->
        {:error,
         ReqLLM.Error.API.Response.exception(
           reason: "Invalid rerank response format",
           response_body: result
         )}

      true ->
        global_index = index + offset

        case Enum.at(documents, global_index) do
          document when is_binary(document) ->
            {:ok,
             %{
               index: global_index,
               relevance_score: relevance_score * 1.0,
               document: document
             }}

          _ ->
            {:error,
             ReqLLM.Error.API.Response.exception(
               reason: "Invalid rerank response format",
               response_body: result
             )}
        end
    end
  end

  defp parse_result(result, _offset, _documents) do
    {:error,
     ReqLLM.Error.API.Response.exception(
       reason: "Invalid rerank response format",
       response_body: result
     )}
  end

  defp maybe_take_top_n(results, nil), do: results
  defp maybe_take_top_n(results, top_n), do: Enum.take(results, top_n)

  defp merge_ids(ids) do
    ids
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(", ")
    |> case do
      "" -> nil
      merged -> merged
    end
  end

  defp normalize_meta(nil), do: nil

  defp normalize_meta(meta) when is_map(meta) do
    %{}
    |> maybe_put(:billed_units, normalize_numeric_map(fetch_value(meta, :billed_units)))
    |> maybe_put(:tokens, normalize_numeric_map(fetch_value(meta, :tokens)))
    |> maybe_put(:cached_tokens, normalize_number(fetch_value(meta, :cached_tokens)))
    |> maybe_put(:warnings, normalize_warnings(fetch_value(meta, :warnings)))
    |> case do
      %{} = normalized when map_size(normalized) == 0 -> nil
      normalized -> normalized
    end
  end

  defp normalize_meta(_meta), do: nil

  defp normalize_numeric_map(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case normalize_number(value) do
        nil -> acc
        number -> Map.put(acc, normalize_key(key), number)
      end
    end)
    |> case do
      normalized when map_size(normalized) == 0 -> nil
      normalized -> normalized
    end
  end

  defp normalize_numeric_map(_), do: nil

  defp normalize_number(number) when is_integer(number), do: number
  defp normalize_number(number) when is_float(number), do: number
  defp normalize_number(_), do: nil

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key("images"), do: :images
  defp normalize_key("input_tokens"), do: :input_tokens
  defp normalize_key("image_tokens"), do: :image_tokens
  defp normalize_key("output_tokens"), do: :output_tokens
  defp normalize_key("search_units"), do: :search_units
  defp normalize_key("classifications"), do: :classifications
  defp normalize_key(other) when is_binary(other), do: other

  defp normalize_warnings(warnings) when is_list(warnings) do
    warnings
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> nil
      list -> list
    end
  end

  defp normalize_warnings(_), do: nil

  defp merge_meta(metas, batch_count, usages) do
    normalized_metas = Enum.reject(metas, &is_nil/1)

    %{}
    |> maybe_put(:billed_units, merge_numeric_field(normalized_metas, :billed_units))
    |> maybe_put(:tokens, merge_numeric_field(normalized_metas, :tokens))
    |> maybe_put(:cached_tokens, sum_scalar_field(normalized_metas, :cached_tokens))
    |> maybe_put(:warnings, merge_warnings(normalized_metas))
    |> Map.put(:batch_count, batch_count)
    |> Map.merge(merge_costs(usages))
  end

  defp merge_costs(usages) do
    Enum.reduce(usages, %{}, fn usage, acc ->
      acc
      |> maybe_sum_cost(usage, :input_cost)
      |> maybe_sum_cost(usage, :output_cost)
      |> maybe_sum_cost(usage, :reasoning_cost)
      |> maybe_sum_cost(usage, :total_cost)
    end)
  end

  defp maybe_sum_cost(acc, usage, field) when is_map(usage) do
    case fetch_value(usage, field) do
      value when is_number(value) -> Map.update(acc, field, value, &(&1 + value))
      _ -> acc
    end
  end

  defp maybe_sum_cost(acc, _usage, _field), do: acc

  defp merge_numeric_field(metas, field) do
    metas
    |> Enum.reduce(%{}, fn meta, acc ->
      meta
      |> Map.get(field, %{})
      |> Enum.reduce(acc, fn {key, value}, inner_acc ->
        Map.update(inner_acc, key, value, &(&1 + value))
      end)
    end)
    |> case do
      merged when map_size(merged) == 0 -> nil
      merged -> merged
    end
  end

  defp sum_scalar_field(metas, field) do
    metas
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      values -> Enum.sum(values)
    end
  end

  defp merge_warnings(metas) do
    metas
    |> Enum.flat_map(&Map.get(&1, :warnings, []))
    |> Enum.uniq()
    |> case do
      [] -> nil
      warnings -> warnings
    end
  end

  defp fetch_value(map, key) when is_map(map) do
    case map do
      %{^key => value} -> value
      _ -> Map.get(map, Atom.to_string(key))
    end
  end
end

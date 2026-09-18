defmodule ReqLLM.Evaluation do
  @moduledoc """
  Evaluates one text or JSON state against named questions.

  This is a model call, not a test run. Providers handle their own request and
  answer formats. An evaluation model does not need to support chat generation.
  """

  alias ReqLLM.Response

  @openrouter_jev_ids ["typesafe/jev-1.13", "~typesafe/jev-latest"]

  @keyword_options Zoi.array(Zoi.tuple({Zoi.atom(), Zoi.any()}))

  @options_schema Zoi.keyword(
                    [
                      api_key: Zoi.string(),
                      base_url: Zoi.string(),
                      receive_timeout: Zoi.integer() |> Zoi.positive(),
                      total_timeout:
                        Zoi.union([Zoi.integer() |> Zoi.positive(), Zoi.literal(:infinity)]),
                      max_retries: Zoi.integer() |> Zoi.min(0),
                      req_http_options: @keyword_options,
                      fixture: Zoi.union([Zoi.string(), Zoi.tuple({Zoi.atom(), Zoi.string()})]),
                      telemetry: Zoi.union([Zoi.map(Zoi.any(), Zoi.any()), @keyword_options])
                    ],
                    unrecognized_keys: :error
                  )

  @doc """
  Evaluates one state against a map of named questions.

      questions = %{
        department: %{
          type: :choice,
          instructions: "Which team should handle this?",
          criteria: %{billing: "Billing and refunds", support: "Other requests"}
        },
        urgent: %{type: :boolean, instructions: "Is this urgent?"}
      }

      {:ok, result} = ReqLLM.evaluate("typesafe:jev-latest", "Please refund me", questions)
      result.object["department"]["choice"]
      result.object["urgent"]["probability"]

  Choice and score answers may include probabilities and confidence. Providers
  may support more question types. The response stores named answers in `object`
  with string keys. `provider_meta.raw_response` keeps the original provider data.
  """
  @spec evaluate(ReqLLM.model_input(), String.t() | map() | list(), map(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def evaluate(model_spec, state, questions, opts \\ [])

  def evaluate(model_spec, state, questions, opts) when is_list(opts) do
    opts = ReqLLM.ModelInput.merge_tuple_defaults(model_spec, :evaluate, opts)

    with :ok <- validate_state(state),
         :ok <- validate_questions(questions),
         :ok <- validate_json(%{state: state, questions: questions}),
         {:ok, opts} <- validate_options(opts),
         {:ok, model} <- resolve_model(model_spec),
         :ok <- validate_support(model),
         {:ok, provider} <- ReqLLM.provider(model.provider),
         {:ok, request} <-
           provider.prepare_request(:evaluate, model, %{state: state, questions: questions}, opts),
         {:ok, response} <-
           ReqLLM.TimeoutBudget.request(request, ReqLLM.TimeoutBudget.deadline(opts)) do
      result(response)
    end
  end

  def evaluate(_model_spec, _state, _questions, opts) do
    {:error, invalid_parameter("opts must be a keyword list, got: #{inspect(opts)}")}
  end

  @doc """
  Lists model specs that `evaluate/4` can call with an installed adapter.

  This includes the confirmed OpenRouter Jev IDs when an older LLMDB release
  does not list them. Catalog evaluation metadata can also describe models for
  providers that ReqLLM does not yet support. Those models are excluded.
  """
  @spec models() :: [String.t()]
  def models do
    catalog_specs =
      LLMDB.candidates(require: [evaluate: true])
      |> Enum.filter(fn spec ->
        case LLMDB.Spec.resolve(spec) do
          {:ok, {_provider, _id, model}} -> callable?(model)
          _ -> false
        end
      end)
      |> Enum.map(fn {provider, id} -> "#{provider}:#{id}" end)

    fallback_specs =
      Enum.flat_map(@openrouter_jev_ids, fn id ->
        case confirmed_openrouter_jev(id) do
          {:ok, _model} -> ["openrouter:#{id}"]
          _ -> []
        end
      end)

    (catalog_specs ++ fallback_specs)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Same as `evaluate/4`, but raises on error.
  """
  @spec evaluate!(ReqLLM.model_input(), String.t() | map() | list(), map(), keyword()) ::
          Response.t() | no_return()
  def evaluate!(model_spec, state, questions, opts \\ []) do
    case evaluate(model_spec, state, questions, opts) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end

  @doc false
  def schema, do: @options_schema

  defp resolve_model(model_spec) when is_binary(model_spec) do
    case LLMDB.Spec.resolve(model_spec) do
      {:ok, {_provider, _id, model}} ->
        ReqLLM.model(model)

      _ ->
        case LLMDB.Spec.parse_spec(model_spec) do
          {:ok, {provider, id}} -> unavailable_model(provider, id)
          _ -> {:error, unknown_model(model_spec)}
        end
    end
  end

  defp resolve_model({provider, id, _opts}) when is_atom(provider) and is_binary(id) do
    resolve_model({provider, id})
  end

  defp resolve_model({provider, id} = spec) when is_atom(provider) and is_binary(id) do
    case LLMDB.Spec.resolve(spec) do
      {:ok, {_provider, _id, model}} -> ReqLLM.model(model)
      _ -> unavailable_model(provider, id)
    end
  end

  defp resolve_model(model_spec) do
    with {:ok, model} <- ReqLLM.model(model_spec) do
      case LLMDB.Spec.resolve({model.provider, model.id}) do
        {:ok, {_provider, _id, catalog_model}} ->
          ReqLLM.model(catalog_model)

        _ ->
          case base_catalog_model(model.provider, model.id) do
            {:ok, catalog_model} ->
              {:error, unavailable_catalog_error(catalog_model)}

            :error ->
              if explicit_inline_evaluation?(model_spec) do
                {:ok, model}
              else
                {:error, unknown_model("#{model.provider}:#{model.id}")}
              end
          end
      end
    end
  end

  defp unavailable_model(provider, id) do
    case base_catalog_model(provider, id) do
      {:ok, model} ->
        {:error, unavailable_catalog_error(model)}

      :error ->
        case confirmed_openrouter_jev(provider, id) do
          {:ok, model} -> {:ok, model}
          :error -> {:error, unknown_model("#{provider}:#{id}")}
        end
    end
  end

  defp confirmed_openrouter_jev(id), do: confirmed_openrouter_jev(:openrouter, id)

  defp confirmed_openrouter_jev(:openrouter, id) when id in @openrouter_jev_ids do
    case LLMDB.Spec.resolve({:openrouter, id}) do
      {:ok, _resolved} ->
        :error

      _ ->
        case base_catalog_model(:openrouter, id) do
          {:ok, _model} ->
            :error

          :error ->
            if fallback_visible?(id) do
              ReqLLM.model(%{
                provider: :openrouter,
                id: id,
                capabilities: %{chat: false, evaluate: true, streaming: %{text: false}},
                execution: %{
                  evaluate: %{
                    supported: true,
                    family: "openrouter_decisions",
                    wire_protocol: "openrouter_decisions",
                    base_url: "https://openrouter.ai",
                    path: "/api/alpha/decisions",
                    provider_model_id: id
                  }
                }
              })
            else
              :error
            end
        end
    end
  end

  defp confirmed_openrouter_jev(_, _), do: :error

  defp fallback_visible?(id) do
    case LLMDB.Catalog.snapshot() do
      %{filters: filters} when is_map(filters) ->
        LLMDB.Engine.apply_filters([%{provider: :openrouter, id: id}], filters) != []

      _ ->
        false
    end
  end

  defp base_catalog_model(provider, id) do
    LLMDB.Catalog.ensure_loaded!()

    case LLMDB.Catalog.snapshot() do
      %{base_models: models} when is_list(models) ->
        case Enum.find(models, &(&1.provider == provider and &1.id == id)) do
          nil -> :error
          model -> {:ok, model}
        end

      _ ->
        :error
    end
  end

  defp unavailable_catalog_error(model) do
    if model.catalog_only == true do
      invalid_parameter(
        "Catalog-only evaluation model #{LLMDB.Model.spec(model)} has no ReqLLM evaluation adapter"
      )
    else
      case validate_support(model) do
        :ok ->
          invalid_parameter(
            "Evaluation model #{LLMDB.Model.spec(model)} is unavailable under the current catalog filter"
          )

        {:error, error} ->
          error
      end
    end
  end

  defp explicit_inline_evaluation?(spec) when is_map(spec) do
    capabilities = field(spec, :capabilities)
    execution = field(field(spec, :execution), :evaluate)

    field(capabilities, :evaluate) == true and
      field(execution, :supported) == true and
      is_binary(field(execution, :family)) and
      is_binary(field(execution, :wire_protocol)) and
      is_binary(field(execution, :path)) and
      is_binary(field(execution, :provider_model_id))
  end

  defp explicit_inline_evaluation?(_), do: false

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_, _), do: nil

  defp validate_support(model) do
    cond do
      field(model.capabilities, :evaluate) != true ->
        {:error, invalid_parameter("#{LLMDB.Model.spec(model)} does not support evaluation")}

      callable?(model) ->
        :ok

      true ->
        {:error,
         invalid_parameter(
           "No evaluation adapter for #{LLMDB.Model.spec(model)} (provider #{inspect(model.provider)}, execution family #{inspect(field(field(model.execution, :evaluate), :family))})"
         )}
    end
  end

  defp callable?(model) do
    execution = field(model.execution, :evaluate)

    case model.provider do
      :typesafe ->
        contract?(execution, "typesafe_systemone", "/v1/systemone")

      :openrouter ->
        contract?(execution, "openrouter_decisions", "/api/alpha/decisions")

      _ ->
        false
    end
  end

  defp contract?(execution, family, path) do
    field(execution, :supported) == true and
      field(execution, :family) == family and
      field(execution, :wire_protocol) == family and
      field(execution, :path) == path and
      (is_binary(field(execution, :provider_model_id)) or family == "typesafe_systemone")
  end

  defp unknown_model(spec) do
    invalid_parameter(
      "Unknown evaluation model spec #{inspect(spec)}. Use a catalog spec from ReqLLM.evaluation_models/0 or a full inline model spec with evaluation capability and execution metadata"
    )
  end

  defp validate_state(state) when is_binary(state) or is_map(state) or is_list(state), do: :ok
  defp validate_state(_), do: {:error, invalid_parameter("state must be text or JSON data")}

  defp validate_questions(questions) when is_map(questions) and map_size(questions) > 0 do
    if Enum.all?(questions, fn {id, question} ->
         (is_atom(id) or is_binary(id)) and is_map(question)
       end) do
      :ok
    else
      {:error, invalid_parameter("questions must map names to question maps")}
    end
  end

  defp validate_questions(_),
    do: {:error, invalid_parameter("questions must be a non-empty map")}

  defp validate_json(value) do
    case Jason.encode(value) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, invalid_parameter("state and questions must be JSON data")}
    end
  end

  defp validate_options(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, invalid_parameter("opts must be a keyword list")}

      length(opts) != length(Enum.uniq_by(opts, &elem(&1, 0))) ->
        {:error, invalid_parameter("opts must not contain duplicate keys")}

      true ->
        case Zoi.parse(@options_schema, opts) do
          {:ok, valid_opts} -> {:ok, valid_opts}
          {:error, errors} -> {:error, invalid_parameter(format_zoi_errors(errors))}
        end
    end
  end

  defp format_zoi_errors(errors) do
    Enum.map_join(errors, ", ", fn %Zoi.Error{path: path, message: message} ->
      case path do
        [] -> message
        _ -> "#{Enum.map_join(path, ".", &to_string/1)}: #{message}"
      end
    end)
  end

  defp result(%Req.Response{status: status, body: %Response{} = body})
       when status in 200..299,
       do: {:ok, body}

  defp result(%Req.Response{status: status, body: body}) do
    {:error,
     ReqLLM.Error.API.Request.exception(
       reason: "Evaluation request failed",
       status: status,
       response_body: body
     )}
  end

  defp invalid_parameter(message),
    do: ReqLLM.Error.Invalid.Parameter.exception(parameter: message)
end

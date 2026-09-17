defmodule ReqLLM.Evaluation do
  @moduledoc """
  Evaluates one text or JSON state against named questions.

  This is a model call, not a test run. Providers handle their own request and
  answer formats. An evaluation model does not need to support chat generation.
  """

  alias ReqLLM.EvaluationResponse

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
      result.answers["department"]["choice"]
      result.answers["urgent"]["probability"]

  Choice and score answers may include probabilities and confidence. Providers
  may support more question types. Answers use string keys, and `raw` keeps the
  original provider data.
  """
  @spec evaluate(ReqLLM.model_input(), String.t() | map() | list(), map(), keyword()) ::
          {:ok, EvaluationResponse.t()} | {:error, term()}
  def evaluate(model_spec, state, questions, opts \\ [])

  def evaluate(model_spec, state, questions, opts) when is_list(opts) do
    opts = ReqLLM.ModelInput.merge_tuple_defaults(model_spec, :evaluate, opts)

    with :ok <- validate_state(state),
         :ok <- validate_questions(questions),
         :ok <- validate_json(%{state: state, questions: questions}),
         {:ok, opts} <- validate_options(opts),
         {:ok, model} <- ReqLLM.model(model_spec),
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
  Same as `evaluate/4`, but raises on error.
  """
  @spec evaluate!(ReqLLM.model_input(), String.t() | map() | list(), map(), keyword()) ::
          EvaluationResponse.t() | no_return()
  def evaluate!(model_spec, state, questions, opts \\ []) do
    case evaluate(model_spec, state, questions, opts) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end

  @doc false
  def schema, do: @options_schema

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

  defp result(%Req.Response{status: status, body: %EvaluationResponse{} = body})
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

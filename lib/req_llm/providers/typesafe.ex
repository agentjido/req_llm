defmodule ReqLLM.Providers.TypeSafe do
  @moduledoc """
  TypeSafe evaluation provider for Jev and later System One models.

  TypeSafe does not support chat, text generation, or arbitrary JSON schemas.
  """

  import ReqLLM.Provider.Utils, only: [ensure_parsed_body: 1]

  alias ReqLLM.EvaluationResponse

  use ReqLLM.Provider,
    id: :typesafe,
    default_base_url: "https://api.typesafe.ai",
    default_env_key: "TYPESAFE_API_KEY"

  @impl ReqLLM.Provider
  def prepare_request(:evaluate, model_spec, %{state: state, questions: questions}, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, api_key, _source} <- ReqLLM.Keys.get(model, opts) do
      timeout = Keyword.get(opts, :receive_timeout, 30_000)
      http_opts = Keyword.get(opts, :req_http_options, [])

      request =
        Req.new(
          [
            url: "/v1/systemone",
            method: :post,
            receive_timeout: timeout
          ] ++ ReqLLM.Provider.Defaults.merge_finch_options(http_opts, pool_timeout: timeout)
        )
        |> Req.Request.register_options([:operation, :model, :state, :questions])
        |> Req.Request.merge_options(
          operation: :evaluate,
          model: model.provider_model_id || model.id,
          state: state,
          questions: questions,
          base_url: Keyword.get(opts, :base_url, default_base_url())
        )
        |> attach(model, Keyword.put(opts, :api_key, api_key))

      {:ok, request}
    else
      {:error, message} when is_binary(message) ->
        {:error, ReqLLM.Error.Invalid.Parameter.exception(parameter: message)}

      {:error, _} = error ->
        error
    end
  end

  def prepare_request(operation, _model_spec, _input, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "operation #{inspect(operation)} is not supported by TypeSafe; use evaluate/4"
     )}
  end

  @impl ReqLLM.Provider
  def attach(request, model, opts) do
    api_key = ReqLLM.Keys.get!(model, opts)

    request
    |> Req.Request.put_header("authorization", "Bearer #{api_key}")
    |> ReqLLM.Step.Retry.attach(opts)
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.prepend_request_steps(llm_encode_body: &encode_body/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> Req.Request.append_response_steps(llm_decode_response: &decode_response/1)
    |> ReqLLM.Step.Telemetry.attach(model, opts)
    |> ReqLLM.Step.Fixture.maybe_attach(model, opts)
  end

  @impl ReqLLM.Provider
  def attach_stream(_model, _context, _opts, _finch_name) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "streaming is not supported by TypeSafe; use evaluate/4"
     )}
  end

  @impl ReqLLM.Provider
  def build_body(request) do
    %{
      model: request.options[:model],
      state: request.options[:state],
      questions: normalize_questions(request.options[:questions])
    }
  end

  @impl ReqLLM.Provider
  def encode_body(request) do
    ReqLLM.Provider.Defaults.encode_body_from_map(request, build_body(request))
  end

  @impl ReqLLM.Provider
  def decode_response({request, %Req.Response{status: status} = response})
      when status in 200..299 do
    body = ensure_parsed_body(response.body)

    case body do
      %{"model" => model, "answers" => answers, "usage" => usage}
      when is_binary(model) and is_map(answers) and is_map(usage) ->
        result = %EvaluationResponse{
          model: model,
          answers: normalize_answers(answers, request.options[:questions]),
          usage: ReqLLM.Usage.normalize(usage),
          raw: body
        }

        {request, %{response | body: result}}

      _ ->
        {request,
         ReqLLM.Error.API.Response.exception(
           reason: "Invalid TypeSafe evaluation response",
           status: status,
           response_body: body
         )}
    end
  end

  def decode_response({request, %Req.Response{status: status} = response}) do
    {request,
     ReqLLM.Error.API.Response.exception(
       reason: "TypeSafe evaluation failed",
       status: status,
       response_body: ensure_parsed_body(response.body)
     )}
  end

  @impl ReqLLM.Provider
  def extract_usage(%{"usage" => usage}, _model) when is_map(usage), do: {:ok, usage}
  def extract_usage(_, _), do: {:error, :no_usage_found}

  defp normalize_questions(questions) do
    Map.new(questions, fn {id, question} ->
      {to_string(id), normalize_question(question)}
    end)
  end

  defp normalize_question(question) do
    case question[:type] || question["type"] do
      type when type in [:boolean, "boolean"] ->
        question
        |> Map.drop([:type, "type"])
        |> Map.put("type", "noul")

      _ ->
        question
    end
  end

  defp normalize_answers(answers, questions) do
    boolean_ids =
      questions
      |> Enum.filter(fn {_id, question} ->
        (question[:type] || question["type"]) in [:boolean, "boolean"]
      end)
      |> Map.new(fn {id, _question} -> {to_string(id), true} end)

    Map.new(answers, fn {id, answer} ->
      if Map.has_key?(boolean_ids, id) and is_map(answer) and
           Map.has_key?(answer, "noul") do
        {id,
         answer
         |> Map.drop(["noul"])
         |> Map.put("type", "boolean")
         |> Map.put("probability", answer["noul"])}
      else
        {id, answer}
      end
    end)
  end
end

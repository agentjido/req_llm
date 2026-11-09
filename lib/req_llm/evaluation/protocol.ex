defmodule ReqLLM.Evaluation.Protocol do
  @moduledoc false

  alias ReqLLM.Evaluation.{Codec, Execution}
  alias ReqLLM.Providers.OpenAI.DecisionsAPI

  @spec prepare_request(LLMDB.Model.t(), map(), keyword(), map(), String.t()) ::
          {:ok, Req.Request.t()} | {:error, Exception.t()}
  def prepare_request(model, %{state: state, questions: questions}, opts, contract, api_key) do
    with {:ok, body, answer_contract} <- compile(contract, state, questions, opts) do
      timeout = Keyword.get(opts, :receive_timeout, 30_000)
      http_opts = Keyword.get(opts, :req_http_options, [])

      request =
        Req.new(
          [
            url: Execution.url(contract.base_url, contract.path),
            method: :post,
            receive_timeout: timeout,
            json: body
          ] ++ ReqLLM.Provider.Defaults.merge_finch_options(http_opts, pool_timeout: timeout)
        )
        |> Req.Request.register_options([:operation])
        |> Req.Request.merge_options(operation: :evaluate)
        |> Req.Request.put_header("authorization", "Bearer " <> api_key)
        |> Req.Request.put_private(:req_llm_evaluation_provider, model.provider)
        |> Req.Request.put_private(DecisionsAPI.request_private_key(), answer_contract)
        |> ReqLLM.Step.Retry.attach(opts)
        |> ReqLLM.Step.Error.attach()
        |> ReqLLM.Step.Usage.attach(model)
        |> Req.Request.append_response_steps(
          llm_decode_response: &decode_response(&1, contract.wire_protocol, model.provider)
        )
        |> ReqLLM.Step.Telemetry.attach(model, opts)
        |> ReqLLM.Step.Fixture.maybe_attach(model, opts)

      {:ok, request}
    end
  end

  defp compile(%{wire_protocol: "openai_decisions"} = contract, state, questions, opts) do
    provider_opts = opts[:provider_options] || []

    safety_identifier =
      if is_map(provider_opts),
        do: provider_opts[:safety_identifier] || provider_opts["safety_identifier"],
        else: Keyword.get(provider_opts, :safety_identifier)

    DecisionsAPI.compile_request(contract.provider_model_id, state, questions, safety_identifier)
  end

  defp compile(contract, state, questions, _opts) do
    {:ok,
     %{
       model: contract.provider_model_id,
       state: state,
       questions: Codec.normalize_questions(questions)
     }, nil}
  end

  defp decode_response(args, "openai_decisions", _provider),
    do: DecisionsAPI.decode_response(args)

  defp decode_response({request, response}, _protocol, provider) do
    body = ReqLLM.Provider.Utils.ensure_parsed_body(response.body)

    case response.status in 200..299 && Codec.decode_response(body, provider) do
      {:ok, result} ->
        {request, %{response | body: result}}

      _ ->
        {request,
         ReqLLM.Error.API.Response.exception(
           reason: "Invalid evaluation response from #{provider}",
           status: response.status,
           response_body: body
         )}
    end
  end
end

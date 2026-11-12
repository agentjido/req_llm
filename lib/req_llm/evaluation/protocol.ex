defmodule ReqLLM.Evaluation.Protocol do
  @moduledoc false

  alias ReqLLM.Evaluation.{Codec, Execution}
  alias ReqLLM.Providers.Google.DecisionsAPI, as: GoogleDecisionsAPI
  alias ReqLLM.Providers.OpenAI.DecisionsAPI

  @spec prepare_request(
          LLMDB.Model.t(),
          map(),
          keyword(),
          map(),
          String.t() | {String.t(), String.t()}
        ) ::
          {:ok, Req.Request.t()} | {:error, Exception.t()}
  def prepare_request(model, %{state: state, questions: questions}, opts, contract, credential) do
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
        |> put_auth_header(credential)
        |> Req.Request.put_private(:req_llm_evaluation_provider, model.provider)
        |> Req.Request.put_private(request_private_key(contract.wire_protocol), answer_contract)
        |> ReqLLM.Step.Retry.attach(opts)
        |> ReqLLM.Step.Error.attach()
        |> Req.Request.append_response_steps(
          llm_decode_response: &decode_response(&1, contract.wire_protocol, model.provider)
        )
        |> ReqLLM.Step.Usage.attach(model)
        |> ReqLLM.Step.Telemetry.attach(model, opts)
        |> ReqLLM.Step.Fixture.maybe_attach(model, opts)

      {:ok, request}
    end
  end

  defp put_auth_header(request, {header, value}),
    do: Req.Request.put_header(request, header, value)

  defp put_auth_header(request, api_key),
    do: Req.Request.put_header(request, "authorization", "Bearer " <> api_key)

  defp request_private_key("google_decisions"), do: GoogleDecisionsAPI.request_private_key()
  defp request_private_key(_protocol), do: DecisionsAPI.request_private_key()

  defp compile(%{wire_protocol: "google_decisions"} = contract, state, questions, _opts) do
    GoogleDecisionsAPI.compile_request(contract.provider_model_id, state, questions)
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

  defp decode_response(args, "google_decisions", _provider),
    do: GoogleDecisionsAPI.decode_response(args)

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

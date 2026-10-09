defmodule ReqLLM.Test.Billing.Samples do
  @moduledoc false

  alias ReqLLM.Test.Billing.{Cases, Reference}

  def all do
    Enum.map(Cases.all(), fn spec ->
      anthropic = :anthropic in spec.providers and spec.id != "basic_usage"
      model = if anthropic, do: "anthropic:claude-haiku-4-5-20251001", else: "openai:gpt-6-luna"
      sample(spec.id, model)
    end)
  end

  def selected?(sample) do
    ids = selected("REQ_LLM_BILLING_CASES")
    models = selected("REQ_LLM_BILLING_MODELS")
    provider = System.get_env("REQ_LLM_BILLING_PROVIDER")

    (ids == [] or sample.case_id in ids) and (models == [] or sample.model in models) and
      (provider in [nil, ""] or String.starts_with?(sample.model, provider <> ":"))
  end

  def sample(id, model) do
    anthropic = String.starts_with?(model, "anthropic:")
    usage = %{"input_tokens" => 100, "output_tokens" => 10}

    body =
      if anthropic,
        do: %{
          "id" => "synthetic_message",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "OK"}],
          "stop_reason" => "end_turn",
          "usage" => usage
        },
        else: %{
          "id" => "synthetic_response",
          "object" => "response",
          "status" => "completed",
          "service_tier" => "default",
          "output" => [],
          "usage" => usage
        }

    {body, expected} = specialize(id, body)

    url =
      if anthropic,
        do: "https://api.anthropic.com/v1/messages",
        else: "https://api.openai.com/v1/responses"

    url = if id == "compact_unknown", do: url <> "/compact", else: url
    %{case_id: id, model: model, body: body, request: %{"url" => url}, expected: expected}
  end

  def buffered(sample) do
    model = ReqLLM.model!(sample.model)
    opts = %{model: model.id, context: ReqLLM.Context.new([])}

    opts =
      if sample.case_id == "compact_unknown",
        do: Map.put(opts, :api_mod, ReqLLM.Providers.OpenAI.ResponsesAPI),
        else: opts

    pricing_context =
      if model.provider == :anthropic, do: %{api: "chat", inference_geo: "global"}, else: %{}

    request = %Req.Request{
      url: URI.parse(sample.request["url"]),
      options: opts,
      private: %{
        req_llm_model: model,
        req_llm_pricing_context: pricing_context
      }
    }

    {:ok, provider} = ReqLLM.provider(model.provider)

    {request, response} =
      provider.decode_response({request, %Req.Response{status: 200, body: sample.body}})

    {_request, response} = ReqLLM.Step.Usage.handle({request, response})
    response.body
  end

  def events(sample) do
    if String.starts_with?(sample.model, "anthropic:") do
      message = Map.put(sample.body, "usage", Map.put(sample.body["usage"], "output_tokens", 0))

      [
        %{"type" => "message_start", "message" => message},
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "end_turn"},
          "usage" => %{"output_tokens" => 10}
        },
        %{"type" => "message_stop"}
      ]
    else
      [%{"type" => "response.completed", "response" => sample.body}]
    end
  end

  def transcript(sample, streaming \\ false) do
    payload =
      if streaming,
        do: Enum.map_join(events(sample), &"data: #{Jason.encode!(&1)}\n\n"),
        else: Jason.encode!(sample.body)

    ReqLLM.Test.Transcript.new(
      provider: ReqLLM.model!(sample.model).provider,
      model_spec: sample.model,
      captured_at: DateTime.utc_now(),
      request: %{
        method: "POST",
        url: sample.request["url"],
        headers: [],
        canonical_json: %{"model" => ReqLLM.model!(sample.model).id}
      },
      response_meta: %{status: 200, headers: [], streaming: streaming},
      events: [{:status, 200}, {:headers, []}, {:data, payload}, {:done, :ok}]
    )
  end

  defp specialize(id, body) when id in ~w(cache_5m cache_1h mixed_cache_ttl) do
    {five, hour, expected} =
      case id do
        "cache_5m" -> {4000, 0, "0.005150"}
        "cache_1h" -> {0, 4000, "0.008150"}
        "mixed_cache_ttl" -> {4000, 6000, "0.017150"}
      end

    usage =
      body["usage"]
      |> Map.put("cache_creation_input_tokens", five + hour)
      |> Map.put("cache_creation", %{
        "ephemeral_5m_input_tokens" => five,
        "ephemeral_1h_input_tokens" => hour
      })

    {Map.put(body, "usage", usage), expected}
  end

  defp specialize("returned_service_tier", body),
    do: {Map.put(body, "service_tier", "flex"), "0.000008"}

  defp specialize("long_context", body),
    do: {put_in(body, ["usage", "input_tokens"], 275_000), "0.055008"}

  defp specialize("compact_unknown", body),
    do: {Map.put(body, "object", "response.compaction"), "unknown"}

  defp specialize("client_function", body) do
    call = %{
      "type" => "function_call",
      "id" => "fc_synthetic",
      "call_id" => "call_synthetic",
      "name" => "billing_echo",
      "arguments" => ~s({"value":"OK"}),
      "status" => "completed"
    }

    {Map.put(body, "output", [call]), "0.000015"}
  end

  defp specialize("hosted_web_search", body) do
    call = %{"type" => "web_search_call", "id" => "search_synthetic", "status" => "completed"}
    {Map.put(body, "output", [call]), "0.010015"}
  end

  defp specialize(_id, body), do: {body, "0.000015"}

  def reference(sample), do: Reference.calculate(sample.model, sample.body, sample.request)
  defp selected(key), do: (System.get_env(key) || "") |> String.split(",", trim: true)
end

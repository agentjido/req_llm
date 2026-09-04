defmodule ReqLLM.Providers.OpenAIAstraTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Providers.OpenAI

  @model_spec "openai:gpt-6-astra"
  @api_key "astra-request-test-key"

  test "catalog model uses Responses and supports the published reasoning efforts" do
    model = ReqLLM.model!(@model_spec)

    assert model.capabilities.reasoning.effort.values == ~w(low medium high xhigh max)

    for effort <- [:low, :medium, :high, :xhigh, :max] do
      assert {:ok, request} =
               OpenAI.prepare_request(:chat, model, "Hello",
                 api_key: @api_key,
                 reasoning_effort: effort,
                 max_tokens: 2048
               )

      body = request |> OpenAI.encode_body() |> Map.fetch!(:body) |> Jason.decode!()

      assert request.private.req_llm_request_plan.surface == :openai_responses
      assert request.url.path == "/responses"
      assert body["model"] == "gpt-6-astra"
      assert body["max_output_tokens"] == 2048
      assert body["reasoning"] == %{"effort" => Atom.to_string(effort)}
      assert body["include"] == ["reasoning.encrypted_content"]
    end
  end

  test "full model specs without catalog metadata use Responses" do
    model = ReqLLM.model!(%{provider: :openai, id: "gpt-6-astra"})

    assert {:ok, request} =
             OpenAI.prepare_request(:chat, model, "Hello", api_key: @api_key)

    assert request.url.path == "/responses"
    assert request.options[:api_mod] == OpenAI.ResponsesAPI
  end

  test "option translation removes sampling parameters" do
    {opts, warnings} =
      OpenAI.translate_options(:chat, ReqLLM.model!(@model_spec),
        max_tokens: 2048,
        reasoning_effort: :low,
        temperature: 0.9,
        top_p: 0.8,
        top_k: 40
      )

    assert opts[:max_completion_tokens] == 2048
    assert opts[:reasoning_effort] == "low"
    refute Keyword.has_key?(opts, :temperature)
    refute Keyword.has_key?(opts, :top_p)
    refute Keyword.has_key?(opts, :top_k)
    assert Enum.any?(warnings, &String.contains?(&1, "sampling"))
  end

  test "HTTP, SSE, and WebSocket requests preserve the same Responses body" do
    model = ReqLLM.model!(@model_spec)
    context = Context.new([Context.user("Hello")])

    opts = [
      api_key: @api_key,
      reasoning_effort: :low,
      max_tokens: 2048,
      provider_options: [store: false, prompt_cache_options: %{ttl: "30m"}]
    ]

    assert {:ok, request} = OpenAI.prepare_request(:chat, model, context, opts)
    body = request |> OpenAI.encode_body() |> Map.fetch!(:body) |> Jason.decode!()

    assert {:ok, stream_request} = OpenAI.attach_stream(model, context, opts, ReqLLM.Finch)
    stream_body = Jason.decode!(stream_request.body)

    websocket_opts =
      Keyword.update!(
        opts,
        :provider_options,
        &Keyword.put(&1, :openai_stream_transport, :websocket)
      )

    assert {:ok, websocket} = OpenAI.attach_websocket_stream(model, context, websocket_opts)
    assert [initial_message] = websocket.initial_messages

    assert %{"type" => "response.create", "model" => "gpt-6-astra"} =
             websocket_event = Jason.decode!(initial_message)

    refute Map.has_key?(websocket_event, "response")
    refute Map.has_key?(websocket_event, "stream")
    refute Map.has_key?(websocket_event, "background")

    assert stream_request.path == "/v1/responses"
    assert websocket.url == "wss://api.openai.com/v1/responses"
    assert stream_body["stream"] == true
    assert body["stream"] == false
    assert Map.delete(stream_body, "stream") == Map.delete(body, "stream")
    assert websocket.request_plan.transport == :websocket
    assert Map.delete(websocket_event, "type") == Map.delete(body, "stream")
    assert body["store"] == false
    assert body["prompt_cache_options"] == %{"ttl" => "30m"}
    assert body["include"] == ["reasoning.encrypted_content"]
    refute Map.has_key?(body, "temperature")
    refute Map.has_key?(body, "top_p")
  end
end

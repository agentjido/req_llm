defmodule ReqLLM.Providers.OpenAIMultiAgentTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Providers.OpenAI}

  test "HTTP, SSE, and WebSocket use the beta header and same configuration" do
    model = ReqLLM.model!(%{provider: :openai, id: "gpt-6.1-sol"})
    context = Context.new([Context.user("Review the proposals")])

    opts = [
      api_key: "test-key",
      provider_options: [multi_agent: %{enabled: true, max_concurrent_subagents: 3}]
    ]

    assert {:ok, request} = OpenAI.prepare_request(:chat, model, context, opts)
    request = OpenAI.encode_body(request)
    assert Req.Request.get_header(request, "openai-beta") == ["responses_multi_agent=v1"]

    assert Jason.decode!(request.body)["multi_agent"] == %{
             "enabled" => true,
             "max_concurrent_subagents" => 3
           }

    assert {:ok, stream} = OpenAI.attach_stream(model, context, opts, ReqLLM.Finch)
    assert {"OpenAI-Beta", "responses_multi_agent=v1"} in stream.headers
    assert Jason.decode!(stream.body)["multi_agent"] == Jason.decode!(request.body)["multi_agent"]
    assert {:ok, socket} = OpenAI.attach_websocket_stream(model, context, opts)
    assert {"OpenAI-Beta", "responses_multi_agent=v1"} in socket.headers

    assert Jason.decode!(hd(socket.initial_messages))["multi_agent"] ==
             Jason.decode!(request.body)["multi_agent"]
  end

  test "disabled multi-agent does not enable the beta" do
    assert OpenAI.MultiAgent.headers([multi_agent: %{enabled: false}], "gpt-6-astra") == []
  end

  test "invalid configurations fail before an API request" do
    model = ReqLLM.model!(%{provider: :openai, id: "gpt-6.1-sol"})

    for config <- [
          %{enabled: true, max_concurrent_subagents: 0},
          %{enabled: "true"},
          %{enabled: true, unknown: 1}
        ] do
      assert {:error, _} =
               OpenAI.prepare_request(:chat, model, "Hello",
                 api_key: "test-key",
                 provider_options: [multi_agent: config]
               )
    end

    astra = ReqLLM.model!(%{provider: :openai, id: "gpt-6-astra"})

    assert {:error, _} =
             OpenAI.prepare_request(:chat, astra, "Hello",
               api_key: "test-key",
               provider_options: [multi_agent: %{enabled: true}]
             )

    assert {:error, _} =
             OpenAI.prepare_request(:chat, model, "Hello",
               api_key: "test-key",
               provider_options: [multi_agent: %{enabled: true}, reasoning_summary: :auto]
             )
  end
end

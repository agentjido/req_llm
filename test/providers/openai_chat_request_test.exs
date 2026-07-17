defmodule ReqLLM.Providers.OpenAI.ChatRequestTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Providers.OpenAI.ChatAPI
  alias ReqLLM.Providers.OpenAI.ChatAPI.Request
  alias ReqLLM.Tool

  test "builds the exact Chat Completions envelope for canonical options" do
    tool =
      Tool.new!(
        name: "lookup",
        description: "Look up a value",
        parameter_schema: [query: [type: :string, required: true]],
        callback: fn _arguments -> {:ok, "found"} end,
        strict: true
      )

    context = Context.new([Context.user("Find it")])

    body =
      Request.build_body(
        context,
        "gpt-4-turbo",
        [
          tools: [tool],
          tool_choice: %{type: "tool", name: "lookup"},
          max_tokens: 64,
          stream: true,
          reasoning_effort: "low",
          service_tier: "flex",
          provider_options: [
            openai_parallel_tool_calls: true,
            openai_logprobs: true,
            openai_top_logprobs: 3,
            verbosity: :high,
            modalities: ["text"]
          ]
        ],
        :chat
      )

    assert body.model == "gpt-4-turbo"
    assert body.messages == [%{role: "user", content: "Find it"}]
    assert body.max_tokens == 64
    assert body.stream == true
    assert body.stream_options == %{include_usage: true}
    assert body.reasoning_effort == "low"
    assert body.service_tier == "flex"
    assert body.parallel_tool_calls == true
    assert body.logprobs == true
    assert body.top_logprobs == 3
    assert body.verbosity == "high"
    assert body.modalities == ["text"]

    assert body.tool_choice == %{type: "function", function: %{name: "lookup"}}
    assert [encoded_tool] = body.tools
    assert encoded_tool["function"]["strict"] == true
    assert encoded_tool["function"]["parameters"]["required"] == ["query"]
    assert encoded_tool["function"]["parameters"]["additionalProperties"] == false
  end

  test "Req and Finch paths use the same streaming envelope" do
    model = %LLMDB.Model{
      provider: :openai,
      id: "gpt-4-turbo",
      extra: %{wire: %{protocol: "openai_chat"}}
    }

    context = Context.new([Context.system("Be concise"), Context.user("Hello")])

    opts = [
      api_key: "test-key",
      max_tokens: 32,
      temperature: 0.2,
      provider_options: [openai_parallel_tool_calls: false, verbosity: "low"]
    ]

    req =
      Req.new(method: :post, url: ChatAPI.path())
      |> Map.put(
        :options,
        Map.new([model: model.id, context: context, operation: :chat, stream: true] ++ opts)
      )

    req_body = req |> ChatAPI.encode_body() |> ReqLLM.Test.Helpers.json_body()
    assert {:ok, finch_request} = ChatAPI.attach_stream(model, context, opts, ReqLLM.Finch)
    finch_body = ReqLLM.Test.Helpers.json_body(finch_request)

    assert req_body == finch_body
  end
end

defmodule ReqLLM.Providers.OpenAI.ChatRequestTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart
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

  test "encodes explicit prompt cache controls" do
    breakpoint = %{mode: "explicit"}

    context =
      Context.new([
        Context.system([
          ContentPart.text("Stable instructions", %{prompt_cache_breakpoint: breakpoint})
        ]),
        Context.user("Dynamic request")
      ])

    body =
      Request.build_body(
        context,
        "gpt-5.6",
        [
          provider_options: [
            prompt_cache_key: "tenant:acme:instructions-v1",
            prompt_cache_options: %{mode: "explicit", ttl: "30m"}
          ]
        ],
        :chat
      )

    assert body.prompt_cache_key == "tenant:acme:instructions-v1"
    assert body.prompt_cache_options == %{mode: "explicit", ttl: "30m"}

    [system_message, _user_message] = body.messages
    assert [system_block] = system_message.content
    assert system_block.prompt_cache_breakpoint == breakpoint
  end

  describe "web_search_options" do
    setup do
      %{context: Context.new([Context.user("Find one recent announcement")])}
    end

    # `%{}` is the documented way to request OpenAI's web-search defaults, so it
    # must survive into the body rather than being treated as "unset".
    test "forwards an empty map to enable web search with provider defaults", %{context: context} do
      assert %{web_search_options: %{}} = search_body(context, web_search_options: %{})
    end

    test "forwards search configuration verbatim", %{context: context} do
      body = search_body(context, web_search_options: %{"search_context_size" => "high"})
      assert body.web_search_options == %{"search_context_size" => "high"}
    end

    test "accepts the option nested under provider_options", %{context: context} do
      body =
        search_body(context, provider_options: [web_search_options: %{"user_location" => nil}])

      assert body.web_search_options == %{"user_location" => nil}
    end

    test "normalizes a keyword list into a map so it encodes as a JSON object", %{
      context: context
    } do
      body = search_body(context, web_search_options: [search_context_size: "low"])
      assert body.web_search_options == %{search_context_size: "low"}
      assert Jason.encode!(body.web_search_options) == ~s({"search_context_size":"low"})
    end

    test "is omitted entirely when not requested", %{context: context} do
      refute Map.has_key?(search_body(context, []), :web_search_options)
    end

    test "is accepted by the provider option schema" do
      assert :web_search_options in ReqLLM.Providers.OpenAI.supported_provider_options()

      for value <- [
            %{},
            %{"search_context_size" => "medium"},
            %{"user_location" => %{"type" => "approximate", "country" => "US"}},
            %{search_context_size: "low"},
            [search_context_size: "low"]
          ] do
        assert {:ok, _opts} =
                 NimbleOptions.validate(
                   [web_search_options: value],
                   ReqLLM.Providers.OpenAI.provider_schema()
                 )
      end
    end

    defp search_body(context, opts) do
      Request.build_body(context, "gpt-4o-mini-search-preview", opts, :chat)
    end
  end
end

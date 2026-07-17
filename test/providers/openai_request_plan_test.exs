defmodule ReqLLM.Providers.OpenAIRequestPlanTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.OpenAI

  @api_key "request-plan-test-key"

  describe "planned request routing" do
    test "records the selected surface for non-streaming Chat and Responses requests" do
      context = context_fixture()

      cases = [
        {chat_model(), :openai_chat_completions, OpenAI.ChatAPI, "/chat/completions"},
        {ReqLLM.model!("openai:gpt-4o-mini"), :openai_responses, OpenAI.ResponsesAPI,
         "/responses"}
      ]

      for {model, surface, api_module, path} <- cases do
        assert {:ok, request} =
                 OpenAI.prepare_request(:chat, model, context, api_key: @api_key)

        assert request.url.path == path
        assert request.options[:api_mod] == api_module

        assert %{
                 operation: :chat,
                 provider: :openai,
                 surface: ^surface,
                 transport: :req,
                 provider_module: OpenAI,
                 api_module: ^api_module,
                 warnings: []
               } = request.private[:req_llm_request_plan]

        refute inspect(request.private[:req_llm_request_plan]) =~ @api_key
      end
    end

    test "records object planning without changing the existing Responses request" do
      model = ReqLLM.model!("openai:gpt-4o-mini")
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string, required: true])

      assert {:ok, request} =
               OpenAI.prepare_request(:object, model, "Return a name",
                 api_key: @api_key,
                 compiled_schema: schema
               )

      assert request.url.path == "/responses"
      assert request.options[:api_mod] == OpenAI.ResponsesAPI

      assert %{
               operation: :object,
               surface: :openai_responses,
               transport: :req,
               api_module: OpenAI.ResponsesAPI
             } = request.private[:req_llm_request_plan]
    end

    test "records the selected surface for Finch Chat and Responses streams" do
      context = context_fixture()

      cases = [
        {chat_model(), :openai_chat_completions, OpenAI.ChatAPI, "/v1/chat/completions"},
        {ReqLLM.model!("openai:gpt-4o-mini"), :openai_responses, OpenAI.ResponsesAPI,
         "/v1/responses"}
      ]

      for {model, surface, api_module, path} <- cases do
        assert {:ok, request} =
                 OpenAI.attach_stream(model, context, [api_key: @api_key], ReqLLM.Finch)

        assert request.path == path

        assert %{
                 operation: :chat,
                 provider: :openai,
                 surface: ^surface,
                 transport: :finch,
                 provider_module: OpenAI,
                 api_module: ^api_module,
                 warnings: []
               } = request.private[:req_llm_request_plan]

        refute inspect(request.private[:req_llm_request_plan]) =~ @api_key
      end
    end

    test "records the planned Responses WebSocket surface" do
      model = ReqLLM.model!("openai:gpt-4o-mini")

      assert {:ok, config} =
               OpenAI.attach_websocket_stream(model, context_fixture(),
                 api_key: @api_key,
                 base_url: "http://localhost:4010/v1",
                 provider_options: [openai_stream_transport: :websocket]
               )

      assert config.url == "ws://localhost:4010/v1/responses"

      assert %{
               operation: :chat,
               provider: :openai,
               surface: :openai_responses,
               transport: :websocket,
               provider_module: OpenAI,
               api_module: OpenAI.ResponsesAPI,
               warnings: []
             } = config.request_plan

      refute inspect(config.request_plan) =~ @api_key
    end

    test "retains planning warnings for inferred Chat routing" do
      assert {:ok, request} =
               OpenAI.prepare_request(:chat, ReqLLM.model!("openai:chat-latest"), "Hello",
                 api_key: @api_key
               )

      assert request.url.path == "/chat/completions"

      assert request.private[:req_llm_request_plan].warnings == [
               "Defaulted to OpenAI Chat Completions because model wire metadata is absent"
             ]
    end
  end

  describe "planning failures" do
    test "rejects invalid OpenAI wire metadata before request construction" do
      model =
        ReqLLM.model!(%{
          provider: :openai,
          id: "invalid-wire-model",
          extra: %{wire: %{protocol: "unsupported_wire"}}
        })

      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = error} =
               OpenAI.prepare_request(:chat, model, "Hello", api_key: @api_key)

      assert Exception.message(error) =~ "wire protocol \"unsupported_wire\" is invalid"
    end

    test "keeps the existing WebSocket request error for Chat models" do
      assert {:error, %ReqLLM.Error.API.Request{} = error} =
               OpenAI.attach_websocket_stream(chat_model(), context_fixture(),
                 api_key: @api_key,
                 provider_options: [openai_stream_transport: :websocket]
               )

      assert Exception.message(error) =~
               "OpenAI WebSocket mode is only supported for Responses models"

      assert Exception.message(error) =~ "routes to ReqLLM.Providers.OpenAI.ChatAPI"
    end
  end

  defp chat_model do
    ReqLLM.model!(%{
      provider: :openai,
      id: "request-plan-chat-model",
      limits: %{output: 1024},
      extra: %{wire: %{protocol: "openai_chat"}}
    })
  end

  defp context_fixture do
    ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
  end
end

defmodule ReqLLM.Providers.AnthropicRequestPlanTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Anthropic

  @api_key "anthropic-request-plan-test-key"

  describe "planned request routing" do
    test "records Anthropic Messages for non-streaming chat requests" do
      assert {:ok, request} =
               Anthropic.prepare_request(:chat, model(), "Hello",
                 api_key: @api_key,
                 max_tokens: 64
               )

      assert request.url.path == "/v1/messages"

      assert %{
               operation: :chat,
               provider: :anthropic,
               surface: :anthropic_messages,
               transport: :req,
               provider_module: Anthropic,
               api_module: Anthropic,
               warnings: []
             } = request.private[:req_llm_request_plan]

      refute inspect(request.private[:req_llm_request_plan]) =~ @api_key

      body = request |> Anthropic.encode_body() |> ReqLLM.Test.Helpers.json_body()

      assert body["model"] == "claude-sonnet-4-5-20250929"
      assert body["max_tokens"] == 64
      assert body["messages"] == [%{"content" => "Hello", "role" => "user"}]
    end

    test "records object planning without changing the Messages request" do
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string, required: true])

      assert {:ok, request} =
               Anthropic.prepare_request(:object, model(), "Return a name",
                 api_key: @api_key,
                 compiled_schema: schema
               )

      assert request.url.path == "/v1/messages"

      assert %{
               operation: :object,
               surface: :anthropic_messages,
               transport: :req,
               api_module: Anthropic
             } = request.private[:req_llm_request_plan]

      body = request |> Anthropic.encode_body() |> ReqLLM.Test.Helpers.json_body()

      assert body["model"] == "claude-sonnet-4-5-20250929"
      assert body["output_format"]["type"] == "json_schema"
    end

    test "records Anthropic Messages for Finch streams" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      assert {:ok, request} =
               Anthropic.attach_stream(model(), context, [api_key: @api_key, max_tokens: 64], nil)

      assert request.path == "/v1/messages"

      assert %{
               operation: :chat,
               provider: :anthropic,
               surface: :anthropic_messages,
               transport: :finch,
               provider_module: Anthropic,
               api_module: Anthropic,
               warnings: []
             } = request.private[:req_llm_request_plan]

      refute inspect(request.private[:req_llm_request_plan]) =~ @api_key

      body = Jason.decode!(request.body)

      assert body["model"] == "claude-sonnet-4-5-20250929"
      assert body["max_tokens"] == 64
      assert body["stream"]
    end
  end

  describe "planning failures" do
    test "preserves the provider mismatch error for prepared requests" do
      openai_model = ReqLLM.model!("openai:gpt-4o-mini")

      assert_raise ReqLLM.Error.Invalid.Provider, fn ->
        Anthropic.prepare_request(:chat, openai_model, "Hello", api_key: @api_key)
      end
    end

    test "rejects invalid Anthropic wire metadata before request construction" do
      invalid_model =
        ReqLLM.model!(%{
          provider: :anthropic,
          id: "invalid-wire-model",
          extra: %{wire: %{protocol: "openai_chat"}}
        })

      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = error} =
               Anthropic.prepare_request(:chat, invalid_model, "Hello", api_key: @api_key)

      assert Exception.message(error) =~ "wire protocol \"openai_chat\" is invalid"
    end

    test "rejects invalid Anthropic wire metadata before stream construction" do
      invalid_model =
        ReqLLM.model!(%{
          provider: :anthropic,
          id: "invalid-wire-stream-model",
          extra: %{wire: %{protocol: "openai_responses"}}
        })

      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = error} =
               Anthropic.attach_stream(invalid_model, context, [api_key: @api_key], nil)

      assert Exception.message(error) =~ "wire protocol \"openai_responses\" is invalid"
    end
  end

  defp model do
    ReqLLM.model!("anthropic:claude-sonnet-4-5-20250929")
  end
end

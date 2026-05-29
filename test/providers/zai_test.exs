defmodule ReqLLM.Providers.ZaiTest do
  @moduledoc """
  Provider-level tests for Z.AI implementation.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Zai

  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.Zai
  alias ReqLLM.Providers.ZaiCoder

  describe "request preparation" do
    test "zai_coder uses the coding endpoint instead of registry metadata" do
      {:ok, request} =
        ZaiCoder.prepare_request(:chat, "zai_coder:glm-4.5-flash", "Hello", api_key: "test")

      assert request.options[:base_url] == "https://api.z.ai/api/coding/paas/v4"
    end

    test "zai_coder preserves explicit base_url overrides" do
      {:ok, request} =
        ZaiCoder.prepare_request(:chat, "zai_coder:glm-4.5-flash", "Hello",
          api_key: "test",
          base_url: "https://proxy.example.com/v1"
        )

      assert request.options[:base_url] == "https://proxy.example.com/v1"
    end
  end

  describe "encode_body/1" do
    test "drops assistant thinking parts when encoding history" do
      {:ok, model} = ReqLLM.model("zai:glm-4.5")

      context =
        Context.new([
          Context.user("Hi"),
          Context.assistant([ContentPart.thinking("internal"), ContentPart.text("hello")]),
          Context.user("What did you say?")
        ])

      request = %Req.Request{options: [context: context, model: model.model, stream: false]}

      encoded_request = Zai.encode_body(request)
      decoded = ReqLLM.Test.Helpers.json_body(encoded_request)

      [_user_msg, assistant_msg, _followup_msg] = decoded["messages"]

      assert assistant_msg["role"] == "assistant"
      assert assistant_msg["content"] == "hello"
    end

    test "handles map content parts with string keys" do
      {:ok, model} = ReqLLM.model("zai:glm-4.5")

      context =
        Context.new([
          Context.assistant([
            %{"type" => "thinking", "thinking" => "internal"},
            %{"type" => "text", "text" => "hello"}
          ]),
          Context.user("repeat")
        ])

      request = %Req.Request{options: [context: context, model: model.model, stream: false]}

      encoded_request = Zai.encode_body(request)
      decoded = ReqLLM.Test.Helpers.json_body(encoded_request)

      [assistant_msg, user_msg] = decoded["messages"]

      assert assistant_msg["content"] == "hello"
      assert user_msg["content"] == "repeat"
    end
  end
end

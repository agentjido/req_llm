defmodule ReqLLM.Providers.OpenAICompatibleTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.OpenAICompatible

  defp model(attrs \\ %{}) do
    defaults = %{
      provider: :togetherai,
      id: "community-chat",
      capabilities: %{chat: true, streaming: %{text: true}},
      execution: %{
        text: %{
          supported: true,
          family: "openai_chat_compatible",
          wire_protocol: "openai_chat",
          path: "/chat/completions"
        },
        object: %{
          supported: true,
          family: "openai_chat_compatible",
          wire_protocol: "openai_chat",
          path: "/chat/completions"
        }
      }
    }

    ReqLLM.model!(Map.merge(defaults, attrs))
  end

  test "selects the shared adapter and keeps the catalog provider identity" do
    community_model = model()

    assert {:ok, OpenAICompatible} = ReqLLM.provider_for(community_model, :chat)
    assert {:ok, OpenAICompatible} = ReqLLM.provider_for(community_model, :object)
    assert {:ok, plan} = ReqLLM.RequestPlan.build(community_model, :chat)
    assert plan.provider == :togetherai
    assert plan.provider_module == OpenAICompatible
    assert plan.surface == :openai_chat_completions
    assert {:ok, diagnostic} = ReqLLM.plan(community_model, :chat)
    assert diagnostic.route == %{method: :post, path: "/chat/completions"}
    assert ReqLLM.Keys.env_var_name(:togetherai) == "TOGETHER_API_KEY"
  end

  test "keeps a dedicated provider module in control" do
    openrouter_model = %{model() | provider: :openrouter}

    assert {:ok, ReqLLM.Providers.OpenRouter} = ReqLLM.provider_for(openrouter_model, :chat)
  end

  test "uses the provider URL, model ID, and bearer key for a generated response" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/chat/completions"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer community-key"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["model"] == "community-chat"

      Req.Test.json(conn, %{
        "id" => "chatcmpl-community",
        "model" => "community-chat",
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "Hello"}}],
        "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 1, "total_tokens" => 3}
      })
    end)

    assert {:ok, response} =
             ReqLLM.generate_text(model(), "Hi",
               api_key: "community-key",
               req_http_options: [plug: {Req.Test, __MODULE__}]
             )

    assert ReqLLM.Response.text(response) == "Hello"
  end

  test "builds a Finch streaming request from the same catalog metadata" do
    context = ReqLLM.Context.new([ReqLLM.Context.user("Hi")])

    assert {:ok, request} =
             OpenAICompatible.attach_stream(
               model(),
               context,
               [api_key: "community-key"],
               ReqLLM.Finch
             )

    assert request.host == "api.together.xyz"
    assert request.path == "/v1/chat/completions"
    assert {"Authorization", "Bearer community-key"} in request.headers
    assert Jason.decode!(request.body)["stream"] == true
  end

  test "uses the shared adapter for structured output" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/chat/completions"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["tool_choice"] != nil

      Req.Test.json(conn, %{
        "id" => "chatcmpl-object",
        "model" => "community-chat",
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "id" => "call-object",
                  "type" => "function",
                  "function" => %{
                    "name" => "structured_output",
                    "arguments" => ~s({"name":"Ada"})
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 3, "total_tokens" => 5}
      })
    end)

    assert {:ok, response} =
             ReqLLM.generate_object(
               model(),
               "Return a person",
               [name: [type: :string, required: true]],
               api_key: "community-key",
               req_http_options: [plug: {Req.Test, __MODULE__}]
             )

    assert response.object == %{"name" => "Ada"}
  end

  test "rejects operations without an explicit compatible execution contract" do
    community_model = model(%{execution: %{text: %{supported: false}}})

    assert {:error, error} = ReqLLM.provider_for(community_model, :chat)
    assert Exception.message(error) =~ "does not declare OpenAI Chat Completions compatibility"
  end

  test "rejects catalog-only models" do
    community_model = model(%{catalog_only: true})

    assert {:error, error} = ReqLLM.provider_for(community_model, :chat)
    assert Exception.message(error) =~ "catalog entry is not executable"
  end
end

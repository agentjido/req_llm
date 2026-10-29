defmodule ReqLLM.Providers.VLLMTest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.VLLM, async: true

  alias ReqLLM.Providers.VLLM

  defp vllm_model(model_id, capabilities) do
    %LLMDB.Model{
      id: "vllm:#{model_id}",
      model: model_id,
      provider: :vllm,
      capabilities: capabilities
    }
  end

  test "prepares embedding requests with dimensions" do
    model = vllm_model("embedding-model", %{embeddings: true})

    assert {:ok, request} =
             VLLM.prepare_request(:embedding, model, "Follow the white rabbit.", dimensions: 32)

    assert request.url.path == "/embeddings"
    assert request.method == :post
    assert VLLM.build_body(request).dimensions == 32
  end

  test "encodes tools for OpenAI-compatible servers" do
    model = vllm_model("test-model", %{chat: true, tools: %{enabled: true}})

    tool =
      ReqLLM.Tool.new!(
        name: "get_weather",
        description: "Get the weather",
        parameter_schema: [location: [type: :string, required: true, doc: "City name"]],
        callback: fn _ -> {:ok, "sunny"} end
      )

    request = %Req.Request{
      options: [
        context: context_fixture(),
        model: model.model,
        stream: false,
        tools: [tool]
      ]
    }

    body = request |> VLLM.encode_body() |> ReqLLM.Test.Helpers.json_body()

    assert [%{"function" => %{"name" => "get_weather"}}] = body["tools"]
  end
end

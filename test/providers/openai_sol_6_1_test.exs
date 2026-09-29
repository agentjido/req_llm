defmodule ReqLLM.Providers.OpenAISol61Test do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.OpenAI

  test "explicit Sol 6.1 model specs use Responses and translate reasoning options" do
    model = ReqLLM.model!(%{provider: :openai, id: "gpt-6.1-sol"})

    assert {:ok, request} =
             OpenAI.prepare_request(:chat, model, "Hello",
               api_key: "test-key",
               reasoning_effort: :low,
               max_tokens: 100
             )

    body = request |> OpenAI.encode_body() |> Map.fetch!(:body) |> Jason.decode!()
    assert request.url.path == "/responses"
    assert body["max_output_tokens"] == 100
    assert body["reasoning"]["effort"] == "low"
    refute Map.has_key?(body, "temperature")
  end

  test "Sol 6.1 rejects reasoning efforts that Sol 6 supports" do
    model = ReqLLM.model!(%{provider: :openai, id: "gpt-6.1-sol"})

    for effort <- [:none, :minimal] do
      assert {:error, _} =
               OpenAI.prepare_request(:chat, model, "Hello",
                 api_key: "test-key",
                 reasoning_effort: effort
               )
    end
  end

  test "Astra-only features remain restricted" do
    assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
      OpenAI.Astra.require_astra!("gpt-6.1-sol", "Async tools")
    end
  end
end

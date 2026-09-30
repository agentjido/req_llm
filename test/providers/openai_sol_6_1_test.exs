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

  test "GPT-6 models encode async tools and reasoning configuration updates" do
    for id <- ["gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna"] do
      model = ReqLLM.model!(%{provider: :openai, id: id})
      effort = if id == "gpt-6.1-sol", do: :low, else: :none

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user("Review", metadata: %{openai_reasoning_effort: effort})
        ])

      assert {:ok, request} =
               OpenAI.prepare_request(:chat, model, context,
                 api_key: "test-key",
                 tools: [%{type: "function", name: "lookup", async: true}]
               )

      body = request |> OpenAI.encode_body() |> Map.fetch!(:body) |> Jason.decode!()
      assert [%{"async" => true}] = body["tools"]

      assert [%{"type" => "configuration_update", "reasoning" => %{"effort" => encoded}} | _] =
               body["input"]

      assert encoded == to_string(effort)
      assert is_nil(OpenAI.Astra.require_gpt6!(id, "Steering"))
    end

    assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
      OpenAI.Astra.require_gpt6!("gpt-5.6-sol", "Steering")
    end
  end

  test "Sol and Luna retain sampling only when reasoning is none" do
    for id <- ["gpt-6-sol", "gpt-6-luna"], effort <- [:none, :low] do
      model = ReqLLM.model!(%{provider: :openai, id: id})

      assert {:ok, request} =
               OpenAI.prepare_request(:chat, model, "Hello",
                 api_key: "test-key",
                 reasoning_effort: effort,
                 temperature: 0.4,
                 top_p: 0.8
               )

      body = request |> OpenAI.encode_body() |> Map.fetch!(:body) |> Jason.decode!()

      if effort == :none do
        assert body["temperature"] == 0.4
        assert body["top_p"] == 0.8
      else
        refute Map.has_key?(body, "temperature")
        refute Map.has_key?(body, "top_p")
      end
    end
  end
end

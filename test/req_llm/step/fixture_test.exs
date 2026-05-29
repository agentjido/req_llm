defmodule ReqLLM.Step.FixtureTest do
  use ExUnit.Case, async: true

  describe "maybe_attach/3" do
    test "stores the resolved model when attaching a fixture" do
      model = %LLMDB.Model{id: "tts-1", provider: :openai}
      request = Req.new()

      updated = ReqLLM.Step.Fixture.maybe_attach(request, model, fixture: "speech_basic")

      assert updated.private[:req_llm_model] == model
      assert Keyword.has_key?(updated.request_steps, :llm_fixture)
    end

    test "leaves the request alone without a fixture" do
      model = %LLMDB.Model{id: "tts-1", provider: :openai}
      request = Req.new()

      updated = ReqLLM.Step.Fixture.maybe_attach(request, model, [])

      refute Map.has_key?(updated.private, :req_llm_model)
      refute Keyword.has_key?(updated.request_steps, :llm_fixture)
    end
  end
end

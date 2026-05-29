defmodule ReqLLM.Step.FixtureTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Step.Fixture.Backend
  alias ReqLLM.Test.VCR

  @fixture_dir "tmp/fixture_step_test"

  setup do
    File.rm_rf(@fixture_dir)
    File.mkdir_p!(@fixture_dir)
    :ok
  end

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

  describe "handle_replay/2" do
    test "returns Req-compatible response headers" do
      path = Path.join(@fixture_dir, "response.json")
      model = %LLMDB.Model{id: "gpt-4", provider: :openai}

      :ok =
        VCR.record(path,
          provider: :openai,
          model: "gpt-4",
          request: %{
            method: "POST",
            url: "https://api.openai.com/v1/chat/completions",
            headers: [],
            canonical_json: %{}
          },
          response: %{status: 200, headers: [{"content-type", "application/json"}]},
          body: ~s({"ok":true})
        )

      {:ok, response} = Backend.handle_replay(path, model)

      assert response.headers == %{"content-type" => ["application/json"]}
    end
  end
end

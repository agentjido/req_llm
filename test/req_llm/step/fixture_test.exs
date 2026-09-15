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

  describe "handle_replay/3" do
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

      request = replay_request(%{})
      {:ok, response} = Backend.handle_replay(path, model, request)

      assert response.headers == %{"content-type" => ["application/json"]}
    end
  end

  test "loads a response when the current request matches the fixture" do
    path = Path.join(@fixture_dir, "matching_request.json")
    model = %LLMDB.Model{id: "gpt-4", provider: :openai}
    canonical_json = %{"messages" => [%{"content" => "Hello", "role" => "user"}]}

    record_fixture(path, canonical_json)

    request = replay_request(canonical_json)

    assert {:ok, %Req.Response{status: 200}} = Backend.handle_replay(path, model, request)
  end

  test "rejects a fixture when the current request body changed" do
    path = Path.join(@fixture_dir, "changed_request.json")
    model = %LLMDB.Model{id: "gpt-4", provider: :openai}
    canonical_json = %{"messages" => [%{"content" => "Hello", "role" => "user"}]}

    record_fixture(path, canonical_json)

    changed_json = %{"messages" => [%{"content" => "Changed", "role" => "user"}]}
    request = replay_request(changed_json)

    assert_raise RuntimeError,
                 ~r/Fixture request mismatch:.*Field: \$\.canonical_json\.messages\[0\]\.content/s,
                 fn -> Backend.handle_replay(path, model, request) end
  end

  test "accepts the legacy canonical JSON wrapper" do
    path = Path.join(@fixture_dir, "legacy_request.json")
    model = %LLMDB.Model{id: "gpt-4", provider: :openai}
    canonical_json = [%{"name" => "purpose", "value" => "user_data"}]

    record_fixture(path, %{"canonical_json" => canonical_json})

    request = replay_request(canonical_json)

    assert {:ok, %Req.Response{status: 200}} = Backend.handle_replay(path, model, request)
  end

  defp record_fixture(path, canonical_json) do
    VCR.record(path,
      provider: :openai,
      model: "gpt-4",
      request: %{
        method: "POST",
        url: "https://api.openai.com/v1/chat/completions",
        headers: [],
        canonical_json: canonical_json
      },
      response: %{status: 200, headers: [{"content-type", "application/json"}]},
      body: ~s({"ok":true})
    )
  end

  defp replay_request(canonical_json) do
    Req.new(method: :post, url: "https://api.openai.com/v1/chat/completions")
    |> Req.Request.put_private(:llm_canonical_json, canonical_json)
  end
end

defmodule ReqLLM.CatalogGatewayHarnessTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.ReqLlm.ModelCompat
  alias ReqLLM.Providers.CatalogGateway
  alias ReqLLM.Step.Fixture.Backend
  alias ReqLLM.Test.{CatalogGatewayCatalog, ChunkCollector, ModelMatrix, VCR}

  setup do
    CatalogGatewayCatalog.install!()
  end

  test "shared-adapter models resolve and keep their endpoint, wire ID, usage prices and identity" do
    spec = "llmapi:vendor/chat-model"
    model = ReqLLM.model!(spec)
    assert model.provider == :llmapi
    assert model.id == "vendor/chat-model"
    assert {:ok, CatalogGateway} = ReqLLM.ProviderDispatch.get(model, :chat)

    handler_id = "catalog-harness-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:req_llm, :request, :start],
          [:req_llm, :request, :exception],
          [:req_llm, :token_usage]
        ],
        fn event, _measurements, metadata, _config -> send(test_pid, {event, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Req.Test.stub(__MODULE__.TextHTTP, fn conn ->
      assert conn.host == "api.llmapi.ai"
      assert conn.request_path == "/v1/chat/completions"
      assert conn.body_params["model"] == "vendor/chat-model"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-key"]

      Req.Test.json(conn, %{
        "id" => "response-1",
        "model" => "vendor/chat-model",
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => "Hello"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 1, "total_tokens" => 4}
      })
    end)

    assert {:ok, response} =
             ReqLLM.generate_text(spec, "Hi",
               api_key: "fixture-key",
               req_http_options: [plug: {Req.Test, __MODULE__.TextHTTP}]
             )

    assert ReqLLM.Response.text(response) == "Hello"
    assert response.model == "vendor/chat-model"
    assert response.usage.input_tokens == 3
    assert response.usage.output_tokens == 1
    assert_in_delta response.usage.total_cost, 0.00005, 0.000000001
    assert_receive {[:req_llm, :request, :start], %{provider: :llmapi}}
    assert_receive {[:req_llm, :token_usage], %{provider: :llmapi}}

    Req.Test.stub(__MODULE__.ErrorHTTP, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "bad key"}}))
    end)

    assert {:error, error} =
             ReqLLM.generate_text(spec, "Hi",
               api_key: "fixture-key",
               max_retries: 0,
               req_http_options: [plug: {Req.Test, __MODULE__.ErrorHTTP}]
             )

    assert Exception.message(error) =~ "Llmapi"
    assert_receive {[:req_llm, :request, :exception], %{provider: :llmapi}}
  end

  test "compatibility selection includes executable catalog models and excludes incomplete routes",
       %{
         registry: registry
       } do
    assert ModelCompat.select_models(registry, "llmapi:*", []) == [
             {:llmapi, "vendor/chat-model"}
           ]

    assert ModelCompat.select_models(registry, "llmapi:vendor/chat-model", []) == [
             {:llmapi, "vendor/chat-model"}
           ]

    assert ModelCompat.select_models(registry, "llmapi:*", type: "all") == [
             {:llmapi, "vendor/chat-model"}
           ]

    previous_samples = Application.get_env(:req_llm, :sample_text_models)
    Application.put_env(:req_llm, :sample_text_models, [])

    on_exit(fn ->
      if previous_samples,
        do: Application.put_env(:req_llm, :sample_text_models, previous_samples),
        else: Application.delete_env(:req_llm, :sample_text_models)
    end)

    assert ModelCompat.select_models(registry, "llmapi:*", sample: true) == [
             {:llmapi, "vendor/chat-model"}
           ]

    assert ModelCompat.select_models(registry, "llmapi:*", type: "embedding") == []
    assert ModelCompat.select_models(registry, "missing_gateway_runtime:*", []) == []

    assert ModelCompat.test_args_for(:llmapi, :text, "basic") == [
             "test",
             "test/coverage/catalog_gateway/comprehensive_test.exs",
             "--only",
             "scenario:basic"
           ]

    assert ModelCompat.test_args_for(:llmapi, :all) == [
             "test",
             "test/coverage/catalog_gateway/comprehensive_test.exs",
             "--only",
             "provider:llmapi"
           ]

    assert File.exists?("test/coverage/catalog_gateway/comprehensive_test.exs")
  end

  test "default matrix discovery and explicit patterns include only executable gateway models" do
    for pattern <- ["all", "*:*", "llmapi:*"] do
      specs = ModelMatrix.selected_specs(env: %{"REQ_LLM_MODELS" => pattern})
      assert "llmapi:vendor/chat-model" in specs
      refute "llmapi:catalog-only" in specs
      refute "llmapi:missing-contract" in specs
      refute "missing_gateway_runtime:vendor/chat-model" in specs
    end

    assert ModelMatrix.selected_specs(env: %{"REQ_LLM_MODELS" => "llmapi:*"}, operation: :all) ==
             ["llmapi:vendor/chat-model"]
  end

  test "tool capability does not schedule object scenarios without a separate execution contract" do
    refute ReqLLM.ProviderTest.Comprehensive.supports_object_generation?(
             "llmapi:vendor/chat-model"
           )

    refute ReqLLM.ProviderTest.Comprehensive.supports_streaming_object_generation?(
             "llmapi:vendor/chat-model"
           )
  end

  test "streaming coverage requires a catalog streaming contract", %{model: model} do
    assert ReqLLM.ProviderTest.Comprehensive.supports_text_streaming?(model)

    model = %{model | capabilities: put_in(model.capabilities, [:streaming, :text], false)}
    refute ReqLLM.ProviderTest.Comprehensive.supports_text_streaming?(model)
    assert ReqLLM.ProviderDispatch.executable?(model, :text)
    refute ReqLLM.ProviderTest.Comprehensive.supports_text_streaming?("llmapi:missing-contract")
  end

  test "streaming fixture replay dispatches an unregistered provider through its catalog contract",
       %{
         model: model
       } do
    fixture_dir =
      Path.join(System.tmp_dir!(), "catalog-fixture-#{System.unique_integer([:positive])}")

    File.mkdir_p!(fixture_dir)
    on_exit(fn -> File.rm_rf!(fixture_dir) end)
    path = Path.join(fixture_dir, "streaming.json")
    {:ok, collector} = ChunkCollector.start_link()

    payload = %{
      "id" => "response-1",
      "model" => "vendor/chat-model",
      "choices" => [%{"index" => 0, "delta" => %{"content" => "Hello"}, "finish_reason" => nil}]
    }

    finish =
      put_in(payload, ["choices"], [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}])

    ChunkCollector.add_chunk(collector, "data: #{Jason.encode!(payload)}\n\n")
    ChunkCollector.add_chunk(collector, "data: #{Jason.encode!(finish)}\n\n")
    ChunkCollector.add_chunk(collector, "data: [DONE]\n\n")
    canonical_json = %{"model" => "vendor/chat-model", "stream" => true}

    :ok =
      VCR.record(path,
        provider: :llmapi,
        model: "vendor/chat-model",
        request: %{
          method: "POST",
          url: "https://api.llmapi.ai/v1/chat/completions",
          headers: [],
          canonical_json: canonical_json
        },
        response: %{status: 200, headers: [{"content-type", "text/event-stream"}]},
        collector: collector
      )

    request =
      Req.new(method: :post, url: "https://api.llmapi.ai/v1/chat/completions")
      |> Req.Request.put_private(:llm_canonical_json, canonical_json)

    assert {:ok, response} = Backend.handle_replay(path, model, request)
    chunks = Enum.to_list(response.body)
    assert Enum.any?(chunks, &match?(%ReqLLM.StreamChunk{type: :content, text: "Hello"}, &1))

    assert Enum.any?(
             chunks,
             &match?(%ReqLLM.StreamChunk{type: :meta, metadata: %{terminal?: true}}, &1)
           )
  end

  test "replay fake keys use declared catalog environment variables without replacing real keys" do
    env_names = ["LLM_API_KEY", "LLMAPI_API_KEY", "REQ_LLM_FIXTURES_MODE"]
    previous_env = Map.new(env_names, &{&1, System.get_env(&1)})
    previous_config = Application.get_env(:req_llm, :llmapi_api_key)

    on_exit(fn ->
      for {name, value} <- previous_env do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      if previous_config,
        do: Application.put_env(:req_llm, :llmapi_api_key, previous_config),
        else: Application.delete_env(:req_llm, :llmapi_api_key)
    end)

    System.put_env("REQ_LLM_FIXTURES_MODE", "replay")
    System.delete_env("LLM_API_KEY")
    System.delete_env("LLMAPI_API_KEY")
    Application.delete_env(:req_llm, :llmapi_api_key)
    ReqLLM.TestSupport.FakeKeys.install!()
    assert System.get_env("LLM_API_KEY") == "test-key-llmapi"

    System.delete_env("LLM_API_KEY")
    System.put_env("LLMAPI_API_KEY", "private-fixture-key")
    ReqLLM.TestSupport.FakeKeys.install!()
    assert System.get_env("LLM_API_KEY") == nil
    assert System.get_env("LLMAPI_API_KEY") == "private-fixture-key"

    System.delete_env("LLMAPI_API_KEY")
    System.put_env("REQ_LLM_FIXTURES_MODE", "record")
    ReqLLM.TestSupport.FakeKeys.install!()
    assert System.get_env("LLM_API_KEY") == nil
  end
end

defmodule ReqLLM.Providers.InferenceTest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Inference

  alias ReqLLM.Providers.Inference

  defp inference_model(model_id \\ "deepseek-v4.1-flash-1017") do
    %LLMDB.Model{
      id: model_id,
      model: model_id,
      provider_model_id: model_id,
      provider: :inference,
      name: model_id,
      family: "inference-openai-compatible",
      capabilities: %{
        chat: true,
        reasoning: %{enabled: true},
        tools: %{enabled: true, streaming: true, strict: true},
        json: %{native: true, schema: true, strict: true}
      },
      limits: %{context: 1_040_000, output: 393_216},
      extra: %{wire: %{protocol: "openai_chat"}}
    }
  end

  describe "provider contract" do
    test "declares the Inference.net identity and authentication setting" do
      assert Inference.provider_id() == :inference
      assert Inference.base_url() == "https://api.inference.net/v1"
      assert Inference.default_env_key() == "INFERENCE_API_KEY"
      assert Inference.display_name() == "Inference.net"
      assert {:ok, Inference} = ReqLLM.provider(:inference)
    end

    test "exposes the documented provider options" do
      schema_keys = Inference.provider_schema().schema |> Keyword.keys()

      assert schema_keys == [
               :response_format,
               :service_tier,
               :reasoning,
               :verbosity,
               :inference_environment,
               :inference_task_id,
               :inference_metadata
             ]
    end
  end

  describe "request preparation" do
    test "prepares an OpenAI-compatible chat request" do
      {:ok, request} =
        Inference.prepare_request(:chat, inference_model(), "Hello", temperature: 0.2)

      assert request.method == :post
      assert request.url.path == "/chat/completions"
      assert request.options[:base_url] == "https://api.inference.net/v1"
    end

    test "respects the US-only base URL override" do
      {:ok, request} =
        Inference.prepare_request(:chat, inference_model(), "Hello",
          base_url: "https://us.api.inference.net/v1"
        )

      assert request.options[:base_url] == "https://us.api.inference.net/v1"
    end

    test "replaces the legacy catalog URL with the current provider URL" do
      model = %{inference_model() | base_url: "https://inference.net/v1"}
      {:ok, request} = Inference.prepare_request(:chat, model, "Hello", [])

      assert request.options[:base_url] == "https://api.inference.net/v1"
    end

    test "preserves a custom model URL" do
      model = %{inference_model() | base_url: "https://inference.example/v1"}
      {:ok, request} = Inference.prepare_request(:chat, model, "Hello", [])

      assert request.options[:base_url] == "https://inference.example/v1"
    end

    test "rejects operations not implemented by the ReqLLM provider" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Inference.prepare_request(:embedding, inference_model(), "Hello", [])
    end
  end

  describe "body encoding" do
    test "sends reasoning and service options in the chat body" do
      {:ok, request} =
        Inference.prepare_request(:chat, inference_model(), "Solve this",
          reasoning_effort: :high,
          provider_options: [
            reasoning: %{enabled: true},
            service_tier: "priority",
            verbosity: "low"
          ]
        )

      body = request |> Inference.encode_body() |> ReqLLM.Test.Helpers.json_body()

      assert body["model"] == "deepseek-v4.1-flash-1017"
      assert body["reasoning_effort"] == "high"
      assert body["reasoning"] == %{"enabled" => true}
      assert body["service_tier"] == "priority"
      assert body["verbosity"] == "low"
    end

    test "omits the default reasoning effort" do
      {:ok, request} =
        Inference.prepare_request(:chat, inference_model(), "Hello", reasoning_effort: :default)

      body = request |> Inference.encode_body() |> ReqLLM.Test.Helpers.json_body()
      refute Map.has_key?(body, "reasoning_effort")
    end

    test "normalizes a canonical forced tool choice" do
      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get the weather",
          parameter_schema: [location: [type: :string, required: true]],
          strict: true,
          callback: fn _arguments -> {:ok, "sunny"} end
        )

      {:ok, request} =
        Inference.prepare_request(:chat, inference_model(), "Use the tool",
          tools: [tool],
          tool_choice: %{type: "tool", name: "get_weather"}
        )

      body = request |> Inference.encode_body() |> ReqLLM.Test.Helpers.json_body()

      assert body["tool_choice"] == %{
               "type" => "function",
               "function" => %{"name" => "get_weather"}
             }

      assert hd(body["tools"])["function"]["strict"]
    end
  end

  describe "structured output" do
    test "uses a strict native JSON Schema response format" do
      {:ok, compiled} =
        ReqLLM.Schema.compile(
          name: [type: :string, required: true],
          age: [type: :pos_integer, required: true]
        )

      {:ok, request} =
        Inference.prepare_request(:object, inference_model(), "Make a person",
          compiled_schema: compiled
        )

      body = request |> Inference.encode_body() |> ReqLLM.Test.Helpers.json_body()

      refute Map.has_key?(body, "tools")

      assert %{
               "type" => "json_schema",
               "json_schema" => %{
                 "strict" => true,
                 "schema" => %{
                   "type" => "object",
                   "additionalProperties" => false,
                   "required" => required
                 }
               }
             } = body["response_format"]

      assert Enum.sort(required) == ["age", "name"]
    end

    test "keeps reasoning effort valid when streamed object options are processed twice" do
      model = inference_model()

      processed =
        ReqLLM.Provider.Options.process!(Inference, :object, model,
          api_key: "test-key",
          operation: :object,
          reasoning_effort: :minimal,
          max_tokens: 128
        )

      assert processed[:reasoning_effort] == :minimal

      assert {:ok, request} =
               Inference.attach_stream(model, context_fixture(), processed, :finch)

      body = request.body |> IO.iodata_to_binary() |> Jason.decode!()
      assert body["reasoning_effort"] == "minimal"
    end
  end

  describe "observability headers" do
    test "adds task, environment, and metadata headers to normal requests" do
      attached =
        Inference.attach(Req.new(), inference_model(),
          provider_options: [
            inference_environment: "development",
            inference_task_id: "task-123",
            inference_metadata: %{"user-id" => "user-456", attempt: 2}
          ]
        )

      assert attached.headers["x-inference-environment"] == ["development"]
      assert attached.headers["x-inference-task-id"] == ["task-123"]
      assert attached.headers["x-inference-metadata-user-id"] == ["user-456"]
      assert attached.headers["x-inference-metadata-attempt"] == ["2"]
    end

    test "adds the same headers to streaming requests" do
      config =
        Inference.streaming_http(inference_model(), "test-key",
          inference_environment: "production",
          inference_task_id: "stream-123",
          inference_metadata: %{"chat-id" => "chat-456"}
        )

      assert {"Authorization", "Bearer test-key"} in config.headers
      assert {"x-inference-environment", "production"} in config.headers
      assert {"x-inference-task-id", "stream-123"} in config.headers
      assert {"x-inference-metadata-chat-id", "chat-456"} in config.headers
    end

    test "uses the current endpoint for streaming when catalog metadata is stale" do
      model = %{inference_model() | base_url: "https://inference.net/v1"}

      assert {:ok, request} =
               Inference.attach_stream(model, context_fixture(), [api_key: "test-key"], :finch)

      assert request.scheme == :https
      assert request.host == "api.inference.net"
      assert request.path == "/v1/chat/completions"
    end

    test "rejects invalid metadata header names and values" do
      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        Inference.streaming_http(inference_model(), "test-key",
          inference_metadata: %{"bad key" => "value"}
        )
      end

      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        Inference.streaming_http(inference_model(), "test-key",
          inference_metadata: %{"safe-key" => "bad\r\nvalue"}
        )
      end
    end
  end

  describe "option translation" do
    test "renders reasoning effort and removes token budgets" do
      {translated, warnings} =
        Inference.translate_options(:chat, inference_model(),
          reasoning_effort: :xhigh,
          reasoning_token_budget: 4096
        )

      assert translated[:reasoning_effort] == :xhigh
      assert translated[:receive_timeout] == 300_000
      refute Keyword.has_key?(translated, :reasoning_token_budget)
      assert [warning] = warnings
      assert warning =~ "reasoning_token_budget"
    end
  end

  describe "response decoding" do
    test "decodes an OpenAI-compatible response" do
      request = %Req.Request{
        options: [context: context_fixture(), model: "deepseek-v4.1-flash-1017", operation: :chat],
        private: %{req_llm_model: inference_model()}
      }

      response = %Req.Response{
        status: 200,
        body:
          openai_format_json_fixture(
            model: "deepseek-v4.1-flash-1017",
            content: "Hello from Inference.net"
          )
      }

      {_request, decoded} = Inference.decode_response({request, response})

      assert %ReqLLM.Response{} = decoded.body
      assert ReqLLM.Response.text(decoded.body) == "Hello from Inference.net"
    end
  end
end

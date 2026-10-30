defmodule ReqLLM.Providers.AmazonBedrock.MantleEndpointTest do
  use ExUnit.Case, async: true

  import ReqLLM.Test.AmazonBedrockHelpers, only: [build_aws_event_stream_message: 1]

  alias ReqLLM.{Context, Providers.AmazonBedrock}

  describe "bedrock-mantle endpoint" do
    setup do
      context = Context.new([Context.user("Hello")])

      opts = [
        access_key_id: "AKIATEST",
        secret_access_key: "secretTEST",
        region: "eu-west-1",
        provider_options: [endpoint: :mantle]
      ]

      {:ok, gpt_oss} = ReqLLM.model("amazon-bedrock:openai.gpt-oss-120b")
      {:ok, gpt_5} = ReqLLM.model(%{provider: :amazon_bedrock, id: "openai.gpt-5.6-terra"})
      {:ok, claude} = ReqLLM.model("amazon-bedrock:anthropic.claude-3-haiku-20240307-v1:0")

      {:ok, context: context, opts: opts, gpt_oss: gpt_oss, gpt_5: gpt_5, claude: claude}
    end

    test "stays on bedrock-runtime unless asked", %{context: context, opts: opts, gpt_oss: model} do
      {:ok, request} =
        AmazonBedrock.prepare_request(
          :chat,
          model,
          context,
          Keyword.delete(opts, :provider_options)
        )

      assert request.url.host == "bedrock-runtime.eu-west-1.amazonaws.com"
      assert request.url.path == "/model/openai.gpt-oss-120b/invoke"
      assert request.options[:endpoint] == :runtime
    end

    test "preserves runtime token parameters", %{context: context, opts: opts} do
      {:ok, model} = ReqLLM.model(%{provider: :amazon_bedrock, id: "openai.gpt-5.4"})

      opts =
        opts
        |> Keyword.delete(:provider_options)
        |> Keyword.put(:max_tokens, 400)

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
      body = Jason.decode!(request.body)

      assert body["max_tokens"] == 400
      refute Map.has_key?(body, "max_completion_tokens")
    end

    test "sends chat completions to bedrock-mantle", %{
      context: context,
      opts: opts,
      gpt_oss: model
    } do
      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      assert request.url.host == "bedrock-mantle.eu-west-1.api.aws"
      assert request.url.path == "/v1/chat/completions"
      assert request.options[:endpoint] == :mantle
      assert request.options[:model_family] == "openai"
      assert request.options[:use_converse] == false

      assert %{"model" => "openai.gpt-oss-120b", "messages" => [%{"role" => "user"}]} =
               Jason.decode!(request.body)
    end

    test "sends every other family as chat completions too", %{context: context, opts: opts} do
      {:ok, model} =
        ReqLLM.model(%{provider: :amazon_bedrock, id: "mistral.voxtral-mini-3b-2507"})

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      assert request.url.path == "/v1/chat/completions"
      assert request.options[:model_family] == "openai"
      assert %{"model" => "mistral.voxtral-mini-3b-2507"} = Jason.decode!(request.body)
    end

    test "keeps non-Responses OpenAI-compatible models on chat completions", %{
      context: context,
      opts: opts
    } do
      for id <- ["google.gemma-4-31b", "xai.grok-4.3"] do
        {:ok, model} = ReqLLM.model(%{provider: :amazon_bedrock, id: id})
        {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

        assert request.url.path == "/openai/v1/chat/completions"
        assert request.options[:model_family] == "openai"
        assert %{"model" => ^id} = Jason.decode!(request.body)

        {:ok, finch_request} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)
        assert finch_request.path == "/openai/v1/chat/completions"
      end
    end

    test "catalog shape does not move Gemma to Responses", %{
      context: context,
      opts: opts
    } do
      model =
        LLMDB.Model.new!(%{
          provider: :amazon_bedrock,
          id: "google.gemma-4-31b",
          extra: %{provider: %{shape: "responses"}}
        })

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
      assert request.url.path == "/openai/v1/chat/completions"
    end

    test "routes GPT-6 models on /openai/v1", %{context: context, opts: opts} do
      for id <- ["openai.gpt-6.1-sol", "openai.gpt-6-luna"] do
        {:ok, model} = ReqLLM.model(%{provider: :amazon_bedrock, id: id})
        {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

        assert request.url.path == "/openai/v1/responses"
        assert %{"model" => ^id} = Jason.decode!(request.body)

        {:ok, finch_request} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)
        assert finch_request.path == "/openai/v1/responses"
      end
    end

    test "sends any service tier through to Mantle", %{context: context, opts: opts} do
      {:ok, model} = ReqLLM.model(%{provider: :amazon_bedrock, id: "openai.gpt-6.1-sol"})
      opts = Keyword.put(opts, :service_tier, "ultrafast")

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
      assert Jason.decode!(request.body)["service_tier"] == "ultrafast"

      {:ok, stream} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)
      assert Jason.decode!(stream.body)["service_tier"] == "ultrafast"
    end

    test "routes GPT-5 Responses bodies on both Mantle transports", %{
      context: context,
      opts: opts,
      gpt_5: model
    } do
      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get the weather",
          parameter_schema: [location: [type: :string, required: true]],
          callback: fn _args -> {:ok, "sunny"} end
        )

      opts =
        Keyword.merge(opts,
          max_tokens: 400,
          reasoning_effort: :high,
          tools: [tool]
        )

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
      assert Regex.scan(~r/"model":/, request.body) == [["\"model\":"]]
      assert request.body =~ ~s("model":"openai.gpt-5.6-terra")
      body = Jason.decode!(request.body)

      assert request.url.path == "/openai/v1/responses"
      assert [%{"role" => "user"}] = body["input"]
      refute Map.has_key?(body, "messages")
      assert [%{"type" => "function", "name" => "get_weather"}] = body["tools"]
      assert body["reasoning"] == %{"effort" => "high"}
      assert body["max_output_tokens"] == 400
      refute Map.has_key?(body, "max_tokens")

      {:ok, stream} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)
      assert Regex.scan(~r/"model":/, stream.body) == [["\"model\":"]]
      assert stream.body =~ ~s("model":"openai.gpt-5.6-terra")
      body = Jason.decode!(stream.body)

      assert stream.path == "/openai/v1/responses"
      assert [%{"role" => "user"}] = body["input"]
      assert [%{"type" => "function", "name" => "get_weather"}] = body["tools"]
      assert body["max_output_tokens"] == 400
      refute Map.has_key?(body, "max_tokens")
    end

    test "uses model shape metadata and excludes GPT OSS", %{context: context, opts: opts} do
      for extra <- [
            %{"provider" => %{"shape" => "responses"}},
            %{provider: %{shape: "responses"}}
          ] do
        {:ok, model} =
          ReqLLM.model(%{
            provider: :amazon_bedrock,
            id: "xai.grok-4.3",
            extra: extra
          })

        {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
        assert request.url.path == "/openai/v1/responses"
      end

      {:ok, model} =
        ReqLLM.model(%{
          provider: :amazon_bedrock,
          id: "openai.gpt-oss-120b",
          extra: %{"provider" => %{"shape" => "responses"}}
        })

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
      assert request.url.path == "/v1/chat/completions"
    end

    test "constrains object requests with a strict schema on both Mantle transports", %{
      context: context,
      opts: opts,
      gpt_5: model
    } do
      {:ok, compiled_schema} =
        ReqLLM.Schema.compile(location: [type: :string, required: true])

      opts = Keyword.merge(opts, operation: :object, compiled_schema: compiled_schema)
      {:ok, request} = AmazonBedrock.prepare_request(:object, model, context, opts)
      {:ok, stream} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)

      for body <- [request.body, stream.body] do
        body = Jason.decode!(body)
        assert [tool] = body["tools"]
        assert tool["name"] == "structured_output"
        assert tool["strict"] == true
        assert tool["parameters"]["properties"]["location"]["type"] == "string"
        assert tool["parameters"]["required"] == ["location"]
        assert tool["parameters"]["additionalProperties"] == false
        assert body["tool_choice"] == %{"type" => "function", "name" => "structured_output"}
        assert body["parallel_tool_calls"] == false
      end

      payload = %{
        "id" => "resp_object",
        "status" => "completed",
        "output" => [
          %{
            "type" => "function_call",
            "call_id" => "call_object",
            "name" => "structured_output",
            "arguments" => ~s({"location":"Boston"})
          }
        ]
      }

      {_request, response} =
        AmazonBedrock.decode_response({request, %Req.Response{status: 200, body: payload}})

      assert response.body.object == %{"location" => "Boston"}
      assert response.body.model == "openai.gpt-5.6-terra"
      assert request.options[:compiled_schema] == compiled_schema
    end

    test "disables Responses storage by default and accepts explicit storage options", %{
      context: context,
      opts: opts,
      gpt_5: model
    } do
      for store <- [:default, false, true] do
        provider_opts = opts[:provider_options]

        provider_opts =
          if store == :default, do: provider_opts, else: Keyword.put(provider_opts, :store, store)

        opts = Keyword.put(opts, :provider_options, provider_opts)
        expected_store = store == true

        {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
        {:ok, stream} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)

        assert Jason.decode!(request.body)["store"] == expected_store
        assert Jason.decode!(stream.body)["store"] == expected_store
      end
    end

    test "decodes runtime GPT-5 chat deltas through the runtime parser", %{
      context: context,
      opts: opts,
      gpt_5: model
    } do
      opts = Keyword.delete(opts, :provider_options)
      {:ok, request} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)
      assert request.path == "/model/openai.gpt-5.6-terra/invoke-with-response-stream"
      assert Map.has_key?(Jason.decode!(request.body), "messages")

      delta = %{
        "object" => "chat.completion.chunk",
        "choices" => [%{"index" => 0, "delta" => %{"content" => "Hello"}}]
      }

      payload = Jason.encode!(%{"bytes" => Base.encode64(Jason.encode!(delta))})
      parser = AmazonBedrock.stream_protocol_parser(model, opts)
      assert {:ok, [event], <<>>} = parser.(build_aws_event_stream_message(payload), nil)

      for event <- [event, %{data: event}] do
        assert {[%ReqLLM.StreamChunk{type: :content, text: "Hello"}], nil} =
                 AmazonBedrock.decode_stream_event(event, model, nil)
      end
    end

    test "preserves Anthropic token parameters on both Mantle transports", %{
      context: context,
      opts: opts,
      claude: model
    } do
      opts = Keyword.put(opts, :max_tokens, 400)

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
      body = Jason.decode!(request.body)

      assert body["max_tokens"] == 400
      refute Map.has_key?(body, "max_completion_tokens")

      {:ok, stream} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)
      body = Jason.decode!(stream.body)

      assert body["max_tokens"] == 400
      refute Map.has_key?(body, "max_completion_tokens")
    end

    test "keeps a top-level service_tier on both Mantle transports", %{
      context: context,
      opts: opts,
      gpt_oss: model
    } do
      opts = Keyword.put(opts, :service_tier, "flex")

      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
      body = Jason.decode!(request.body)

      assert request.url.path == "/v1/chat/completions"
      assert body["service_tier"] == "flex"
      refute Map.has_key?(body, "serviceTier")

      {:ok, stream} = AmazonBedrock.attach_stream(model, context, opts, ReqLLM.Finch)
      body = Jason.decode!(stream.body)

      assert stream.path == "/v1/chat/completions"
      assert body["service_tier"] == "flex"
      refute Map.has_key?(body, "serviceTier")
    end

    test "mantle_base_path overrides the base picked from the model id", %{
      context: context,
      opts: opts,
      gpt_oss: gpt_oss
    } do
      {:ok, gpt_5} = ReqLLM.model(%{provider: :amazon_bedrock, id: "openai.gpt-5.4"})

      to_openai =
        Keyword.put(opts, :provider_options, endpoint: :mantle, mantle_base_path: "/openai/v1")

      to_v1 = Keyword.put(opts, :provider_options, endpoint: :mantle, mantle_base_path: "/v1")

      {:ok, request} = AmazonBedrock.prepare_request(:chat, gpt_oss, context, to_openai)
      assert request.url.path == "/openai/v1/chat/completions"

      {:ok, request} = AmazonBedrock.prepare_request(:chat, gpt_5, context, to_v1)
      assert request.url.path == "/v1/responses"

      {:ok, finch_request} =
        AmazonBedrock.attach_stream(gpt_oss, context, to_openai, ReqLLM.Finch)

      assert finch_request.path == "/openai/v1/chat/completions"
    end

    test "sends Claude through the Anthropic Messages API", %{
      context: context,
      opts: opts,
      claude: model
    } do
      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      assert request.url.host == "bedrock-mantle.eu-west-1.api.aws"
      assert request.url.path == "/anthropic/v1/messages"
      assert request.options[:model_family] == "anthropic"
      assert Req.Request.get_header(request, "anthropic-version") == ["2023-06-01"]

      body = Jason.decode!(request.body)
      assert body["model"] == "anthropic.claude-3-haiku-20240307-v1:0"
      refute Map.has_key?(body, "anthropic_version")
      assert [%{"role" => "user"}] = body["messages"]
    end

    test "authenticates an API key the way each route expects", %{
      context: context,
      gpt_oss: gpt_oss,
      claude: claude
    } do
      opts = [api_key: "bedrock-key", region: "eu-west-1", provider_options: [endpoint: :mantle]]

      {:ok, chat} = AmazonBedrock.prepare_request(:chat, gpt_oss, context, opts)
      assert Req.Request.get_header(chat, "authorization") == ["Bearer bedrock-key"]

      {:ok, messages} = AmazonBedrock.prepare_request(:chat, claude, context, opts)
      assert Req.Request.get_header(messages, "x-api-key") == ["bedrock-key"]
      assert Req.Request.get_header(messages, "authorization") == []
    end

    test "streams as server-sent events", %{
      context: context,
      opts: opts,
      gpt_oss: gpt_oss,
      claude: claude
    } do
      {:ok, chat} = AmazonBedrock.attach_stream(gpt_oss, context, opts, ReqLLM.Finch)
      headers = Map.new(chat.headers)

      assert chat.host == "bedrock-mantle.eu-west-1.api.aws"
      assert chat.path == "/v1/chat/completions"
      assert headers["accept"] == "text/event-stream"
      assert headers["authorization"] =~ "AWS4-HMAC-SHA256"
      assert headers["authorization"] =~ "/bedrock-mantle/aws4_request"
      assert %{"stream" => true} = Jason.decode!(chat.body)

      {:ok, messages} = AmazonBedrock.attach_stream(claude, context, opts, ReqLLM.Finch)

      assert messages.path == "/anthropic/v1/messages"
      assert Map.new(messages.headers)["anthropic-version"] == "2023-06-01"

      assert %{"stream" => true, "model" => "anthropic.claude-3-haiku-20240307-v1:0"} =
               Jason.decode!(messages.body)
    end

    test "picks the stream parser from the endpoint", %{gpt_oss: model} do
      sse = AmazonBedrock.stream_protocol_parser(model, provider_options: [endpoint: :mantle])

      assert {:ok, [%{data: ~s({"a":1})}], %ServerSentEvents.Parser{} = state} =
               sse.(~s(data: {"a":1}\n\n), nil)

      assert {:ok, [%{data: ~s({"b":2})}], %ServerSentEvents.Parser{}} =
               sse.(~s(data: {"b":2}\n\n), state)

      event_stream = AmazonBedrock.stream_protocol_parser(model, [])
      assert {:incomplete, <<0, 0>>} = event_stream.(<<0, 0>>, nil)
    end

    test "decodes each Mantle stream wire format", %{
      gpt_oss: gpt_oss,
      gpt_5: gpt_5,
      claude: claude
    } do
      delta = %{data: %{"choices" => [%{"index" => 0, "delta" => %{"content" => "Hi"}}]}}

      assert {[%ReqLLM.StreamChunk{type: :content, text: "Hi"}], nil} =
               AmazonBedrock.decode_stream_event(delta, gpt_oss, nil)

      delta = %{data: %{"event" => "response.output_text.delta", "delta" => "Hi"}}

      assert {[%ReqLLM.StreamChunk{type: :content, text: "Hi"}], _state} =
               AmazonBedrock.decode_stream_event(delta, gpt_5, nil)

      delta = %{
        event: "content_block_delta",
        data: %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "Hi"}
        }
      }

      assert {[%ReqLLM.StreamChunk{type: :content, text: "Hi"}], _state} =
               AmazonBedrock.decode_stream_event(
                 delta,
                 claude,
                 AmazonBedrock.init_stream_state(claude)
               )
    end

    test "decodes buffered Responses payloads with the routed formatter", %{
      context: context,
      opts: opts,
      gpt_5: model
    } do
      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)

      payload = %{
        "id" => "resp_123",
        "model" => "openai.gpt-5.6-terra",
        "status" => "completed",
        "output" => [
          %{
            "type" => "function_call",
            "call_id" => "call_123",
            "name" => "get_weather",
            "arguments" => ~s({"location":"Boston"})
          }
        ],
        "usage" => %{"input_tokens" => 8, "output_tokens" => 12}
      }

      {_request, response} =
        AmazonBedrock.decode_response({request, %Req.Response{status: 200, body: payload}})

      assert [tool_call] = response.body.message.tool_calls
      assert tool_call.id == "call_123"
      assert tool_call.function.name == "get_weather"
    end

    test "sends the project header each bedrock-mantle route takes", %{
      context: context,
      opts: opts,
      gpt_oss: gpt_oss,
      claude: claude
    } do
      opts = put_in(opts, [:provider_options, :project], "proj_abc123")

      {:ok, chat} = AmazonBedrock.prepare_request(:chat, gpt_oss, context, opts)
      assert Req.Request.get_header(chat, "openai-project") == ["proj_abc123"]

      {:ok, messages} = AmazonBedrock.prepare_request(:chat, claude, context, opts)
      assert Req.Request.get_header(messages, "anthropic-workspace-id") == ["proj_abc123"]
      assert Req.Request.get_header(messages, "openai-project") == []

      {:ok, stream} = AmazonBedrock.attach_stream(gpt_oss, context, opts, ReqLLM.Finch)
      headers = Map.new(stream.headers)
      assert headers["openai-project"] == "proj_abc123"
      assert headers["authorization"] =~ "openai-project"
    end

    test "sends no project header off bedrock-mantle", %{
      context: context,
      opts: opts,
      gpt_oss: model
    } do
      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, opts)
      assert Req.Request.get_header(request, "openai-project") == []

      runtime = Keyword.put(opts, :provider_options, project: "proj_abc123")
      {:ok, request} = AmazonBedrock.prepare_request(:chat, model, context, runtime)
      assert request.url.host == "bedrock-runtime.eu-west-1.amazonaws.com"
      assert Req.Request.get_header(request, "openai-project") == []
    end
  end
end

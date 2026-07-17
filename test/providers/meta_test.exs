defmodule ReqLLM.Providers.MetaTest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Meta

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.Providers.Meta
  alias ReqLLM.Providers.OpenAI.ResponsesAPI

  defp meta_model do
    ReqLLM.model!("meta:muse-spark-1.1")
  end

  describe "provider contract" do
    test "provider identity and configuration" do
      assert Meta.provider_id() == :meta
      assert Meta.base_url() == "https://api.meta.ai/v1"
      assert Meta.default_env_key() == "MODEL_API_KEY"
      assert Meta.display_name() == "Meta Model API"
    end

    test "provider schema exposes Meta Responses request fields" do
      schema_keys = Meta.provider_schema().schema |> Keyword.keys()

      assert schema_keys == [
               :include,
               :max_output_tokens,
               :parallel_tool_calls,
               :prompt_cache_retention,
               :reasoning_summary,
               :response_format,
               :store
             ]
    end

    test "provider is discoverable and Muse resolves from LLMDB" do
      assert {:ok, Meta} = ReqLLM.provider(:meta)
      assert {:ok, model} = ReqLLM.model("meta:muse-spark-1.1")
      assert model.provider == :meta
      assert model.id == "muse-spark-1.1"
      assert model.cost.input == 1.25
      assert model.cost.output == 4.25
    end

    test "Meta models use the Responses response builder" do
      assert ReqLLM.Provider.ResponseBuilder.for_model(meta_model()) ==
               ResponsesAPI.ResponseBuilder
    end
  end

  describe "request preparation" do
    test "prepare_request creates a stateless Responses request" do
      {:ok, request} =
        Meta.prepare_request(:chat, meta_model(), "Hello world", reasoning_effort: :low)

      assert %Req.Request{} = request
      assert request.url.path == "/responses"
      assert request.method == :post
      assert request.options[:base_url] == "https://api.meta.ai/v1"
      assert request.options[:api_mod] == ResponsesAPI
      assert request.options[:provider_options][:store] == false

      assert request.options[:provider_options][:include] == [
               "reasoning.encrypted_content"
             ]
    end

    test "prepare_request rejects unsupported operations" do
      {:error, error} = Meta.prepare_request(:embedding, meta_model(), "Hello", [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error
    end

    test "object requests use Responses JSON schema output" do
      {:ok, compiled_schema} =
        ReqLLM.Schema.compile(name: [type: :string, required: true])

      {:ok, request} =
        Meta.prepare_request(
          :object,
          meta_model(),
          "Generate a name",
          compiled_schema: compiled_schema,
          provider_options: %{store: true}
        )

      body = request |> Meta.encode_body() |> ReqLLM.Test.Helpers.json_body()

      assert body["text"]["format"]["type"] == "json_schema"
      assert body["text"]["format"]["strict"] == true
      assert body["text"]["format"]["schema"]["required"] == ["name"]
      assert body["parallel_tool_calls"] == false
      assert body["store"] == true
    end
  end

  describe "option translation and body encoding" do
    test "translate_options maps canonical token and reasoning controls" do
      {translated, warnings} =
        Meta.translate_options(
          :chat,
          meta_model(),
          max_tokens: 256,
          reasoning_effort: :high,
          reasoning_token_budget: 1000
        )

      assert translated[:max_output_tokens] == 256
      assert translated[:reasoning_effort] == "high"
      refute Keyword.has_key?(translated, :max_tokens)
      refute Keyword.has_key?(translated, :reasoning_token_budget)
      assert length(warnings) == 2
    end

    test "translate_options maps unsupported none effort to minimal" do
      {translated, warnings} =
        Meta.translate_options(:chat, meta_model(), reasoning_effort: :none)

      assert translated[:reasoning_effort] == "minimal"
      assert [warning] = warnings
      assert warning =~ "do not accept reasoning_effort :none"
    end

    test "translate_options preserves max reasoning effort" do
      {translated, warnings} =
        Meta.translate_options(:chat, meta_model(), reasoning_effort: :max)

      assert translated[:reasoning_effort] == "max"
      assert warnings == []
    end

    test "translate_options enforces Meta's minimum output token limit" do
      {translated, warnings} =
        Meta.translate_options(:chat, meta_model(), max_tokens: 10)

      assert translated[:max_output_tokens] == 16
      assert Enum.any?(warnings, &(&1 =~ "Meta API minimum (16)"))
    end

    test "encode_body emits Meta-compatible Responses fields" do
      request = %Req.Request{
        options: [
          context: context_fixture(),
          model: "muse-spark-1.1",
          stream: false,
          max_output_tokens: 512,
          reasoning_effort: "high",
          parallel_tool_calls: false,
          prompt_cache_retention: "24h",
          provider_options: [
            reasoning_summary: :auto,
            response_format: %{
              type: "json_schema",
              json_schema: %{
                name: "answer",
                strict: true,
                schema: %{"type" => "object", "properties" => %{}}
              }
            }
          ]
        ],
        private: %{req_llm_model: meta_model()}
      }

      encoded_request = Meta.encode_body(request)
      assert_no_duplicate_json_keys(ReqLLM.Test.Helpers.json_iodata(encoded_request))
      decoded = ReqLLM.Test.Helpers.json_body(encoded_request)

      assert decoded["model"] == "muse-spark-1.1"
      assert decoded["max_output_tokens"] == 512
      assert decoded["reasoning"] == %{"effort" => "high", "summary" => "auto"}
      assert decoded["parallel_tool_calls"] == false
      assert decoded["prompt_cache_retention"] == "24h"
      assert decoded["store"] == false
      assert decoded["include"] == ["reasoning.encrypted_content"]
      assert decoded["text"]["format"]["type"] == "json_schema"
      refute Map.has_key?(decoded, "max_tokens")
      assert is_list(decoded["input"])
    end

    test "encode_body replays Meta encrypted reasoning details" do
      reasoning_detail = %ReasoningDetails{
        text: "Check the facts",
        signature: "encrypted-meta-reasoning",
        encrypted?: true,
        provider: :meta,
        format: "openai-responses-v1",
        index: 0,
        provider_data: %{"id" => "rs_meta_1", "type" => "reasoning"}
      }

      context = %ReqLLM.Context{
        messages: [
          %Message{role: :user, content: [%ContentPart{type: :text, text: "Question"}]},
          %Message{
            role: :assistant,
            content: [%ContentPart{type: :text, text: "Working"}],
            reasoning_details: [reasoning_detail]
          }
        ]
      }

      request = %Req.Request{
        options: [context: context, model: "muse-spark-1.1"],
        private: %{req_llm_model: meta_model()}
      }

      body = request |> Meta.encode_body() |> ReqLLM.Test.Helpers.json_body()

      assert [reasoning | _input] = body["input"]
      assert reasoning["type"] == "reasoning"
      assert reasoning["id"] == "rs_meta_1"
      assert reasoning["encrypted_content"] == "encrypted-meta-reasoning"
    end
  end

  describe "authentication and streaming" do
    test "attach adds bearer authentication and Responses pipeline steps" do
      attached = Meta.attach(Req.new(), meta_model(), [])

      assert ["Bearer test-key-12345"] = attached.headers["authorization"]
      assert :llm_encode_body in Keyword.keys(attached.request_steps)
      assert :llm_decode_response in Keyword.keys(attached.response_steps)
    end

    test "attach_stream builds a stateless Meta Responses request" do
      {:ok, request} =
        Meta.attach_stream(
          meta_model(),
          context_fixture(),
          [
            max_tokens: 128,
            reasoning_effort: :low,
            provider_options: [prompt_cache_retention: "in_memory"]
          ],
          ReqLLM.Finch
        )

      assert request.method == "POST"
      assert request.path == "/v1/responses"
      assert Map.new(request.headers)["Authorization"] == "Bearer test-key-12345"

      decoded = Jason.decode!(request.body)
      assert decoded["stream"] == true
      assert decoded["max_output_tokens"] == 128
      assert decoded["reasoning"] == %{"effort" => "low"}
      assert decoded["prompt_cache_retention"] == "in_memory"
      assert decoded["store"] == false
      assert decoded["include"] == ["reasoning.encrypted_content"]
      refute Map.has_key?(decoded, "max_tokens")
    end

    test "attach_stream uses the wire model ID from explicit model specs" do
      model = %{meta_model() | id: "friendly-name", provider_model_id: "muse-spark-wire-id"}

      {:ok, request} =
        Meta.attach_stream(
          model,
          context_fixture(),
          [base_url: "https://proxy.example/v1/"],
          ReqLLM.Finch
        )

      assert request.path == "/v1/responses"
      assert Jason.decode!(request.body)["model"] == "muse-spark-wire-id"
    end
  end

  describe "response decoding" do
    test "decode_response materializes Meta reasoning and usage" do
      body = %{
        "id" => "resp_meta_1",
        "model" => "muse-spark-1.1",
        "status" => "completed",
        "output" => [
          %{
            "id" => "rs_meta_1",
            "type" => "reasoning",
            "summary" => [%{"type" => "summary_text", "text" => "Think carefully."}],
            "encrypted_content" => "encrypted-meta-reasoning"
          },
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "The answer is 42."}]
          }
        ],
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 8,
          "output_tokens_details" => %{"reasoning_tokens" => 3}
        }
      }

      request = %Req.Request{
        options: [
          context: context_fixture(),
          model: "muse-spark-1.1",
          operation: :chat,
          stream: false
        ],
        private: %{req_llm_model: meta_model()}
      }

      {_request, response} =
        Meta.decode_response({request, %Req.Response{status: 200, body: body}})

      assert %ReqLLM.Response{} = response.body
      assert ReqLLM.Response.text(response.body) == "The answer is 42."
      assert ReqLLM.Response.thinking(response.body) == "Think carefully."
      assert response.body.usage.input_tokens == 10
      assert response.body.usage.output_tokens == 8
      assert response.body.usage.reasoning_tokens == 3
      assert [%ReasoningDetails{provider: :meta}] = response.body.message.reasoning_details
    end

    test "decode_stream_event preserves Meta reasoning identity" do
      event = %{
        data: %{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_meta_1",
            "output" => [
              %{
                "id" => "rs_meta_1",
                "type" => "reasoning",
                "encrypted_content" => "encrypted-meta-reasoning"
              }
            ]
          }
        }
      }

      assert [%ReqLLM.StreamChunk{type: :meta, metadata: metadata}] =
               Meta.decode_stream_event(event, meta_model())

      assert metadata.terminal? == true
      assert [%ReasoningDetails{provider: :meta}] = metadata.reasoning_details
    end
  end
end

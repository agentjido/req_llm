defmodule ReqLLM.Providers.FireworksAITest do
  @moduledoc """
  Provider-level tests for Fireworks AI implementation.

  Verifies the OpenAI-compatible request/response pipeline, the Fireworks
  base URL, and the encoding of Fireworks-specific options.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.FireworksAI

  alias ReqLLM.Providers.FireworksAI

  describe "provider contract" do
    test "provider identity and configuration" do
      assert FireworksAI.provider_id() == :fireworks_ai
      assert FireworksAI.base_url() == "https://api.fireworks.ai/inference/v1"
      assert FireworksAI.default_env_key() == "FIREWORKS_API_KEY"
    end

    test "provider_extended_generation_schema includes all core keys" do
      extended_schema = FireworksAI.provider_extended_generation_schema()
      extended_keys = extended_schema.schema |> Keyword.keys()

      core_keys = ReqLLM.Provider.Options.all_generation_keys()
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))

      for core_key <- core_without_meta do
        assert core_key in extended_keys,
               "Extended schema missing core key: #{core_key}"
      end
    end

    test "provider schema exposes Fireworks-specific options" do
      schema_keys = FireworksAI.provider_schema().schema |> Keyword.keys()

      assert :prompt_cache_key in schema_keys
      assert :prompt_truncate_len in schema_keys
      assert :min_p in schema_keys
      assert :repetition_penalty in schema_keys
      assert :speculation in schema_keys
      assert :fireworks_reasoning_effort in schema_keys
    end
  end

  describe "request preparation" do
    test "prepare_request for :chat creates /chat/completions request" do
      {:ok, model} =
        ReqLLM.model("fireworks_ai:accounts/fireworks/models/kimi-k2-instruct")

      {:ok, request} = FireworksAI.prepare_request(:chat, model, "Hello", temperature: 0.7)

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
      assert request.options[:base_url] == "https://api.fireworks.ai/inference/v1"
    end
  end

  describe "authentication wiring" do
    test "attach adds Bearer authorization header and pipeline steps" do
      {:ok, model} =
        ReqLLM.model("fireworks_ai:accounts/fireworks/models/kimi-k2-instruct")

      request = FireworksAI.attach(Req.new(), model, [])

      auth_header = request.headers["authorization"]
      assert auth_header != nil
      assert String.starts_with?(List.first(auth_header), "Bearer ")

      assert :llm_encode_body in Keyword.keys(request.request_steps)
      assert :llm_decode_response in Keyword.keys(request.response_steps)
    end
  end

  describe "body encoding" do
    test "encode_body produces valid OpenAI-compatible JSON with Fireworks extras" do
      {:ok, model} =
        ReqLLM.model("fireworks_ai:accounts/fireworks/models/kimi-k2-instruct")

      {:ok, request} =
        FireworksAI.prepare_request(:chat, model, "Hello",
          temperature: 0.5,
          max_tokens: 50,
          reasoning_effort: :high,
          min_p: 0.05,
          repetition_penalty: 1.1,
          prompt_cache_key: "user-42",
          prompt_truncate_len: 4000,
          safe_tokenization: true
        )

      encoded = FireworksAI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["model"] == "accounts/fireworks/models/kimi-k2-instruct"
      assert is_list(body["messages"])
      assert body["temperature"] == 0.5
      assert body["max_tokens"] == 50
      assert body["reasoning_effort"] == "high"
      assert body["min_p"] == 0.05
      assert body["repetition_penalty"] == 1.1
      assert body["prompt_cache_key"] == "user-42"
      assert body["prompt_truncate_len"] == 4000
      assert body["safe_tokenization"] == true
    end

    test "encode_body omits Fireworks extras when not provided" do
      {:ok, model} =
        ReqLLM.model("fireworks_ai:accounts/fireworks/models/kimi-k2-instruct")

      {:ok, request} = FireworksAI.prepare_request(:chat, model, "Hello", temperature: 0.0)

      encoded = FireworksAI.encode_body(request)
      body = Jason.decode!(encoded.body)

      refute Map.has_key?(body, "min_p")
      refute Map.has_key?(body, "reasoning_effort")
      refute Map.has_key?(body, "prompt_cache_key")
      refute Map.has_key?(body, "metadata")
    end

    test "encode_body strips reasoning_details, reasoning_content, and metadata from messages" do
      {:ok, model} =
        ReqLLM.model("fireworks_ai:accounts/fireworks/models/kimi-k2-instruct")

      assistant_with_extras = %ReqLLM.Message{
        role: :assistant,
        content: [
          %ReqLLM.Message.ContentPart{type: :thinking, text: "Let me think step by step."},
          %ReqLLM.Message.ContentPart{type: :text, text: "ok"}
        ],
        metadata: %{trace_id: "abc"},
        reasoning_details: [
          %ReqLLM.Message.ReasoningDetails{
            index: 0,
            format: "openai-reasoning-content-v1",
            text: "Let",
            provider: :fireworks_ai
          }
        ]
      }

      context = %ReqLLM.Context{
        messages: [
          assistant_with_extras,
          %ReqLLM.Message{
            role: :user,
            content: [%ReqLLM.Message.ContentPart{type: :text, text: "Continue?"}]
          }
        ]
      }

      {:ok, request} = FireworksAI.prepare_request(:chat, model, context, temperature: 0.0)
      body = Jason.decode!(FireworksAI.encode_body(request).body)

      for msg <- body["messages"] do
        refute Map.has_key?(msg, "metadata"),
               "metadata must be stripped (Fireworks rejects extra fields)"

        refute Map.has_key?(msg, "reasoning_details"),
               "reasoning_details must be stripped (Fireworks rejects extra fields)"

        refute Map.has_key?(msg, "reasoning_content"),
               "reasoning_content must be stripped (Fireworks rejects extra fields)"
      end
    end

    test "encode_body forwards tools using OpenAI shape" do
      {:ok, model} =
        ReqLLM.model("fireworks_ai:accounts/fireworks/models/kimi-k2-instruct")

      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get the weather",
          parameter_schema: [
            location: [type: :string, required: true, doc: "City name"]
          ],
          callback: fn _ -> {:ok, "sunny"} end
        )

      {:ok, request} = FireworksAI.prepare_request(:chat, model, "Hi", tools: [tool])

      encoded = FireworksAI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert is_list(body["tools"])
      assert hd(body["tools"])["function"]["name"] == "get_weather"
    end
  end

  describe "translate_options/3" do
    test "drops reasoning_token_budget (unsupported)" do
      model = %LLMDB.Model{provider: :fireworks_ai, id: "any"}

      {translated, []} =
        FireworksAI.translate_options(:chat, model, reasoning_token_budget: 1024)

      refute Keyword.has_key?(translated, :reasoning_token_budget)
    end

    test "caps non-streaming max_tokens to 4096 and warns" do
      model = %LLMDB.Model{provider: :fireworks_ai, id: "any"}

      {translated, warnings} =
        FireworksAI.translate_options(:chat, model, max_tokens: 25_000, stream: false)

      assert Keyword.get(translated, :max_tokens) == 4096
      assert [warning] = warnings
      assert warning =~ "max_tokens > 4096"
    end

    test "leaves streaming max_tokens untouched" do
      model = %LLMDB.Model{provider: :fireworks_ai, id: "any"}

      {translated, []} =
        FireworksAI.translate_options(:chat, model, max_tokens: 25_000, stream: true)

      assert Keyword.get(translated, :max_tokens) == 25_000
    end

    test "leaves reasoning_effort untouched (rendered at body build time)" do
      model = %LLMDB.Model{provider: :fireworks_ai, id: "any"}

      {translated, []} =
        FireworksAI.translate_options(:chat, model, reasoning_effort: :low)

      assert Keyword.get(translated, :reasoning_effort) == :low
    end
  end

  describe "reasoning_effort rendering" do
    test "atoms are rendered to Fireworks string values in the encoded body" do
      {:ok, model} =
        ReqLLM.model("fireworks_ai:accounts/fireworks/models/kimi-k2-instruct")

      for {atom_value, expected} <- [
            {:none, "none"},
            {:minimal, "low"},
            {:low, "low"},
            {:medium, "medium"},
            {:high, "high"},
            {:xhigh, "xhigh"}
          ] do
        {:ok, request} =
          FireworksAI.prepare_request(:chat, model, "Hi", reasoning_effort: atom_value)

        encoded = FireworksAI.encode_body(request)
        body = Jason.decode!(encoded.body)
        assert body["reasoning_effort"] == expected
      end
    end

    test "provider_options reasoning_effort max renders Fireworks native value" do
      {:ok, model} =
        ReqLLM.model("fireworks_ai:accounts/fireworks/models/kimi-k2-instruct")

      {:ok, request} =
        FireworksAI.prepare_request(:chat, model, "Hi",
          provider_options: [reasoning_effort: "max"]
        )

      encoded = FireworksAI.encode_body(request)
      body = Jason.decode!(encoded.body)
      assert body["reasoning_effort"] == "max"
    end

    test ":default is omitted from the body" do
      {:ok, model} =
        ReqLLM.model("fireworks_ai:accounts/fireworks/models/kimi-k2-instruct")

      {:ok, request} =
        FireworksAI.prepare_request(:chat, model, "Hi", reasoning_effort: :default)

      encoded = FireworksAI.encode_body(request)
      body = Jason.decode!(encoded.body)
      refute Map.has_key?(body, "reasoning_effort")
    end
  end

  describe "tool_choice translation" do
    test "rewrites canonical tool_choice into OpenAI function shape" do
      {:ok, model} =
        ReqLLM.model("fireworks_ai:accounts/fireworks/models/kimi-k2-instruct")

      tool =
        ReqLLM.Tool.new!(
          name: "add",
          description: "Add two integers",
          parameter_schema: [a: [type: :integer, required: true]],
          callback: fn _ -> {:ok, 0} end
        )

      {:ok, request} =
        FireworksAI.prepare_request(:chat, model, "Hi",
          tools: [tool],
          tool_choice: %{type: "tool", name: "add"}
        )

      encoded = FireworksAI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["tool_choice"] == %{"type" => "function", "function" => %{"name" => "add"}}
    end
  end

  describe "extended parameter passthrough" do
    test "parallel_tool_calls and max_completion_tokens flow into body" do
      {:ok, model} =
        ReqLLM.model("fireworks_ai:accounts/fireworks/models/kimi-k2-instruct")

      {:ok, request} =
        FireworksAI.prepare_request(:chat, model, "Hi",
          parallel_tool_calls: true,
          max_completion_tokens: 500
        )

      encoded = FireworksAI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["parallel_tool_calls"] == true
      assert body["max_completion_tokens"] == 500
    end

    test "top_k flows from top-level and provider_options into body" do
      {:ok, model} =
        ReqLLM.model("fireworks_ai:accounts/fireworks/models/kimi-k2-instruct")

      {:ok, top_level_request} =
        FireworksAI.prepare_request(:chat, model, "Hi", top_k: 40)

      {:ok, nested_request} =
        FireworksAI.prepare_request(:chat, model, "Hi", provider_options: [top_k: 41])

      assert Jason.decode!(FireworksAI.encode_body(top_level_request).body)["top_k"] == 40
      assert Jason.decode!(FireworksAI.encode_body(nested_request).body)["top_k"] == 41
    end

    test "tool.strict flag is preserved in the encoded tool schema" do
      {:ok, model} =
        ReqLLM.model("fireworks_ai:accounts/fireworks/models/kimi-k2-instruct")

      tool =
        ReqLLM.Tool.new!(
          name: "add",
          description: "Add two integers",
          parameter_schema: [a: [type: :integer, required: true]],
          strict: true,
          callback: fn _ -> {:ok, 0} end
        )

      {:ok, request} = FireworksAI.prepare_request(:chat, model, "Hi", tools: [tool])

      encoded = FireworksAI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert hd(body["tools"])["function"]["strict"] == true
    end
  end

  describe "structured output (:object) modes" do
    setup do
      {:ok, model} =
        ReqLLM.model("fireworks_ai:accounts/fireworks/models/kimi-k2-instruct")

      {:ok, compiled} =
        ReqLLM.Schema.compile(
          name: [type: :string, required: true],
          age: [type: :pos_integer, required: true]
        )

      {:ok, model: model, compiled: compiled}
    end

    test "default :auto mode emits native response_format json_schema with strict enforcement",
         %{model: model, compiled: compiled} do
      {:ok, request} =
        FireworksAI.prepare_request(:object, model, "Make a person",
          compiled_schema: compiled,
          temperature: 0.0
        )

      body = Jason.decode!(FireworksAI.encode_body(request).body)
      refute Map.has_key?(body, "tools")

      assert %{
               "type" => "json_schema",
               "json_schema" => %{
                 "name" => "output_schema",
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

    test "fireworks_json_schema_strict: false leaves schema untouched", %{
      model: model,
      compiled: compiled
    } do
      {:ok, request} =
        FireworksAI.prepare_request(:object, model, "Make a person",
          compiled_schema: compiled,
          temperature: 0.0,
          fireworks_json_schema_strict: false
        )

      body = Jason.decode!(FireworksAI.encode_body(request).body)

      assert body["response_format"]["json_schema"]["strict"] == false
    end

    test "provider_options fireworks_json_schema_strict: false leaves schema untouched", %{
      model: model,
      compiled: compiled
    } do
      {:ok, request} =
        FireworksAI.prepare_request(:object, model, "Make a person",
          compiled_schema: compiled,
          temperature: 0.0,
          provider_options: [fireworks_json_schema_strict: false]
        )

      body = Jason.decode!(FireworksAI.encode_body(request).body)

      assert body["response_format"]["json_schema"]["strict"] == false
    end

    test ":tool mode falls back to tool-call workaround", %{model: model, compiled: compiled} do
      {:ok, request} =
        FireworksAI.prepare_request(:object, model, "Make a person",
          compiled_schema: compiled,
          temperature: 0.0,
          fireworks_structured_output_mode: :tool
        )

      body = Jason.decode!(FireworksAI.encode_body(request).body)

      refute Map.has_key?(body, "response_format")
      assert hd(body["tools"])["function"]["name"] == "structured_output"
      assert hd(body["tools"])["function"]["strict"] == true
      assert body["tool_choice"]["function"]["name"] == "structured_output"
      assert body["parallel_tool_calls"] == false
    end
  end

  describe "stream options" do
    test "include_usage is set on streaming requests" do
      {:ok, model} =
        ReqLLM.model("fireworks_ai:accounts/fireworks/models/kimi-k2-instruct")

      {:ok, request} = FireworksAI.prepare_request(:chat, model, "Hi", stream: true)

      encoded = FireworksAI.encode_body(request)
      body = Jason.decode!(encoded.body)

      assert body["stream"] == true
      assert body["stream_options"] == %{"include_usage" => true}
    end

    test "stream_options absent on non-streaming requests" do
      {:ok, model} =
        ReqLLM.model("fireworks_ai:accounts/fireworks/models/kimi-k2-instruct")

      {:ok, request} = FireworksAI.prepare_request(:chat, model, "Hi", stream: false)

      encoded = FireworksAI.encode_body(request)
      body = Jason.decode!(encoded.body)

      refute Map.has_key?(body, "stream_options")
    end
  end

  describe "response decoding" do
    test "decode_response parses OpenAI-format response" do
      mock_resp = %Req.Response{
        status: 200,
        body:
          openai_format_json_fixture(
            model: "accounts/fireworks/models/kimi-k2-instruct",
            content: "Hello from Fireworks!"
          )
      }

      mock_req = %Req.Request{
        options: [
          context: context_fixture(),
          model: "accounts/fireworks/models/kimi-k2-instruct",
          operation: :chat
        ]
      }

      {_req, decoded} = FireworksAI.decode_response({mock_req, mock_resp})

      assert %ReqLLM.Response{} = decoded.body
      assert ReqLLM.Response.text(decoded.body) == "Hello from Fireworks!"
    end
  end
end

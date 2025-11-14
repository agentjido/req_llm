defmodule ReqLLM.Providers.XAITest do
  @moduledoc """
  Provider-level tests for xAI implementation.

  Tests the provider contract, capability detection, mode selection, and
  structured output infrastructure without making live API calls.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.XAI

  alias ReqLLM.Context
  alias ReqLLM.Providers.XAI

  @test_schema [
    name: [type: :string, required: true],
    age: [type: :integer, required: true]
  ]

  setup_all do
    compiled_schema = %{schema: @test_schema, name: "test_output"}
    {:ok, compiled_schema: compiled_schema}
  end

  describe "provider contract" do
    test "provider identity and configuration" do
      assert is_atom(XAI.provider_id())
      assert is_binary(XAI.base_url())
      assert String.starts_with?(XAI.base_url(), "http")
    end

    test "provider schema separation from core options" do
      schema_keys = XAI.provider_schema().schema |> Keyword.keys()
      core_keys = ReqLLM.Provider.Options.generation_schema().schema |> Keyword.keys()

      overlap = MapSet.intersection(MapSet.new(schema_keys), MapSet.new(core_keys))

      assert MapSet.size(overlap) == 0,
             "Schema overlap detected: #{inspect(MapSet.to_list(overlap))}"
    end

    test "provider schema combined with generation schema includes all core keys" do
      full_schema = XAI.provider_extended_generation_schema()
      full_keys = Keyword.keys(full_schema.schema)
      core_keys = ReqLLM.Provider.Options.all_generation_keys()

      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))
      missing = core_without_meta -- full_keys
      assert missing == [], "Missing core generation keys in extended schema: #{inspect(missing)}"
    end

    test "provider_extended_generation_schema includes both base and provider options" do
      extended_schema = XAI.provider_extended_generation_schema()
      extended_keys = extended_schema.schema |> Keyword.keys()

      core_keys = ReqLLM.Provider.Options.all_generation_keys()
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))

      for core_key <- core_without_meta do
        assert core_key in extended_keys,
               "Extended schema missing core key: #{core_key}"
      end

      provider_keys = XAI.provider_schema().schema |> Keyword.keys()

      for provider_key <- provider_keys do
        assert provider_key in extended_keys,
               "Extended schema missing provider key: #{provider_key}"
      end
    end
  end

  describe "capability detection - supports_native_structured_outputs?/1" do
    test "returns false for legacy grok-2 models" do
      assert XAI.supports_native_structured_outputs?("grok-2") == false
      assert XAI.supports_native_structured_outputs?("grok-2-vision") == false
      assert XAI.supports_native_structured_outputs?("grok-2-1111") == false

      {:ok, model} = ReqLLM.model("xai:grok-2")
      refute XAI.supports_native_structured_outputs?(model)
    end

    test "returns true for grok-2-1212+ models" do
      assert XAI.supports_native_structured_outputs?("grok-2-1212")
      assert XAI.supports_native_structured_outputs?("grok-2-1213")
      assert XAI.supports_native_structured_outputs?("grok-2-vision-1212")

      {:ok, model} = ReqLLM.model("xai:grok-2-1212")
      assert XAI.supports_native_structured_outputs?(model)
    end

    test "returns true for grok-3+ models" do
      assert XAI.supports_native_structured_outputs?("grok-3")
      assert XAI.supports_native_structured_outputs?("grok-4")
      assert XAI.supports_native_structured_outputs?("grok-beta")
    end

    test "prefers metadata flag over heuristic when present" do
      model_with_flag_true = %LLMDB.Model{
        provider: :xai,
        id: "grok-2",
        capabilities: %{native_json_schema: true}
      }

      assert XAI.supports_native_structured_outputs?(model_with_flag_true)

      model_with_flag_false = %LLMDB.Model{
        provider: :xai,
        id: "grok-3",
        capabilities: %{native_json_schema: false}
      }

      refute XAI.supports_native_structured_outputs?(model_with_flag_false)
    end

    test "supports_strict_tools?/1 returns true for all models" do
      assert XAI.supports_strict_tools?(%LLMDB.Model{provider: :xai, id: "grok-2"})
      assert XAI.supports_strict_tools?("grok-3")
    end
  end

  describe "mode selection - determine_output_mode/2 with :auto" do
    test "selects :json_schema for modern models without other tools" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      assert XAI.determine_output_mode(model, []) == :json_schema

      {:ok, model_beta} = ReqLLM.model("xai:grok-beta")
      assert XAI.determine_output_mode(model_beta, []) == :json_schema

      {:ok, model_2_1212} = ReqLLM.model("xai:grok-2-1212")
      assert XAI.determine_output_mode(model_2_1212, []) == :json_schema
    end

    test "selects :tool_strict for legacy models" do
      {:ok, model} = ReqLLM.model("xai:grok-2")
      assert XAI.determine_output_mode(model, []) == :tool_strict
    end

    test "selects :tool_strict when other tools present" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      other_tool = %{name: "other_function"}
      opts = [tools: [other_tool]]
      assert XAI.determine_output_mode(model, opts) == :tool_strict
    end

    test "selects :json_schema with only structured_output tool" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      structured_tool = %{name: "structured_output"}
      opts = [tools: [structured_tool]]
      assert XAI.determine_output_mode(model, opts) == :json_schema
    end

    test "handles empty tools list" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      assert XAI.determine_output_mode(model, tools: []) == :json_schema
    end

    test "handles ReqLLM.Tool struct" do
      {:ok, model} = ReqLLM.model("xai:grok-3")

      tool_struct = %ReqLLM.Tool{
        name: "test_tool",
        description: "test",
        callback: fn _ -> {:ok, "result"} end
      }

      assert XAI.determine_output_mode(model, tools: [tool_struct]) == :tool_strict
    end
  end

  describe "mode selection - explicit mode override" do
    test "honors explicit :json_schema when supported" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      opts = [provider_options: [xai_structured_output_mode: :json_schema]]
      assert XAI.determine_output_mode(model, opts) == :json_schema
    end

    test "raises when explicit :json_schema on unsupported model" do
      {:ok, model} = ReqLLM.model("xai:grok-2")
      opts = [provider_options: [xai_structured_output_mode: :json_schema]]

      assert_raise ArgumentError, ~r/does not support :json_schema mode/, fn ->
        XAI.determine_output_mode(model, opts)
      end
    end

    test "honors explicit :tool_strict on any model" do
      {:ok, model_modern} = ReqLLM.model("xai:grok-3")
      opts = [provider_options: [xai_structured_output_mode: :tool_strict]]
      assert XAI.determine_output_mode(model_modern, opts) == :tool_strict

      {:ok, model_legacy} = ReqLLM.model("xai:grok-2")
      assert XAI.determine_output_mode(model_legacy, opts) == :tool_strict
    end

    test "raises on invalid explicit mode" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      opts = [provider_options: [xai_structured_output_mode: :invalid]]

      assert_raise ArgumentError, ~r/Invalid xai_structured_output_mode/, fn ->
        XAI.determine_output_mode(model, opts)
      end
    end
  end

  describe "mode selection - response_format forcing" do
    test "forces :json_schema when response_format has json_schema" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      opts = [response_format: %{json_schema: %{name: "test"}}]
      assert XAI.determine_output_mode(model, opts) == :json_schema
    end

    test "forces :json_schema even with other tools present" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      other_tool = %{name: "other_function"}

      opts = [
        response_format: %{json_schema: %{name: "test"}},
        tools: [other_tool]
      ]

      assert XAI.determine_output_mode(model, opts) == :json_schema
    end

    test "does not force json_schema for response_format without json_schema" do
      {:ok, model} = ReqLLM.model("xai:grok-2")
      opts = [response_format: %{type: "json_object"}]
      assert XAI.determine_output_mode(model, opts) == :tool_strict
    end
  end

  describe "prepare_request(:object) - routing" do
    test "routes to json_schema for grok-3", %{compiled_schema: schema} do
      {:ok, request} =
        XAI.prepare_request(:object, "xai:grok-3", "Generate data", compiled_schema: schema)

      provider_options = request.options[:provider_options] || []
      assert Keyword.has_key?(provider_options, :response_format)
      assert provider_options[:response_format][:type] == "json_schema"
      refute Map.has_key?(request.options, :tools)
    end

    test "routes to tool_strict for grok-2", %{compiled_schema: schema} do
      {:ok, request} =
        XAI.prepare_request(:object, "xai:grok-2", "Generate data", compiled_schema: schema)

      tools = request.options[:tools]
      assert is_list(tools)
      assert Enum.any?(tools, &(&1.name == "structured_output"))
    end

    test "routes to tool_strict when other tools present", %{compiled_schema: schema} do
      other_tool = %ReqLLM.Tool{
        name: "other_tool",
        description: "test",
        callback: fn _ -> {:ok, "result"} end
      }

      {:ok, request} =
        XAI.prepare_request(:object, "xai:grok-3", "Generate data",
          compiled_schema: schema,
          tools: [other_tool]
        )

      tools = request.options[:tools]
      assert length(tools) == 2
      assert Enum.any?(tools, &(&1.name == "structured_output"))
      assert Enum.any?(tools, &(&1.name == "other_tool"))
    end

    test "honors explicit mode overrides", %{compiled_schema: schema} do
      {:ok, request_json} =
        XAI.prepare_request(:object, "xai:grok-3", "Generate data",
          compiled_schema: schema,
          provider_options: [xai_structured_output_mode: :json_schema]
        )

      provider_options = request_json.options[:provider_options] || []
      assert Keyword.has_key?(provider_options, :response_format)

      {:ok, request_tool} =
        XAI.prepare_request(:object, "xai:grok-3", "Generate data",
          compiled_schema: schema,
          provider_options: [xai_structured_output_mode: :tool_strict]
        )

      tools = request_tool.options[:tools]
      assert Enum.any?(tools, &(&1.name == "structured_output"))
    end
  end

  describe "json_schema request structure" do
    setup %{compiled_schema: schema} do
      {:ok, request} =
        XAI.prepare_request(:object, "xai:grok-3", "Generate data", compiled_schema: schema)

      {:ok, request: request}
    end

    test "includes correct response_format structure", %{request: request} do
      provider_options = request.options[:provider_options] || []
      response_format = provider_options[:response_format]

      assert response_format[:type] == "json_schema"
      assert response_format[:json_schema][:name] == "test_output"
      assert response_format[:json_schema][:strict] == true
      assert response_format[:json_schema][:schema]["type"] == "object"
    end

    test "sets parallel_tool_calls to false", %{request: request} do
      provider_options = request.options[:provider_options] || []
      assert provider_options[:parallel_tool_calls] == false
    end

    test "removes tools and tool_choice from options", %{request: request} do
      refute Map.has_key?(request.options, :tools)
      refute Map.has_key?(request.options, :tool_choice)
    end

    test "sets operation to :object", %{request: request} do
      assert request.options[:operation] == :object
    end

    test "preserves other options", %{compiled_schema: schema} do
      {:ok, request} =
        XAI.prepare_request(:object, "xai:grok-3", "Generate data",
          compiled_schema: schema,
          max_tokens: 1000,
          temperature: 0.5
        )

      max_tokens =
        request.options[:max_completion_tokens] || request.options[:max_tokens]

      assert max_tokens == 1000
      assert request.options[:temperature] == 0.5
    end
  end

  describe "tool_strict request structure" do
    setup %{compiled_schema: schema} do
      {:ok, request} =
        XAI.prepare_request(:object, "xai:grok-2", "Generate data", compiled_schema: schema)

      {:ok, request: request}
    end

    test "includes structured_output tool with strict mode", %{request: request} do
      tools = request.options[:tools]
      structured_tool = Enum.find(tools, &(&1.name == "structured_output"))

      assert structured_tool
      assert structured_tool.strict == true
    end

    test "forces tool_choice to structured_output", %{request: request} do
      tool_choice = request.options[:tool_choice]
      assert tool_choice[:type] == "function"
      assert tool_choice[:function][:name] == "structured_output"
    end

    test "sets parallel_tool_calls to false", %{request: request} do
      provider_options = request.options[:provider_options] || []
      assert provider_options[:parallel_tool_calls] == false
    end

    test "preserves existing tools", %{compiled_schema: schema} do
      other_tool = %ReqLLM.Tool{
        name: "other_tool",
        description: "test",
        callback: fn _ -> {:ok, "result"} end
      }

      {:ok, request} =
        XAI.prepare_request(:object, "xai:grok-2", "Generate data",
          compiled_schema: schema,
          tools: [other_tool]
        )

      tools = request.options[:tools]
      assert length(tools) == 2
      assert Enum.any?(tools, &(&1.name == "structured_output"))
      assert Enum.any?(tools, &(&1.name == "other_tool"))
    end
  end

  describe "token limit enforcement" do
    test "sets default max_tokens to 4096 when not specified", %{compiled_schema: schema} do
      {:ok, request} =
        XAI.prepare_request(:object, "xai:grok-3", "Generate data", compiled_schema: schema)

      max_tokens = request.options[:max_completion_tokens] || request.options[:max_tokens]
      assert max_tokens == 4096
    end

    test "enforces minimum 200 tokens", %{compiled_schema: schema} do
      {:ok, request} =
        XAI.prepare_request(:object, "xai:grok-3", "Generate data",
          compiled_schema: schema,
          max_tokens: 50
        )

      max_tokens = request.options[:max_completion_tokens] || request.options[:max_tokens]
      assert max_tokens >= 200
    end

    test "preserves adequate max_tokens value", %{compiled_schema: schema} do
      {:ok, request} =
        XAI.prepare_request(:object, "xai:grok-3", "Generate data",
          compiled_schema: schema,
          max_tokens: 2048
        )

      max_tokens = request.options[:max_completion_tokens] || request.options[:max_tokens]
      assert max_tokens == 2048
    end
  end

  describe "schema naming" do
    test "uses schema name from compiled_schema", %{compiled_schema: schema} do
      {:ok, request} =
        XAI.prepare_request(:object, "xai:grok-3", "Generate data", compiled_schema: schema)

      provider_options = request.options[:provider_options] || []
      json_schema = provider_options[:response_format][:json_schema]
      assert json_schema[:name] == "test_output"
    end

    test "defaults to output_schema when name not provided" do
      compiled_schema_no_name = %{schema: @test_schema}

      {:ok, request} =
        XAI.prepare_request(:object, "xai:grok-3", "Generate data",
          compiled_schema: compiled_schema_no_name
        )

      provider_options = request.options[:provider_options] || []
      json_schema = provider_options[:response_format][:json_schema]
      assert json_schema[:name] == "output_schema"
    end
  end

  describe "request preparation & pipeline wiring" do
    test "prepare_request creates configured request for :chat" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      context = context_fixture()
      opts = [temperature: 0.7, max_tokens: 100]

      {:ok, request} = XAI.prepare_request(:chat, model, context, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
    end

    test "attach configures authentication and pipeline" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      opts = [temperature: 0.5, max_tokens: 50]

      request = Req.new() |> XAI.attach(model, opts)

      assert request.headers["authorization"] |> Enum.any?(&String.starts_with?(&1, "Bearer "))

      request_steps = Keyword.keys(request.request_steps)
      response_steps = Keyword.keys(request.response_steps)

      assert :llm_encode_body in request_steps
      assert :llm_decode_response in response_steps
    end

    test "rejects unsupported operations" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      context = context_fixture()

      {:error, error} = XAI.prepare_request(:embedding, model, context, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error
      assert error.parameter =~ "operation: :embedding not supported"
    end

    test "rejects provider mismatch" do
      {:ok, wrong_model} = ReqLLM.model("openai:gpt-4")

      assert_raise ReqLLM.Error.Invalid.Provider, fn ->
        Req.new() |> XAI.attach(wrong_model, [])
      end
    end
  end

  describe "body encoding" do
    test "encode_body with minimal context" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      updated_request = XAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "grok-3"
      assert is_list(decoded["messages"])
      assert decoded["stream"] == false
      refute Map.has_key?(decoded, "tools")
    end

    test "encode_body with tools" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "test_tool",
          description: "A test tool",
          parameter_schema: [name: [type: :string, required: true]],
          callback: fn _ -> {:ok, "result"} end
        )

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          tools: [tool],
          tool_choice: %{type: "function", function: %{name: "test_tool"}}
        ]
      }

      updated_request = XAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert is_list(decoded["tools"])
      assert decoded["tool_choice"]["function"]["name"] == "test_tool"
    end

    test "encode_body with response_format" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          response_format: %{type: "json_object"}
        ]
      }

      updated_request = XAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["response_format"] == %{"type" => "json_object"}
    end

    test "encode_body with xAI-specific options" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          parallel_tool_calls: false,
          max_completion_tokens: 1024,
          reasoning_effort: "low",
          search_parameters: %{mode: "on"}
        ]
      }

      updated_request = XAI.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["parallel_tool_calls"] == false
      assert decoded["max_completion_tokens"] == 1024
      assert decoded["reasoning_effort"] == "low"
      assert decoded["search_parameters"]["mode"] == "on"
    end
  end

  describe "translate_options" do
    test "translates max_tokens to max_completion_tokens with warning" do
      {:ok, model} = ReqLLM.model("xai:grok-4")
      opts = [temperature: 0.7, max_tokens: 1000]
      {translated_opts, warnings} = XAI.translate_options(:chat, model, opts)

      assert Keyword.get(translated_opts, :max_completion_tokens) == 1000
      refute Keyword.has_key?(translated_opts, :max_tokens)
      assert length(warnings) == 1
      assert hd(warnings) =~ "max_completion_tokens"
    end

    test "handles web_search_options -> search_parameters alias" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      opts = [web_search_options: %{mode: "auto"}]
      {translated_opts, warnings} = XAI.translate_options(:chat, model, opts)

      assert Keyword.get(translated_opts, :search_parameters) == %{mode: "auto"}
      refute Keyword.has_key?(translated_opts, :web_search_options)
      assert length(warnings) == 1
    end

    test "removes unsupported parameters with warnings" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      opts = [temperature: 0.7, logit_bias: %{"123" => 10}, service_tier: "auto"]
      {translated_opts, warnings} = XAI.translate_options(:chat, model, opts)

      refute Keyword.has_key?(translated_opts, :logit_bias)
      refute Keyword.has_key?(translated_opts, :service_tier)
      assert Keyword.get(translated_opts, :temperature) == 0.7
      assert length(warnings) == 2
    end

    test "validates reasoning_effort model compatibility" do
      {:ok, grok_3_mini} = ReqLLM.model("xai:grok-3-mini")
      opts = [reasoning_effort: "high"]
      {translated_opts, warnings} = XAI.translate_options(:chat, grok_3_mini, opts)

      assert Keyword.get(translated_opts, :reasoning_effort) == "high"
      assert warnings == []

      {:ok, grok_4} = ReqLLM.model("xai:grok-4")
      {translated_opts, warnings} = XAI.translate_options(:chat, grok_4, opts)

      refute Keyword.has_key?(translated_opts, :reasoning_effort)
      assert length(warnings) == 1
      assert hd(warnings) =~ "Grok-4"
    end
  end

  describe "usage extraction" do
    test "extract_usage with valid usage data" do
      {:ok, model} = ReqLLM.model("xai:grok-3")

      body_with_usage = %{
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 20,
          "total_tokens" => 30
        }
      }

      {:ok, usage} = XAI.extract_usage(body_with_usage, model)
      assert usage["prompt_tokens"] == 10
      assert usage["completion_tokens"] == 20
      assert usage["total_tokens"] == 30
    end

    test "extract_usage with missing usage data" do
      {:ok, model} = ReqLLM.model("xai:grok-3")
      body_without_usage = %{"choices" => []}

      {:error, :no_usage_found} = XAI.extract_usage(body_without_usage, model)
    end

    test "extract_usage with invalid body type" do
      {:ok, model} = ReqLLM.model("xai:grok-3")

      {:error, :invalid_body} = XAI.extract_usage("invalid", model)
      {:error, :invalid_body} = XAI.extract_usage(nil, model)
    end
  end

  describe "context validation" do
    test "multiple system messages should fail" do
      invalid_context =
        Context.new([
          Context.system("System 1"),
          Context.system("System 2"),
          Context.user("Hello")
        ])

      assert_raise ReqLLM.Error.Validation.Error,
                   ~r/should have at most one system message/,
                   fn ->
                     Context.validate!(invalid_context)
                   end
    end
  end
end

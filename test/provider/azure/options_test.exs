defmodule ReqLLM.Providers.Azure.OptionsTest do
  @moduledoc """
  Tests for Azure provider option handling.

  Covers:
  - Warning messages for option misuse
  - Cross-family option interactions (OpenAI vs Anthropic)
  - Provider option validation
  - n parameter (multiple completions)
  - API version validation
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Azure

  describe "warning messages" do
    import ExUnit.CaptureLog

    test "warns when deployment is not specified" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      log =
        capture_log(fn ->
          Azure.prepare_request(
            :chat,
            model,
            "Hello",
            base_url: "https://my-resource.openai.azure.com/openai"
          )
        end)

      assert log =~ "No deployment specified"
      assert log =~ "gpt-4o"
    end

    test "does not warn when deployment is specified" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      log =
        capture_log(fn ->
          Azure.prepare_request(
            :chat,
            model,
            "Hello",
            base_url: "https://my-resource.openai.azure.com/openai",
            deployment: "my-deployment"
          )
        end)

      refute log =~ "No deployment specified"
    end

    test "does not warn about service_tier for OpenAI models" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      log =
        capture_log(fn ->
          Azure.prepare_request(
            :chat,
            model,
            "Hello",
            base_url: "https://my-resource.openai.azure.com/openai",
            deployment: "my-deployment",
            provider_options: [service_tier: "priority"]
          )
        end)

      refute log =~ "service_tier is only supported"
    end
  end

  describe "cross-family option interactions" do
    import ExUnit.CaptureLog

    test "anthropic_prompt_cache is ignored for OpenAI models" do
      {:ok, _model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      body = Azure.OpenAI.format_request("gpt-4o", context, anthropic_prompt_cache: true)

      refute Map.has_key?(body, "cache_control")
      refute Map.has_key?(body, :cache_control)
    end

    test "OpenAI n parameter is not passed to Claude formatter" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, stream: false, n: 3)

      refute Map.has_key?(body, :n)
      refute Map.has_key?(body, "n")
    end

    test "service_tier warns when used with Claude models" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      log =
        capture_log(fn ->
          Azure.Anthropic.pre_validate_options(
            :chat,
            model,
            provider_options: [service_tier: "priority"]
          )
        end)

      assert log =~ "service_tier"
      assert log =~ "OpenAI-specific"
    end

    test "response_format json_schema warns for Claude models" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      log =
        capture_log(fn ->
          {opts, _warnings} =
            Azure.Anthropic.pre_validate_options(
              :chat,
              model,
              response_format: %{type: "json_schema", json_schema: %{}}
            )

          refute Keyword.has_key?(opts, :response_format)
        end)

      assert log =~ "response_format"
      assert log =~ "json_schema"
      assert log =~ "not supported"
    end

    test "reasoning_effort is translated for Claude reasoning models" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{reasoning: %{enabled: true}}
      }

      {opts, _warnings} =
        Azure.Anthropic.pre_validate_options(:chat, model, reasoning_effort: :medium)

      provider_opts = opts[:provider_options] || []
      additional_fields = provider_opts[:additional_model_request_fields]

      assert additional_fields[:thinking][:type] == "enabled"
      assert additional_fields[:thinking][:budget_tokens] == 2048
    end

    test "reasoning_effort is ignored for Claude non-reasoning models with warning" do
      model = %LLMDB.Model{
        id: "claude-3-haiku-20240307",
        provider: :azure,
        capabilities: %{chat: true}
      }

      log =
        capture_log(fn ->
          {opts, _warnings} =
            Azure.Anthropic.pre_validate_options(:chat, model, reasoning_effort: :high)

          provider_opts = opts[:provider_options] || []
          refute Keyword.has_key?(provider_opts, :additional_model_request_fields)
        end)

      assert log =~ "Reasoning parameters ignored"
    end

    test "OpenAI reasoning_effort passes through for o1 models" do
      {:ok, model} = ReqLLM.model("azure:o1-mini")

      {opts, _warnings} =
        Azure.translate_options(
          :chat,
          model,
          provider_options: [reasoning_effort: "medium"]
        )

      provider_opts = opts[:provider_options] || []
      assert provider_opts[:reasoning_effort] == "medium"
    end

    test "n parameter is ignored for Claude models (OpenAI-specific)" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, stream: false, n: 3)

      refute Map.has_key?(body, :n)
      refute Map.has_key?(body, "n")
    end

    test "parallel_tool_calls is ignored for Claude models (OpenAI-specific)" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather info",
          parameter_schema: [location: [type: :string, required: true]],
          callback: fn _ -> {:ok, %{}} end
        )

      body =
        Azure.Anthropic.format_request(
          "claude-3-sonnet",
          context,
          stream: false,
          tools: [tool],
          parallel_tool_calls: true
        )

      refute Map.has_key?(body, :parallel_tool_calls)
      refute Map.has_key?(body, "parallel_tool_calls")
    end

    test "Anthropic thinking config is not applicable to OpenAI models" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      body =
        Azure.OpenAI.format_request(
          "gpt-4o",
          context,
          stream: false,
          thinking: %{type: "enabled", budget_tokens: 10_000}
        )

      refute Map.has_key?(body, :thinking)
      refute Map.has_key?(body, "thinking")
    end

    test "reasoning_token_budget (Anthropic-specific) is not applicable to OpenAI models" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      body =
        Azure.OpenAI.format_request(
          "gpt-4o",
          context,
          stream: false,
          reasoning_token_budget: 5000
        )

      refute Map.has_key?(body, :reasoning_token_budget)
      refute Map.has_key?(body, "reasoning_token_budget")
      refute Map.has_key?(body, :thinking)
    end
  end

  describe "provider option validation" do
    test "accepts valid api_version" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-resource.openai.azure.com/openai",
          deployment: "my-deployment",
          provider_options: [api_version: "2024-02-01"]
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "api-version=2024-02-01"
    end

    test "accepts valid service_tier values" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      for tier <- ["auto", "default", "priority"] do
        {:ok, _request} =
          Azure.prepare_request(
            :chat,
            model,
            "Hello",
            base_url: "https://my-resource.openai.azure.com/openai",
            deployment: "my-deployment",
            provider_options: [service_tier: tier]
          )
      end
    end

    test "rejects invalid service_tier values" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      assert_raise MatchError, fn ->
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-resource.openai.azure.com/openai",
          deployment: "my-deployment",
          provider_options: [service_tier: "invalid"]
        )
      end
    end

    test "accepts dimensions for embedding models" do
      model = %LLMDB.Model{
        id: "text-embedding-3-small",
        provider: :azure,
        capabilities: %{embeddings: true}
      }

      {:ok, request} =
        Azure.prepare_request(
          :embedding,
          model,
          "Hello",
          base_url: "https://my-resource.openai.azure.com/openai",
          deployment: "my-deployment",
          provider_options: [dimensions: 512]
        )

      assert %Req.Request{} = request
    end

    test "accepts encoding_format for embedding models" do
      model = %LLMDB.Model{
        id: "text-embedding-3-small",
        provider: :azure,
        capabilities: %{embeddings: true}
      }

      {:ok, request} =
        Azure.prepare_request(
          :embedding,
          model,
          "Hello",
          base_url: "https://my-resource.openai.azure.com/openai",
          deployment: "my-deployment",
          provider_options: [encoding_format: "base64"]
        )

      assert %Req.Request{} = request
    end

    test "embedding format_request includes dimensions" do
      body =
        Azure.OpenAI.format_embedding_request(
          "text-embedding-3-small",
          "Hello world",
          provider_options: [dimensions: 256]
        )

      assert body.input == "Hello world"
      assert body.dimensions == 256
    end

    test "embedding format_request includes encoding_format" do
      body =
        Azure.OpenAI.format_embedding_request(
          "text-embedding-3-small",
          "Hello world",
          provider_options: [encoding_format: "base64"]
        )

      assert body.input == "Hello world"
      assert body.encoding_format == "base64"
    end

    test "accepts anthropic_prompt_cache for Claude models" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          api_key: "test-key",
          base_url: "https://my-resource.openai.azure.com/openai",
          deployment: "my-deployment",
          provider_options: [anthropic_prompt_cache: true]
        )

      assert %Req.Request{} = request
    end

    test "accepts anthropic_prompt_cache_ttl for Claude models" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          api_key: "test-key",
          base_url: "https://my-resource.openai.azure.com/openai",
          deployment: "my-deployment",
          provider_options: [anthropic_prompt_cache: true, anthropic_prompt_cache_ttl: "1h"]
        )

      assert %Req.Request{} = request
    end
  end

  describe "n parameter (multiple completions)" do
    test "OpenAI formatter includes n parameter" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false, n: 3]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:n] == 3
    end

    test "n parameter defaults to 1 when not specified" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      refute Map.has_key?(body, :n)
    end

    test "parses response with multiple choices" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(url: "/test", method: :post)
        |> Req.Request.register_options([:context, :api_key, :base_url, :operation, :model])
        |> Req.Request.merge_options(context: context, operation: :chat, model: model.id)
        |> Azure.attach(model,
          api_key: "test-api-key",
          context: context,
          base_url: "https://my-resource.openai.azure.com/openai"
        )
        |> Req.Request.put_private(:model, model)

      body = %{
        "id" => "chatcmpl-123",
        "object" => "chat.completion",
        "model" => "gpt-4o",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => "Response 1"},
            "finish_reason" => "stop"
          },
          %{
            "index" => 1,
            "message" => %{"role" => "assistant", "content" => "Response 2"},
            "finish_reason" => "stop"
          },
          %{
            "index" => 2,
            "message" => %{"role" => "assistant", "content" => "Response 3"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 30, "total_tokens" => 40}
      }

      response = %Req.Response{status: 200, body: body}

      {_req, result} = Azure.decode_response({request, response})

      assert %Req.Response{body: %ReqLLM.Response{}} = result
    end

    test "Claude formatter does not include n parameter" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false, n: 3]

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, opts)

      refute Map.has_key?(body, :n)
      refute Map.has_key?(body, "n")
    end
  end

  describe "API version validation" do
    test "accepts standard API version format" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-resource.openai.azure.com/openai",
          provider_options: [api_version: "2024-02-01"]
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "api-version=2024-02-01"
    end

    test "accepts preview API version format" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-resource.openai.azure.com/openai",
          provider_options: [api_version: "2024-08-01-preview"]
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "api-version=2024-08-01-preview"
    end

    test "uses default API version when not specified" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-resource.openai.azure.com/openai"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "api-version="
    end
  end

  describe "Azure.OpenAI.pre_validate_options/3" do
    import ExUnit.CaptureLog

    test "warns and removes anthropic_prompt_cache (Anthropic-specific option)" do
      model = %LLMDB.Model{id: "gpt-4o", provider: :azure, capabilities: %{}}
      opts = [provider_options: [anthropic_prompt_cache: true]]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.OpenAI.pre_validate_options(:chat, model, opts)
          provider_opts = translated[:provider_options] || []
          refute Keyword.has_key?(provider_opts, :anthropic_prompt_cache)
        end)

      assert log =~ "anthropic_prompt_cache"
      assert log =~ "Anthropic-specific"
      assert log =~ "ignored for OpenAI models on Azure"
    end

    test "warns and removes anthropic_prompt_cache_ttl (Anthropic-specific option)" do
      model = %LLMDB.Model{id: "gpt-4o", provider: :azure, capabilities: %{}}
      opts = [provider_options: [anthropic_prompt_cache_ttl: "1h"]]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.OpenAI.pre_validate_options(:chat, model, opts)
          provider_opts = translated[:provider_options] || []
          refute Keyword.has_key?(provider_opts, :anthropic_prompt_cache_ttl)
        end)

      assert log =~ "anthropic_prompt_cache_ttl"
      assert log =~ "Anthropic-specific"
    end

    test "warns and removes anthropic_version (Anthropic-specific option)" do
      model = %LLMDB.Model{id: "gpt-4o", provider: :azure, capabilities: %{}}
      opts = [provider_options: [anthropic_version: "2023-06-01"]]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.OpenAI.pre_validate_options(:chat, model, opts)
          provider_opts = translated[:provider_options] || []
          refute Keyword.has_key?(provider_opts, :anthropic_version)
        end)

      assert log =~ "anthropic_version"
      assert log =~ "Anthropic-specific"
    end

    test "warns and removes multiple Anthropic options at once" do
      model = %LLMDB.Model{id: "gpt-4o", provider: :azure, capabilities: %{}}

      opts = [
        provider_options: [
          anthropic_prompt_cache: true,
          anthropic_prompt_cache_ttl: "1h",
          anthropic_version: "2023-06-01",
          service_tier: "priority"
        ]
      ]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.OpenAI.pre_validate_options(:chat, model, opts)
          provider_opts = translated[:provider_options] || []
          refute Keyword.has_key?(provider_opts, :anthropic_prompt_cache)
          refute Keyword.has_key?(provider_opts, :anthropic_prompt_cache_ttl)
          refute Keyword.has_key?(provider_opts, :anthropic_version)
          # service_tier should remain (it's valid for OpenAI)
          assert Keyword.has_key?(provider_opts, :service_tier)
        end)

      assert log =~ "Anthropic-specific"
    end

    test "warns and removes thinking config from additional_model_request_fields" do
      model = %LLMDB.Model{id: "gpt-4o", provider: :azure, capabilities: %{}}

      opts = [
        provider_options: [
          additional_model_request_fields: %{thinking: %{type: "enabled", budget_tokens: 10_000}}
        ]
      ]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.OpenAI.pre_validate_options(:chat, model, opts)
          provider_opts = translated[:provider_options] || []
          # additional_model_request_fields should be removed entirely (was only thinking)
          refute Keyword.has_key?(provider_opts, :additional_model_request_fields)
        end)

      assert log =~ "thinking config is Anthropic-specific"
      assert log =~ "ignored for OpenAI models on Azure"
      assert log =~ "use reasoning_effort instead"
    end

    test "preserves other fields in additional_model_request_fields when removing thinking" do
      model = %LLMDB.Model{id: "gpt-4o", provider: :azure, capabilities: %{}}

      opts = [
        provider_options: [
          additional_model_request_fields: %{
            thinking: %{type: "enabled"},
            other_field: "keep me"
          }
        ]
      ]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.OpenAI.pre_validate_options(:chat, model, opts)
          provider_opts = translated[:provider_options] || []
          amrf = provider_opts[:additional_model_request_fields]
          assert amrf != nil
          refute Map.has_key?(amrf, :thinking)
          assert amrf[:other_field] == "keep me"
        end)

      assert log =~ "thinking config is Anthropic-specific"
    end

    test "handles both Anthropic options and thinking config simultaneously" do
      model = %LLMDB.Model{id: "gpt-4o", provider: :azure, capabilities: %{}}

      opts = [
        provider_options: [
          anthropic_prompt_cache: true,
          additional_model_request_fields: %{thinking: %{type: "enabled"}}
        ]
      ]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.OpenAI.pre_validate_options(:chat, model, opts)
          provider_opts = translated[:provider_options] || []
          refute Keyword.has_key?(provider_opts, :anthropic_prompt_cache)
          refute Keyword.has_key?(provider_opts, :additional_model_request_fields)
        end)

      # Both warnings should be logged
      assert log =~ "anthropic_prompt_cache"
      assert log =~ "thinking config is Anthropic-specific"
    end

    test "does not warn when no Anthropic-specific options are present" do
      model = %LLMDB.Model{id: "gpt-4o", provider: :azure, capabilities: %{}}

      opts = [
        provider_options: [service_tier: "priority", response_format: %{type: "json_object"}]
      ]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.OpenAI.pre_validate_options(:chat, model, opts)
          provider_opts = translated[:provider_options] || []
          assert Keyword.has_key?(provider_opts, :service_tier)
          assert Keyword.has_key?(provider_opts, :response_format)
        end)

      refute log =~ "Anthropic-specific"
      refute log =~ "thinking config"
    end

    test "handles non-keyword-list provider_options gracefully" do
      model = %LLMDB.Model{id: "gpt-4o", provider: :azure, capabilities: %{}}
      # This shouldn't happen in practice, but the code should handle it
      opts = [provider_options: %{anthropic_prompt_cache: true}]

      # Should not crash
      {translated, _warnings} = Azure.OpenAI.pre_validate_options(:chat, model, opts)
      # Options are returned as-is since we can't process a map as keyword list
      assert translated[:provider_options] == %{anthropic_prompt_cache: true}
    end

    test "handles string keys in thinking config" do
      model = %LLMDB.Model{id: "gpt-4o", provider: :azure, capabilities: %{}}

      opts = [
        provider_options: [
          additional_model_request_fields: %{"thinking" => %{"type" => "enabled"}}
        ]
      ]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.OpenAI.pre_validate_options(:chat, model, opts)
          provider_opts = translated[:provider_options] || []
          refute Keyword.has_key?(provider_opts, :additional_model_request_fields)
        end)

      assert log =~ "thinking config is Anthropic-specific"
    end
  end

  describe "DeepSeek thinking support" do
    import ExUnit.CaptureLog

    test "pre_validate_options preserves thinking config for DeepSeek models" do
      model = %LLMDB.Model{id: "deepseek-v3.1", provider: :azure, capabilities: %{}}

      opts = [
        provider_options: [
          additional_model_request_fields: %{thinking: %{type: "enabled", budget_tokens: 10_000}}
        ]
      ]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.OpenAI.pre_validate_options(:chat, model, opts)
          provider_opts = translated[:provider_options] || []
          amrf = provider_opts[:additional_model_request_fields]
          assert amrf[:thinking] == %{type: "enabled", budget_tokens: 10_000}
        end)

      refute log =~ "thinking config is Anthropic-specific"
    end

    test "pre_validate_options still strips thinking config for non-DeepSeek OpenAI models" do
      model = %LLMDB.Model{id: "gpt-4o", provider: :azure, capabilities: %{}}

      opts = [
        provider_options: [
          additional_model_request_fields: %{thinking: %{type: "enabled"}}
        ]
      ]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.OpenAI.pre_validate_options(:chat, model, opts)
          provider_opts = translated[:provider_options] || []
          refute Keyword.has_key?(provider_opts, :additional_model_request_fields)
        end)

      assert log =~ "thinking config is Anthropic-specific"
    end

    test "pre_validate_options uses provider_model_id when available" do
      model = %LLMDB.Model{
        id: "some-alias",
        provider: :azure,
        provider_model_id: "deepseek-v3.1",
        capabilities: %{}
      }

      opts = [
        provider_options: [
          additional_model_request_fields: %{thinking: %{type: "enabled"}}
        ]
      ]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.OpenAI.pre_validate_options(:chat, model, opts)
          provider_opts = translated[:provider_options] || []
          amrf = provider_opts[:additional_model_request_fields]
          assert amrf[:thinking] == %{type: "enabled"}
        end)

      refute log =~ "thinking config is Anthropic-specific"
    end

    test "format_request does not add thinking by default for DeepSeek models" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      body = Azure.OpenAI.format_request("deepseek-v3.1", context, stream: false)

      refute Map.has_key?(body, :thinking)
    end

    test "format_request includes user-provided thinking config for DeepSeek models" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      body =
        Azure.OpenAI.format_request(
          "deepseek-v3.1",
          context,
          stream: false,
          provider_options: [
            additional_model_request_fields: %{
              thinking: %{type: "enabled", budget_tokens: 20_000}
            }
          ]
        )

      assert body[:thinking] == %{type: "enabled", budget_tokens: 20_000}
    end

    test "format_request allows disabling thinking for DeepSeek models" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      body =
        Azure.OpenAI.format_request(
          "deepseek-v3.1",
          context,
          stream: false,
          provider_options: [
            additional_model_request_fields: %{thinking: nil}
          ]
        )

      refute Map.has_key?(body, :thinking)
    end

    test "format_request does not add thinking for non-DeepSeek models" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      body = Azure.OpenAI.format_request("gpt-4o", context, stream: false)

      refute Map.has_key?(body, :thinking)
      refute Map.has_key?(body, "thinking")
    end
  end

  describe "deepseek_model?/1" do
    alias ReqLLM.Providers.OpenAI.AdapterHelpers

    test "returns true for DeepSeek model IDs" do
      assert AdapterHelpers.deepseek_model?("deepseek-v3")
      assert AdapterHelpers.deepseek_model?("deepseek-v3.1")
      assert AdapterHelpers.deepseek_model?("deepseek-r1")
      assert AdapterHelpers.deepseek_model?("deepseek-r1-0528")
    end

    test "returns false for non-DeepSeek model IDs" do
      refute AdapterHelpers.deepseek_model?("gpt-4o")
      refute AdapterHelpers.deepseek_model?("mai-ds-r1")
      refute AdapterHelpers.deepseek_model?("o3-mini")
    end

    test "returns false for non-string inputs" do
      refute AdapterHelpers.deepseek_model?(nil)
      refute AdapterHelpers.deepseek_model?(123)
    end
  end
end

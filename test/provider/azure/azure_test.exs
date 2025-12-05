defmodule ReqLLM.Providers.AzureTest do
  @moduledoc """
  Unit tests for Azure provider implementation.

  Tests Azure-specific provider behaviors:
  - Deployment-based URL construction
  - api-key header authentication (not Bearer token)
  - API version handling
  - Model family routing (OpenAI vs Anthropic)
  - Option translation delegation
  - Base URL validation

  Does NOT test live API calls - see test/coverage/azure/ for integration tests.
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Azure

  describe "model lookup" do
    test "azure models are available from LLMDB" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      assert model.provider == :azure
      assert model.id == "gpt-4o"
    end

    test "provider is registered" do
      assert {:ok, Azure} = ReqLLM.provider(:azure)
    end
  end

  describe "prepare_request/4" do
    test "constructs URL with deployment from options" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          deployment: "my-gpt4-deployment",
          base_url: "https://my-resource.openai.azure.com/openai"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "/deployments/my-gpt4-deployment/chat/completions"
      assert url_string =~ "api-version="
    end

    test "uses model.id as default deployment when not specified" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-resource.openai.azure.com/openai"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "/deployments/gpt-4o/chat/completions"
    end

    test "uses custom api_version from provider_options" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-resource.openai.azure.com/openai",
          provider_options: [api_version: "2023-05-15"]
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "api-version=2023-05-15"
    end

    test "embedding operation uses correct endpoint" do
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
          deployment: "my-embedding-deployment",
          base_url: "https://my-resource.openai.azure.com/openai"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "/deployments/my-embedding-deployment/embeddings"
      assert url_string =~ "api-version="
    end

    test "embedding operation rejects non-embedding models" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Azure.prepare_request(
                 :embedding,
                 model,
                 "Hello",
                 deployment: "my-deployment",
                 base_url: "https://my-resource.openai.azure.com/openai"
               )
    end
  end

  describe "attach/3" do
    test "sets api-key header instead of Bearer token" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(url: "/test", method: :post)
        |> Req.Request.register_options([:context, :api_key, :base_url])
        |> Req.Request.merge_options(context: context)
        |> Azure.attach(model,
          api_key: "test-api-key",
          context: context,
          base_url: "https://my-resource.openai.azure.com/openai"
        )

      assert Req.Request.get_header(request, "api-key") == ["test-api-key"]
      refute Req.Request.get_header(request, "authorization") |> Enum.any?(&(&1 =~ "Bearer"))
    end

    test "sets content-type header" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      request =
        Req.new(url: "/test", method: :post)
        |> Req.Request.register_options([:context, :api_key, :base_url])
        |> Req.Request.merge_options(context: context)
        |> Azure.attach(model,
          api_key: "test-api-key",
          context: context,
          base_url: "https://my-resource.openai.azure.com/openai"
        )

      assert Req.Request.get_header(request, "content-type") == ["application/json"]
    end
  end

  describe "attach_stream/4" do
    test "builds Finch request with correct URL and headers" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "test-api-key",
            deployment: "my-deployment",
            base_url: "https://my-resource.openai.azure.com/openai"
          ],
          :req_llm_finch
        )

      assert %Finch.Request{} = finch_request

      url_string =
        case finch_request do
          %{path: path, query: query} when is_binary(query) and query != "" ->
            path <> "?" <> query

          %{path: path} ->
            path
        end

      assert url_string =~ "/deployments/my-deployment/chat/completions"
      assert url_string =~ "api-version="

      header_map = Map.new(finch_request.headers)
      assert header_map["api-key"] == "test-api-key"
      assert header_map["content-type"] == "application/json"
    end

    test "does not include anthropic-version header for OpenAI models" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "test-api-key",
            deployment: "my-deployment",
            base_url: "https://my-resource.openai.azure.com/openai"
          ],
          :req_llm_finch
        )

      header_map = Map.new(finch_request.headers)
      refute Map.has_key?(header_map, "anthropic-version")
    end

    test "includes anthropic-version header for Claude models" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "test-api-key",
            deployment: "claude-deployment",
            base_url: "https://my-resource.openai.azure.com/openai"
          ],
          :req_llm_finch
        )

      header_map = Map.new(finch_request.headers)
      assert Map.has_key?(header_map, "anthropic-version")
      assert header_map["anthropic-version"] == "2023-06-01"
    end

    test "allows custom anthropic_version header override" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "test-api-key",
            deployment: "claude-deployment",
            base_url: "https://my-resource.openai.azure.com/openai",
            anthropic_version: "2024-01-01"
          ],
          :req_llm_finch
        )

      header_map = Map.new(finch_request.headers)
      assert header_map["anthropic-version"] == "2024-01-01"
    end

    test "builds streaming request for Claude models with correct endpoint" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "test-api-key",
            deployment: "claude-deployment",
            base_url: "https://my-resource.openai.azure.com/openai"
          ],
          :req_llm_finch
        )

      url_string =
        case finch_request do
          %{path: path, query: query} when is_binary(query) and query != "" ->
            path <> "?" <> query

          %{path: path} ->
            path
        end

      assert url_string =~ "/v1/messages"
      refute url_string =~ "/chat/completions"
      refute url_string =~ "/deployments/"

      header_map = Map.new(finch_request.headers)
      assert header_map["x-api-key"] == "test-api-key"
      assert header_map["content-type"] == "application/json"
    end

    test "returns error when base_url is empty" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      result =
        Azure.attach_stream(
          model,
          context,
          [api_key: "test-key", deployment: "my-deployment", base_url: ""],
          :req_llm_finch
        )

      assert {:error, error} = result
      assert Exception.message(error) =~ "base_url"
    end

    test "returns error when api_key is empty" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      result =
        Azure.attach_stream(
          model,
          context,
          [
            base_url: "https://my-resource.openai.azure.com/openai",
            deployment: "my-deployment",
            api_key: ""
          ],
          :req_llm_finch
        )

      assert {:error, error} = result
      assert Exception.message(error) =~ "api_key" or Exception.message(error) =~ "API_KEY"
    end

    test "returns error for invalid provider" do
      model = %LLMDB.Model{
        id: "gpt-4o",
        provider: :openai,
        capabilities: %{chat: true}
      }

      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      result =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "test-key",
            base_url: "https://my-resource.openai.azure.com/openai",
            deployment: "my-deployment"
          ],
          :req_llm_finch
        )

      assert {:error, error} = result
      assert Exception.message(error) =~ "provider" or Exception.message(error) =~ "openai"
    end
  end

  describe "provider_schema" do
    test "api_version option has default value" do
      schema = Azure.provider_schema()
      api_version_spec = schema.schema[:api_version]

      assert api_version_spec[:type] == :string
      assert api_version_spec[:default] == "2025-04-01-preview"
    end

    test "deployment option is available" do
      schema = Azure.provider_schema()
      deployment_spec = schema.schema[:deployment]

      assert deployment_spec[:type] == :string
    end
  end

  describe "translate_options/3" do
    test "provider implements translate_options/3" do
      assert function_exported?(Azure, :translate_options, 3)
    end

    test "delegates to OpenAI for GPT models" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      opts = [temperature: 0.7, max_tokens: 1000]
      {translated_opts, warnings} = Azure.translate_options(:chat, model, opts)

      assert translated_opts == opts
      assert warnings == []
    end

    test "delegates to OpenAI for o1 reasoning models - translates max_tokens" do
      {:ok, model} = ReqLLM.model("azure:o1-mini")

      opts = [max_tokens: 1000, temperature: 0.7]
      {translated_opts, warnings} = Azure.translate_options(:chat, model, opts)

      assert translated_opts[:max_completion_tokens] == 1000
      refute Keyword.has_key?(translated_opts, :max_tokens)
      refute Keyword.has_key?(translated_opts, :temperature)
      assert length(warnings) == 2
    end

    test "delegates to OpenAI for o3 reasoning models - translates max_tokens" do
      {:ok, model} = ReqLLM.model("azure:o3-mini")

      opts = [max_tokens: 2000, temperature: 1.0]
      {translated_opts, warnings} = Azure.translate_options(:chat, model, opts)

      assert translated_opts[:max_completion_tokens] == 2000
      refute Keyword.has_key?(translated_opts, :max_tokens)
      refute Keyword.has_key?(translated_opts, :temperature)
      assert length(warnings) == 2
    end

    test "delegates to OpenAI for o4 reasoning models - translates max_tokens" do
      {:ok, model} = ReqLLM.model("azure:o4-mini")

      opts = [max_tokens: 3000, temperature: 0.8]
      {translated_opts, warnings} = Azure.translate_options(:chat, model, opts)

      assert translated_opts[:max_completion_tokens] == 3000
      refute Keyword.has_key?(translated_opts, :max_tokens)
      refute Keyword.has_key?(translated_opts, :temperature)
      assert length(warnings) == 2
    end

    test "passes through options unchanged for non-chat operations" do
      {:ok, model} = ReqLLM.model("azure:o1-mini")

      opts = [max_tokens: 1000, temperature: 0.7]
      {translated_opts, warnings} = Azure.translate_options(:embedding, model, opts)

      assert translated_opts == opts
      assert warnings == []
    end
  end

  describe "thinking_constraints/0" do
    test "returns :none since constraints are model-family specific" do
      assert Azure.thinking_constraints() == :none
    end
  end

  describe "credential_missing?/1" do
    test "returns true for missing AZURE_OPENAI_API_KEY" do
      error = %ArgumentError{message: "AZURE_OPENAI_API_KEY environment variable is not set"}
      assert Azure.credential_missing?(error)
    end

    test "returns true for missing api_key option" do
      error = %ArgumentError{message: "api_key must be provided"}
      assert Azure.credential_missing?(error)
    end

    test "returns false for other errors" do
      error = %ArgumentError{message: "some other error"}
      refute Azure.credential_missing?(error)
    end

    test "returns false for non-ArgumentError" do
      error = %RuntimeError{message: "AZURE_OPENAI_API_KEY not set"}
      refute Azure.credential_missing?(error)
    end
  end

  describe "authentication" do
    test "explicit api_key option takes precedence over environment variable" do
      original_env = System.get_env("AZURE_OPENAI_API_KEY")
      System.put_env("AZURE_OPENAI_API_KEY", "env-key")

      try do
        {:ok, model} = ReqLLM.model("azure:gpt-4o")
        context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

        {:ok, finch_request} =
          Azure.attach_stream(
            model,
            context,
            [
              api_key: "explicit-key",
              deployment: "my-deployment",
              base_url: "https://my-resource.openai.azure.com/openai"
            ],
            :req_llm_finch
          )

        header_map = Map.new(finch_request.headers)
        assert header_map["api-key"] == "explicit-key"
      after
        if original_env,
          do: System.put_env("AZURE_OPENAI_API_KEY", original_env),
          else: System.delete_env("AZURE_OPENAI_API_KEY")
      end
    end
  end

  describe "base_url validation" do
    test "raises error for empty base_url" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      assert_raise ArgumentError, ~r/Azure requires a base_url/, fn ->
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: ""
        )
      end
    end

    test "accepts custom base_url" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-actual-resource.openai.azure.com/openai"
        )

      assert %Req.Request{} = request
    end
  end

  describe "extract_usage/2" do
    test "extracts usage for OpenAI models" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      body = %{
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 20,
          "total_tokens" => 30
        }
      }

      {:ok, usage} = Azure.extract_usage(body, model)

      assert usage.input_tokens == 10
      assert usage.output_tokens == 20
      assert usage.total_tokens == 30
    end

    test "extracts reasoning tokens for o1 models" do
      {:ok, model} = ReqLLM.model("azure:o1-mini")

      body = %{
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 200,
          "total_tokens" => 300,
          "completion_tokens_details" => %{
            "reasoning_tokens" => 150
          }
        }
      }

      {:ok, usage} = Azure.extract_usage(body, model)

      assert usage.input_tokens == 100
      assert usage.output_tokens == 200
      assert usage.reasoning_tokens == 150
    end

    test "extracts usage for Claude models" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{chat: true}
      }

      body = %{
        "usage" => %{
          "input_tokens" => 15,
          "output_tokens" => 25
        }
      }

      {:ok, usage} = Azure.extract_usage(body, model)

      assert usage["input_tokens"] == 15
      assert usage["output_tokens"] == 25
    end

    test "returns error when no usage data" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      body = %{"choices" => []}

      assert {:error, _} = Azure.extract_usage(body, model)
    end
  end

  describe "encode_body/1" do
    test "is pass-through since formatters handle encoding" do
      request = %Req.Request{body: {:json, %{"key" => "value"}}}

      assert Azure.encode_body(request) == request
    end
  end

  describe "reasoning model features" do
    import ExUnit.CaptureLog

    test "OpenAI reasoning models use max_completion_tokens instead of max_tokens" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false, max_tokens: 1000]

      body = Azure.OpenAI.format_request("o1-preview", context, opts)

      assert body[:max_completion_tokens] == 1000
      refute Map.has_key?(body, "max_tokens")
      refute Map.has_key?(body, :max_tokens)
    end

    test "OpenAI reasoning models include reasoning_effort" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Complex reasoning task")])
      opts = [stream: false, provider_options: [reasoning_effort: "high"]]

      body = Azure.OpenAI.format_request("o1", context, opts)

      assert body[:reasoning_effort] == "high"
    end

    test "Claude reasoning models override temperature to 1.0" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{reasoning: %{enabled: true}}
      }

      log =
        capture_log(fn ->
          {opts, _warnings} =
            Azure.Anthropic.pre_validate_options(
              :chat,
              model,
              temperature: 0.5,
              reasoning_effort: :medium
            )

          assert opts[:temperature] == 1.0
        end)

      assert log =~ "temperature=1.0"
      assert log =~ "Overriding"
    end

    test "Claude reasoning models set thinking config with budget_tokens" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{reasoning: %{enabled: true}}
      }

      {opts, _warnings} =
        Azure.Anthropic.pre_validate_options(:chat, model, reasoning_effort: :high)

      provider_opts = opts[:provider_options] || []
      additional_fields = provider_opts[:additional_model_request_fields]

      assert additional_fields[:thinking][:type] == "enabled"
      assert additional_fields[:thinking][:budget_tokens] == 4096
    end

    test "Claude reasoning_token_budget sets explicit budget" do
      model = %LLMDB.Model{
        id: "claude-3-5-sonnet-20241022",
        provider: :azure,
        capabilities: %{reasoning: %{enabled: true}}
      }

      {opts, _warnings} =
        Azure.Anthropic.pre_validate_options(:chat, model, reasoning_token_budget: 10_000)

      provider_opts = opts[:provider_options] || []
      additional_fields = provider_opts[:additional_model_request_fields]

      assert additional_fields[:thinking][:budget_tokens] == 10_000
    end

    test "reasoning parameters ignored for non-reasoning models with warning" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false, max_tokens: 500]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:max_tokens] == 500
      refute Map.has_key?(body, :max_completion_tokens)
    end
  end

  describe "timeout configuration" do
    test "uses standard timeout for regular GPT models" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-resource.openai.azure.com/openai",
          deployment: "my-deployment"
        )

      assert request.options[:receive_timeout] == 30_000
    end

    test "respects custom receive_timeout when specified" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-resource.openai.azure.com/openai",
          deployment: "my-deployment",
          receive_timeout: 60_000
        )

      assert request.options[:receive_timeout] == 60_000
    end

    test "uses standard timeout for embedding models" do
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
          deployment: "my-deployment"
        )

      assert request.options[:receive_timeout] == 30_000
    end

    test "custom timeout applies to Claude models" do
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
          deployment: "claude-deployment",
          receive_timeout: 90_000
        )

      assert request.options[:receive_timeout] == 90_000
    end
  end

  describe "authentication edge cases" do
    test "rejects empty string api_key" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      result =
        Azure.attach_stream(
          model,
          context,
          [api_key: "", base_url: "https://my-resource.openai.azure.com/openai"],
          :req_llm_finch
        )

      assert {:error, _} = result
    end

    test "accepts api_key with special characters" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "sk-test_key+with/special=chars",
            base_url: "https://my-resource.openai.azure.com/openai"
          ],
          :req_llm_finch
        )

      header_map = Map.new(finch_request.headers)
      assert header_map["api-key"] == "sk-test_key+with/special=chars"
    end

    test "trims whitespace from api_key" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          api_key: "  test-api-key  ",
          base_url: "https://my-resource.openai.azure.com/openai"
        )

      api_key_header = get_header(request.headers, "api-key")
      assert api_key_header == "test-api-key" or api_key_header == "  test-api-key  "
    end
  end

  defp get_header(headers, key) do
    case Enum.find(headers, fn {k, _v} -> k == key end) do
      {_, [value | _]} -> value
      {_, value} when is_binary(value) -> value
      nil -> nil
    end
  end

  describe "Azure AI Foundry format detection" do
    test "detects Foundry format from .services.ai.azure.com domain" do
      assert Azure.uses_foundry_format?("https://my-resource.services.ai.azure.com")
      assert Azure.uses_foundry_format?("https://test.services.ai.azure.com/some/path")
      assert Azure.uses_foundry_format?("https://resource-name.services.ai.azure.com/")
    end

    test "does not detect Foundry format for traditional Azure OpenAI domains" do
      refute Azure.uses_foundry_format?("https://my-resource.openai.azure.com/openai")
      refute Azure.uses_foundry_format?("https://my-resource.cognitiveservices.azure.com")
      refute Azure.uses_foundry_format?("https://example.com")
    end

    test "handles edge cases safely" do
      refute Azure.uses_foundry_format?(nil)
      refute Azure.uses_foundry_format?("")
      refute Azure.uses_foundry_format?("not-a-url")
      refute Azure.uses_foundry_format?(12_345)
    end

    test "uses Foundry URL path for .services.ai.azure.com domain" do
      {:ok, model} = ReqLLM.model("azure:deepseek-v3.1")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          deployment: "deepseek-v3",
          base_url: "https://my-resource.services.ai.azure.com",
          api_key: "test-key"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "/models/chat/completions"
      refute url_string =~ "/deployments/"
    end

    test "uses traditional URL path for .openai.azure.com domain" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          deployment: "my-deployment",
          base_url: "https://my-resource.openai.azure.com/openai",
          api_key: "test-key"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "/deployments/my-deployment/chat/completions"
      refute url_string =~ "/models/chat/completions"
    end

    test "adds model to request body for Foundry format" do
      {:ok, model} = ReqLLM.model("azure:deepseek-v3.1")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          deployment: "deepseek-v3-deployment",
          base_url: "https://my-resource.services.ai.azure.com",
          api_key: "test-key"
        )

      # Extract the JSON body from the request
      body = get_json_body(request)
      assert body["model"] == "deepseek-v3-deployment"
    end

    test "does not add model to request body for traditional format" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          deployment: "my-deployment",
          base_url: "https://my-resource.openai.azure.com/openai",
          api_key: "test-key"
        )

      # Extract the JSON body from the request
      body = get_json_body(request)
      refute Map.has_key?(body, "model")
    end

    test "uses Foundry URL path for embeddings on .services.ai.azure.com domain" do
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
          deployment: "my-embedding-deployment",
          base_url: "https://my-resource.services.ai.azure.com",
          api_key: "test-key"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "/models/embeddings"
      refute url_string =~ "/deployments/"
    end

    test "uses traditional URL path for embeddings on .openai.azure.com domain" do
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
          deployment: "my-embedding-deployment",
          base_url: "https://my-resource.openai.azure.com/openai",
          api_key: "test-key"
        )

      url_string = URI.to_string(request.url)
      assert url_string =~ "/deployments/my-embedding-deployment/embeddings"
      refute url_string =~ "/models/embeddings"
    end

    test "streaming uses Foundry URL path for .services.ai.azure.com domain" do
      {:ok, model} = ReqLLM.model("azure:deepseek-v3.1")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "test-api-key",
            deployment: "deepseek-v3-deployment",
            base_url: "https://my-resource.services.ai.azure.com"
          ],
          :req_llm_finch
        )

      url_string =
        case finch_request do
          %{path: path, query: query} when is_binary(query) and query != "" ->
            path <> "?" <> query

          %{path: path} ->
            path
        end

      assert url_string =~ "/models/chat/completions"
      refute url_string =~ "/deployments/"
    end

    test "streaming uses traditional URL path for .openai.azure.com domain" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "test-api-key",
            deployment: "my-deployment",
            base_url: "https://my-resource.openai.azure.com/openai"
          ],
          :req_llm_finch
        )

      url_string =
        case finch_request do
          %{path: path, query: query} when is_binary(query) and query != "" ->
            path <> "?" <> query

          %{path: path} ->
            path
        end

      assert url_string =~ "/deployments/my-deployment/chat/completions"
      refute url_string =~ "/models/chat/completions"
    end

    test "streaming adds model to request body for Foundry format" do
      {:ok, model} = ReqLLM.model("azure:deepseek-v3.1")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "test-api-key",
            deployment: "deepseek-v3-deployment",
            base_url: "https://my-resource.services.ai.azure.com"
          ],
          :req_llm_finch
        )

      # Decode the JSON body from the Finch request
      body = Jason.decode!(finch_request.body)
      assert body["model"] == "deepseek-v3-deployment"
    end
  end

  defp get_json_body(%Req.Request{} = request) do
    # Req stores JSON body in options[:json] before encoding
    request.options[:json] || %{}
  end
end

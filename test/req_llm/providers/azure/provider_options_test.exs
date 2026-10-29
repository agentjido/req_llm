defmodule ReqLLM.Providers.Azure.ProviderOptionsTest do
  @moduledoc """
  Provider option schemas, translation, thinking constraints, and timeouts.
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Azure

  describe "provider_schema" do
    test "api_version option has no schema-level default (chosen at runtime)" do
      schema = Azure.provider_schema()
      api_version_spec = schema.schema[:api_version]

      assert api_version_spec[:type] == :string
      refute api_version_spec[:default]
    end

    test "deployment option is available" do
      schema = Azure.provider_schema()
      deployment_spec = schema.schema[:deployment]

      assert deployment_spec[:type] == :string
    end

    test "include option accepts a list of Responses API include values" do
      schema = Azure.provider_schema()

      assert schema.schema[:include][:type] == {:list, :string}
    end

    test "Responses API reasoning and chaining options are accepted" do
      {:ok, model} = ReqLLM.model("azure:gpt-5.4")

      opts = [
        base_url: "https://my-resource.openai.azure.com/openai",
        deployment: "gpt-5-4",
        context: ReqLLM.Context.new([ReqLLM.Context.user("Hello")]),
        provider_options: [
          reasoning_summary: :auto,
          reasoning_context: :current_turn,
          context_management: [%{type: "compaction", compact_threshold: 1000}],
          store: false,
          previous_response_id: "resp_1",
          prompt_cache_key: "cache-1"
        ]
      ]

      assert {:ok, processed} = ReqLLM.Provider.Options.process(Azure, :chat, model, opts)
      assert processed[:provider_options][:reasoning_summary] == :auto
      assert processed[:provider_options][:reasoning_context] == :current_turn
      assert processed[:provider_options][:previous_response_id] == "resp_1"
    end

    test "top-level reasoning_summary is hoisted into provider_options" do
      {:ok, model} = ReqLLM.model("azure:gpt-5.4")

      opts = [
        base_url: "https://my-resource.openai.azure.com/openai",
        context: ReqLLM.Context.new([ReqLLM.Context.user("Hello")]),
        reasoning_summary: "detailed"
      ]

      assert {:ok, processed} = ReqLLM.Provider.Options.process(Azure, :chat, model, opts)
      assert processed[:provider_options][:reasoning_summary] == "detailed"
    end

    test "rejects invalid reasoning_context values" do
      {:ok, model} = ReqLLM.model("azure:gpt-5.4")

      opts = [
        base_url: "https://my-resource.openai.azure.com/openai",
        context: ReqLLM.Context.new([ReqLLM.Context.user("Hello")]),
        provider_options: [reasoning_context: :sometimes]
      ]

      assert {:error, _} = ReqLLM.Provider.Options.process(Azure, :chat, model, opts)
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
      {:ok, model} = ReqLLM.model("azure:o1")

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
      {:ok, model} = ReqLLM.model("azure:o1")

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
      model = ReqLLM.Test.AzureModelHelpers.embedding_model("text-embedding-3-small")

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
      model = ReqLLM.Test.AzureModelHelpers.chat_model("claude-3-5-sonnet-20241022")

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

    test "uses extended timeout for DeepSeek models" do
      {:ok, model} = ReqLLM.model(%{provider: :azure, id: "deepseek-r1"})

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-resource.services.ai.azure.com/models",
          deployment: "deepseek-r1"
        )

      assert request.options[:receive_timeout] == 120_000
    end

    test "uses extended timeout for mai-ds models" do
      {:ok, model} = ReqLLM.model("azure:mai-ds-r1")

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-resource.services.ai.azure.com/models",
          deployment: "mai-ds-r1"
        )

      assert request.options[:receive_timeout] == 120_000
    end

    test "custom timeout overrides default for DeepSeek models" do
      {:ok, model} = ReqLLM.model(%{provider: :azure, id: "deepseek-r1"})

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          base_url: "https://my-resource.services.ai.azure.com/models",
          deployment: "deepseek-r1",
          receive_timeout: 60_000
        )

      assert request.options[:receive_timeout] == 60_000
    end
  end
end

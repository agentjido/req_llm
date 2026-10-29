defmodule ReqLLM.Providers.Azure.ProviderStreamingTest do
  @moduledoc """
  Provider streaming request construction and reasoning response assembly.
  """

  use ExUnit.Case, async: true

  import ReqLLM.Test.AzureModelHelpers, only: [traditional_openai_model: 0]

  alias ReqLLM.Providers.Azure

  describe "attach_stream/4" do
    import ExUnit.CaptureLog

    test "builds Finch request with correct URL and headers" do
      model = traditional_openai_model()
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

    test "logs unsupported parameter warnings for reasoning models" do
      {:ok, model} = ReqLLM.model("azure:gpt-5.4")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      log =
        capture_log(fn ->
          {:ok, _finch_request} =
            Azure.attach_stream(
              model,
              context,
              [
                api_key: "test-api-key",
                deployment: "my-deployment",
                base_url: "https://my-resource.openai.azure.com/openai",
                temperature: 0.2,
                max_tokens: 50
              ],
              :req_llm_finch
            )
        end)

      assert log =~ "Renamed :max_tokens to :max_completion_tokens for reasoning models"
      assert log =~ "This model does not support sampling parameters"
    end

    test "uses Authorization Bearer header when api_key starts with 'Bearer '" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.test",
            deployment: "my-deployment",
            base_url: "https://my-resource.openai.azure.com/openai"
          ],
          :req_llm_finch
        )

      header_map = Map.new(finch_request.headers)
      assert header_map["authorization"] == "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.test"
      refute Map.has_key?(header_map, "api-key")
    end

    test "Bearer token takes precedence for Claude models in streaming" do
      model = ReqLLM.Test.AzureModelHelpers.chat_model("claude-3-5-sonnet-20241022")

      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.test",
            deployment: "claude-deployment",
            base_url: "https://my-resource.openai.azure.com/openai"
          ],
          :req_llm_finch
        )

      header_map = Map.new(finch_request.headers)
      assert header_map["authorization"] == "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.test"
      refute Map.has_key?(header_map, "x-api-key")
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
      model = ReqLLM.Test.AzureModelHelpers.chat_model("claude-3-5-sonnet-20241022")

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
      model = ReqLLM.Test.AzureModelHelpers.chat_model("claude-3-5-sonnet-20241022")

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
      model = ReqLLM.Test.AzureModelHelpers.chat_model("claude-3-5-sonnet-20241022")

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

  describe "ResponseBuilder - streaming reasoning_details extraction" do
    alias ReqLLM.Provider.Defaults.ResponseBuilder

    test "extracts reasoning_details from thinking chunks for OpenAI models" do
      {:ok, model} = ReqLLM.model("azure:gpt-4o")
      context = %ReqLLM.Context{messages: []}

      thinking_meta = %{
        provider: :openai,
        format: "openai-chat-v1",
        encrypted?: false,
        provider_data: %{"type" => "reasoning"}
      }

      chunks = [
        ReqLLM.StreamChunk.thinking("Step 1: Analyze the problem", thinking_meta),
        ReqLLM.StreamChunk.thinking("Step 2: Consider solutions", thinking_meta),
        ReqLLM.StreamChunk.text("The answer is 42.")
      ]

      metadata = %{finish_reason: :stop}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.reasoning_details != nil
      assert length(response.message.reasoning_details) == 2

      [first, second] = response.message.reasoning_details
      assert %ReqLLM.Message.ReasoningDetails{} = first
      assert first.text == "Step 1: Analyze the problem"
      assert first.provider == :openai
      assert first.format == "openai-chat-v1"
      assert first.index == 0

      assert second.text == "Step 2: Consider solutions"
      assert second.index == 1
    end

    test "prefers finalized reasoning_details from meta chunks for Claude models on Azure" do
      model = ReqLLM.Test.AzureModelHelpers.chat_model("claude-3-5-sonnet-20241022")

      context = %ReqLLM.Context{messages: []}

      reasoning_detail = %ReqLLM.Message.ReasoningDetails{
        text: "Let me think through this carefully",
        signature: "sig_azure_123",
        encrypted?: true,
        provider: :anthropic,
        format: "anthropic-thinking-v1",
        index: 0,
        provider_data: %{"type" => "thinking"}
      }

      chunks = [
        ReqLLM.StreamChunk.thinking("Let me think through"),
        ReqLLM.StreamChunk.thinking(" this carefully"),
        ReqLLM.StreamChunk.meta(%{reasoning_details: [reasoning_detail]}),
        ReqLLM.StreamChunk.text("Here is my answer.")
      ]

      metadata = %{finish_reason: :stop}

      {:ok, response} =
        ResponseBuilder.build_response(chunks, metadata, context: context, model: model)

      assert response.message.reasoning_details != nil
      assert length(response.message.reasoning_details) == 1

      [first] = response.message.reasoning_details
      assert first.text == reasoning_detail.text
      assert first.signature == "sig_azure_123"
      assert first.provider == :anthropic
      assert first.format == "anthropic-thinking-v1"
      assert first.index == 0
    end

    test "Claude streamed reasoning round-trips into Anthropic request blocks on Azure" do
      alias ReqLLM.Providers.Azure.Anthropic, as: AzureAnthropic

      model = ReqLLM.Test.AzureModelHelpers.chat_model("claude-3-5-sonnet-20241022")

      context = %ReqLLM.Context{messages: []}

      reasoning_detail = %ReqLLM.Message.ReasoningDetails{
        text: "Let me think through this carefully",
        signature: "sig_azure_123",
        encrypted?: true,
        provider: :anthropic,
        format: "anthropic-thinking-v1",
        index: 0,
        provider_data: %{"type" => "thinking"}
      }

      chunks = [
        ReqLLM.StreamChunk.thinking("Let me think through"),
        ReqLLM.StreamChunk.thinking(" this carefully"),
        ReqLLM.StreamChunk.meta(%{reasoning_details: [reasoning_detail]}),
        ReqLLM.StreamChunk.text("Here is my answer.")
      ]

      {:ok, response} =
        ResponseBuilder.build_response(chunks, %{finish_reason: :stop},
          context: context,
          model: model
        )

      body = AzureAnthropic.format_request(model.id, response.context, [])
      [assistant_message] = body.messages
      [thinking_block, text_block] = assistant_message[:content]

      assert thinking_block[:type] == "thinking"
      assert thinking_block[:thinking] == "Let me think through this carefully"
      assert thinking_block[:signature] == "sig_azure_123"
      assert text_block == %{type: "text", text: "Here is my answer."}
    end
  end
end

defmodule ReqLLM.Providers.Azure.ProviderOpenAICompatibilityTest do
  @moduledoc """
  Provider compatibility with OpenAI verbosity, reasoning, and Responses API requests.
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Azure

  describe "verbosity option" do
    test "OpenAI models include verbosity when provided as atom" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false, provider_options: [verbosity: :low]]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:verbosity] == "low"
    end

    test "OpenAI models include verbosity when provided as string" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false, provider_options: [verbosity: "high"]]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:verbosity] == "high"
    end

    test "OpenAI models omit verbosity when not provided" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      refute Map.has_key?(body, :verbosity)
    end

    test "verbosity works with reasoning models" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false, provider_options: [verbosity: :medium, reasoning_effort: "high"]]

      body = Azure.OpenAI.format_request("o3-mini", context, opts)

      assert body[:verbosity] == "medium"
      assert body[:reasoning_effort] == "high"
    end
  end

  describe "reasoning model features" do
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

    test "Responses API models forward reasoning_effort to the encoded body" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Complex reasoning task")])
      opts = [stream: false, reasoning_effort: :high]

      body = Azure.ResponsesAPI.format_request("gpt-5-codex", context, opts)

      assert body["reasoning"] == %{"effort" => "high"}
    end

    test "Responses API models omit reasoning when reasoning_effort is absent" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false]

      body = Azure.ResponsesAPI.format_request("gpt-5-codex", context, opts)

      refute Map.has_key?(body, "reasoning")
    end

    test "Responses API models forward reasoning summary, context and context_management" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      opts = [
        stream: false,
        reasoning_effort: :medium,
        provider_options: [
          reasoning_summary: :auto,
          reasoning_context: :all_turns,
          context_management: [%{type: "compaction", compact_threshold: 1000}],
          store: false,
          prompt_cache_key: "cache-1"
        ]
      ]

      body = Azure.ResponsesAPI.format_request("gpt-5.4", context, opts)

      assert body["reasoning"] == %{
               "effort" => "medium",
               "summary" => "auto",
               "context" => "all_turns"
             }

      assert body["context_management"] == [
               %{"type" => "compaction", "compact_threshold" => 1000}
             ]

      assert body["store"] == false
      assert body["prompt_cache_key"] == "cache-1"
    end

    test "Responses API models replay Azure reasoning details" do
      detail = %ReqLLM.Message.ReasoningDetails{
        text: "Plan",
        signature: "enc",
        encrypted?: true,
        provider: :azure,
        format: "openai-responses-v1",
        index: 0,
        provider_data: %{"id" => "rs_1", "type" => "reasoning"}
      }

      context =
        ReqLLM.Context.new([
          %ReqLLM.Message{
            role: :assistant,
            content: [%ReqLLM.Message.ContentPart{type: :text, text: "Answer"}],
            reasoning_details: [detail]
          },
          ReqLLM.Context.user("Next")
        ])

      body =
        Azure.ResponsesAPI.format_request("gpt-5.4", context,
          stream: false,
          provider_options: [store: false]
        )

      assert [%{"type" => "reasoning", "encrypted_content" => "enc"} | _] = body["input"]
    end

    test "format_compact_request/3 encodes the compaction body" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      body = Azure.ResponsesAPI.format_compact_request("gpt-5.4", context, provider_options: [])

      assert body["model"] == "gpt-5.4"
      assert [%{"role" => "user"}] = body["input"]

      assert Azure.ResponsesAPI.format_compact_request("gpt-5.4", context,
               provider_options: [previous_response_id: "resp_1"]
             ) == %{"model" => "gpt-5.4", "previous_response_id" => "resp_1"}
    end

    test "Responses API models forward openai_parallel_tool_calls from provider_options" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false, provider_options: [openai_parallel_tool_calls: false]]

      body = Azure.ResponsesAPI.format_request("gpt-5-codex", context, opts)

      assert body["parallel_tool_calls"] == false
    end

    test "Responses API models accept parallel_tool_calls alias in provider_options" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false, provider_options: [parallel_tool_calls: true]]

      body = Azure.ResponsesAPI.format_request("gpt-5-codex", context, opts)

      assert body["parallel_tool_calls"] == true
    end

    test "Responses API models omit parallel_tool_calls when not provided" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false]

      body = Azure.ResponsesAPI.format_request("gpt-5-codex", context, opts)

      refute Map.has_key?(body, "parallel_tool_calls")
    end

    test "Responses API models forward include from provider_options" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      opts = [
        stream: false,
        provider_options: [
          include: ["reasoning.encrypted_content", "web_search_call.action.sources"]
        ]
      ]

      body = Azure.ResponsesAPI.format_request("gpt-5-codex", context, opts)

      assert body["include"] == [
               "reasoning.encrypted_content",
               "web_search_call.action.sources"
             ]
    end

    test "attach_stream accepts include for Responses API models" do
      model = %LLMDB.Model{
        id: "gpt-5",
        provider: :azure,
        capabilities: %{chat: true},
        extra: %{wire: %{protocol: "openai_responses"}}
      }

      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "test-api-key",
            deployment: "gpt-5",
            base_url: "https://my-resource.openai.azure.com/openai/v1",
            provider_options: [include: ["web_search_call.action.sources"]]
          ],
          :req_llm_finch
        )

      assert %Finch.Request{} = finch_request
      assert Jason.decode!(finch_request.body)["include"] == ["web_search_call.action.sources"]
    end

    test "attach_stream accepts reasoning_summary for Responses API models" do
      model = %LLMDB.Model{
        id: "gpt-5",
        provider: :azure,
        capabilities: %{chat: true},
        extra: %{wire: %{protocol: "openai_responses"}}
      }

      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, finch_request} =
        Azure.attach_stream(
          model,
          context,
          [
            api_key: "test-api-key",
            deployment: "gpt-5",
            base_url: "https://my-resource.openai.azure.com/openai",
            reasoning_effort: :high,
            provider_options: [reasoning_summary: :auto]
          ],
          :req_llm_finch
        )

      assert Jason.decode!(finch_request.body)["reasoning"] == %{
               "effort" => "high",
               "summary" => "auto"
             }
    end

    test "prepare_request(:compact) targets the v1 GA compaction endpoint" do
      {:ok, model} = ReqLLM.model("azure:gpt-5.4")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, request} =
        Azure.prepare_request(:compact, model, context,
          api_key: "test-api-key",
          deployment: "my-gpt-5-4",
          base_url: "https://my-resource.openai.azure.com/openai/v1"
        )

      assert URI.to_string(request.url) == "/responses/compact"
      assert request.options[:base_url] == "https://my-resource.openai.azure.com/openai/v1"
      assert request.options[:json]["model"] == "my-gpt-5-4"
      assert [%{"role" => "user"}] = request.options[:json]["input"]
      assert Req.Request.get_private(request, :formatter) == Azure.ResponsesAPI
      assert Req.Request.get_header(request, "api-key") == ["test-api-key"]
    end

    test "prepare_request(:compact) appends api-version on the legacy base URL" do
      {:ok, model} = ReqLLM.model("azure:gpt-5.4")
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      {:ok, request} =
        Azure.prepare_request(:compact, model, context,
          api_key: "test-api-key",
          deployment: "gpt-5.4",
          base_url: "https://my-resource.openai.azure.com/openai",
          provider_options: [api_version: "2025-04-01-preview", previous_response_id: "resp_1"]
        )

      assert URI.to_string(request.url) == "/responses/compact?api-version=2025-04-01-preview"

      assert request.options[:json] == %{
               "model" => "gpt-5.4",
               "previous_response_id" => "resp_1"
             }
    end

    test "prepare_request(:compact) rejects Chat Completions and Claude models" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [api_key: "k", base_url: "https://my-resource.openai.azure.com/openai"]

      chat_model = %LLMDB.Model{
        id: "gpt-4o",
        provider: :azure,
        capabilities: %{chat: true},
        extra: %{wire: %{protocol: "openai_chat"}}
      }

      assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: message}} =
               Azure.prepare_request(:compact, chat_model, context, opts)

      assert message =~ "openai_responses"

      claude = ReqLLM.Test.AzureModelHelpers.chat_model("claude-sonnet-4-5")

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Azure.prepare_request(:compact, claude, context, opts)
    end

    test "reasoning parameters ignored for non-reasoning models with warning" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false, max_tokens: 500]

      body = Azure.OpenAI.format_request("gpt-4o", context, opts)

      assert body[:max_tokens] == 500
      refute Map.has_key?(body, :max_completion_tokens)
    end
  end
end

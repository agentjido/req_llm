defmodule ReqLLM.Providers.Azure.ProviderAnthropicCompatibilityTest do
  @moduledoc """
  Provider compatibility with Claude thinking options and synchronous reasoning responses.
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Azure

  describe "reasoning model features" do
    import ExUnit.CaptureLog

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

    test "Claude adaptive-only platform models include adaptive thinking in prepared request" do
      model = %LLMDB.Model{
        id: "claude-opus-4-7",
        model: "claude-opus-4-7",
        provider: :azure,
        capabilities: %{chat: true, reasoning: %{enabled: true}},
        extra: %{family: "claude-opus", wire_protocol: "anthropic_messages"}
      }

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          api_key: "test-key",
          base_url: "https://my-resource.services.ai.azure.com/anthropic",
          deployment: "claude-opus-4-7",
          max_tokens: 2000,
          reasoning_effort: :high
        )

      body = request.options[:json]
      assert body[:thinking] == %{type: "adaptive", display: "summarized"}
      refute Map.has_key?(body, :temperature)
      assert body[:output_config][:effort] == "high"
      assert body[:max_tokens] == 2000
    end

    test "Claude adaptive-only platform models do not auto-enable thinking" do
      model = %LLMDB.Model{
        id: "claude-opus-4-7",
        model: "claude-opus-4-7",
        provider: :azure,
        capabilities: %{chat: true, reasoning: %{enabled: true}},
        extra: %{family: "claude-opus", wire_protocol: "anthropic_messages"}
      }

      {:ok, request} =
        Azure.prepare_request(
          :chat,
          model,
          "Hello",
          api_key: "test-key",
          base_url: "https://my-resource.services.ai.azure.com/anthropic",
          deployment: "claude-opus-4-7",
          max_tokens: 2000
        )

      refute Map.has_key?(request.options[:json], :thinking)
    end
  end

  describe "Sync flow - reasoning_details extraction" do
    alias ReqLLM.Providers.Azure.Anthropic, as: AzureAnthropic

    test "extracts reasoning_details from Claude response on Azure (sync flow)" do
      model = ReqLLM.Test.AzureModelHelpers.chat_model("claude-3-5-sonnet-20241022")

      anthropic_response_body = %{
        "id" => "msg_01XFDUDYJgAACzvnptvVoYEL",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-5-sonnet-20241022",
        "content" => [
          %{"type" => "thinking", "thinking" => "Let me analyze this step by step"},
          %{"type" => "thinking", "thinking" => "Considering the options"},
          %{"type" => "text", "text" => "Here is my answer."}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 50
        }
      }

      {:ok, response} = AzureAnthropic.parse_response(anthropic_response_body, model, [])

      assert response.message.reasoning_details != nil
      assert length(response.message.reasoning_details) == 2

      [first, second] = response.message.reasoning_details
      assert first.text == "Let me analyze this step by step"
      assert first.provider == :anthropic
      assert first.format == "anthropic-thinking-v1"
      assert first.index == 0

      assert second.text == "Considering the options"
      assert second.index == 1
    end

    test "returns nil reasoning_details when no thinking content (sync flow)" do
      model = ReqLLM.Test.AzureModelHelpers.chat_model("claude-3-5-sonnet-20241022")

      anthropic_response_body = %{
        "id" => "msg_01XFDUDYJgAACzvnptvVoYEL",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-5-sonnet-20241022",
        "content" => [
          %{"type" => "text", "text" => "Just a simple response."}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 20
        }
      }

      {:ok, response} = AzureAnthropic.parse_response(anthropic_response_body, model, [])

      assert response.message.reasoning_details == nil
    end
  end
end

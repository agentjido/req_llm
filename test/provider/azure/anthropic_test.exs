defmodule ReqLLM.Providers.Azure.AnthropicTest do
  @moduledoc """
  Unit tests for Azure.Anthropic formatter module.

  Tests Claude model formatting for Azure AI Services:
  - Request formatting (no model field, messages format)
  - Extended thinking/reasoning support
  - Tool calling with Claude-specific format
  - Response parsing and usage extraction
  - Option pre-validation for thinking constraints

  This module tests the adapter layer that translates between
  Azure's API and Claude model requirements.
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Providers.Azure

  describe "format_request/3" do
    test "includes model field in body" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false]

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, opts)

      assert body.model == "claude-3-sonnet"
      assert Map.has_key?(body, :messages)
    end

    test "includes messages in correct Anthropic format" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello world")])
      opts = [stream: false]

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, opts)

      assert [%{role: "user", content: "Hello world"}] = body.messages
    end

    test "extracts system message to top level" do
      messages = [
        ReqLLM.Context.system("You are helpful"),
        ReqLLM.Context.user("Hello")
      ]

      context = ReqLLM.Context.new(messages)
      opts = [stream: false]

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, opts)

      assert body.system == "You are helpful"
      assert [%{role: "user", content: "Hello"}] = body.messages
    end

    test "includes stream flag when streaming" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: true]

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, opts)

      assert body.stream == true
    end

    test "includes temperature and other options" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false, temperature: 0.7, max_tokens: 100]

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, opts)

      assert body.temperature == 0.7
      assert body.max_tokens == 100
    end

    test "uses default max_tokens when not specified" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])
      opts = [stream: false]

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, opts)

      assert body.max_tokens == 1024
    end

    test "uses higher default max_tokens for :object operation" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("Hello")])

      tool =
        ReqLLM.Tool.new!(
          name: "structured_output",
          description: "Generate structured output",
          parameter_schema: [name: [type: :string, required: true]],
          callback: fn _args -> {:ok, "structured"} end
        )

      opts = [
        stream: false,
        operation: :object,
        tools: [tool],
        compiled_schema: %{schema: [name: [type: :string, required: true]]}
      ]

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, opts)

      assert body.max_tokens == 4096
    end

    test "includes tools when provided" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("What's the weather?")])

      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather info",
          parameter_schema: [location: [type: :string, required: true]],
          callback: fn _ -> {:ok, %{}} end
        )

      opts = [stream: false, tools: [tool]]

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, opts)

      assert length(body.tools) == 1
      assert hd(body.tools).name == "get_weather"
    end

    test "includes tool_choice when specified" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("What's the weather?")])

      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather info",
          parameter_schema: [location: [type: :string, required: true]],
          callback: fn _ -> {:ok, %{}} end
        )

      opts = [
        stream: false,
        tools: [tool],
        tool_choice: %{type: "tool", name: "get_weather"}
      ]

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, opts)

      assert body.tool_choice == %{type: "tool", name: "get_weather"}
    end
  end

  describe "parse_response/3" do
    test "parses Anthropic response format" do
      body = %{
        "id" => "msg_123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-sonnet",
        "content" => [
          %{"type" => "text", "text" => "Hello! How can I help you?"}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 15
        }
      }

      model = %LLMDB.Model{id: "claude-3-sonnet", provider: :azure}
      opts = [operation: :chat]

      {:ok, response} = Azure.Anthropic.parse_response(body, model, opts)

      assert response.id == "msg_123"
      assert response.model == "claude-3-sonnet"
      assert response.finish_reason == :stop
    end

    test "parses tool call response" do
      body = %{
        "id" => "msg_456",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-sonnet",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_123",
            "name" => "get_weather",
            "input" => %{"location" => "San Francisco"}
          }
        ],
        "stop_reason" => "tool_use",
        "usage" => %{
          "input_tokens" => 20,
          "output_tokens" => 30
        }
      }

      model = %LLMDB.Model{id: "claude-3-sonnet", provider: :azure}
      opts = [operation: :chat]

      {:ok, response} = Azure.Anthropic.parse_response(body, model, opts)

      assert response.finish_reason == :tool_calls
      tool_calls = ReqLLM.Response.tool_calls(response)
      assert length(tool_calls) == 1
      assert hd(tool_calls).function.name == "get_weather"
    end

    test "parses multiple tool calls in one response" do
      body = %{
        "id" => "msg_789",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-sonnet",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "get_weather",
            "input" => %{"location" => "San Francisco"}
          },
          %{
            "type" => "tool_use",
            "id" => "toolu_2",
            "name" => "get_time",
            "input" => %{"timezone" => "PST"}
          }
        ],
        "stop_reason" => "tool_use",
        "usage" => %{
          "input_tokens" => 30,
          "output_tokens" => 50
        }
      }

      model = %LLMDB.Model{id: "claude-3-sonnet", provider: :azure}
      opts = [operation: :chat]

      {:ok, response} = Azure.Anthropic.parse_response(body, model, opts)

      assert response.finish_reason == :tool_calls
      tool_calls = ReqLLM.Response.tool_calls(response)
      assert length(tool_calls) == 2

      names = Enum.map(tool_calls, & &1.function.name)
      assert "get_weather" in names
      assert "get_time" in names
    end

    test "parses mixed text and tool_use content" do
      body = %{
        "id" => "msg_mixed",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-sonnet",
        "content" => [
          %{"type" => "text", "text" => "Let me check the weather for you."},
          %{
            "type" => "tool_use",
            "id" => "toolu_123",
            "name" => "get_weather",
            "input" => %{"location" => "NYC"}
          }
        ],
        "stop_reason" => "tool_use",
        "usage" => %{
          "input_tokens" => 25,
          "output_tokens" => 40
        }
      }

      model = %LLMDB.Model{id: "claude-3-sonnet", provider: :azure}
      opts = [operation: :chat]

      {:ok, response} = Azure.Anthropic.parse_response(body, model, opts)

      assert response.finish_reason == :tool_calls
      tool_calls = ReqLLM.Response.tool_calls(response)
      assert length(tool_calls) == 1
    end

    test "parses content_filter stop_reason" do
      body = %{
        "id" => "msg_filtered",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-sonnet",
        "content" => [],
        "stop_reason" => "content_filter",
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 0
        }
      }

      model = %LLMDB.Model{id: "claude-3-sonnet", provider: :azure}
      opts = [operation: :chat]

      {:ok, response} = Azure.Anthropic.parse_response(body, model, opts)

      assert response.finish_reason == :content_filter
    end

    test "parses max_tokens stop_reason" do
      body = %{
        "id" => "msg_truncated",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-sonnet",
        "content" => [
          %{"type" => "text", "text" => "This response was truncated due to..."}
        ],
        "stop_reason" => "max_tokens",
        "usage" => %{
          "input_tokens" => 50,
          "output_tokens" => 100
        }
      }

      model = %LLMDB.Model{id: "claude-3-sonnet", provider: :azure}
      opts = [operation: :chat]

      {:ok, response} = Azure.Anthropic.parse_response(body, model, opts)

      assert response.finish_reason == :length
    end

    test "parses stop stop_reason (explicit stop)" do
      body = %{
        "id" => "msg_stopped",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-sonnet",
        "content" => [
          %{"type" => "text", "text" => "Text until stop sequence"}
        ],
        "stop_reason" => "stop",
        "usage" => %{
          "input_tokens" => 20,
          "output_tokens" => 10
        }
      }

      model = %LLMDB.Model{id: "claude-3-sonnet", provider: :azure}
      opts = [operation: :chat]

      {:ok, response} = Azure.Anthropic.parse_response(body, model, opts)

      assert response.finish_reason == :stop
    end

    test "parses response with empty content array" do
      body = %{
        "id" => "msg_empty",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-sonnet",
        "content" => [],
        "stop_reason" => "end_turn",
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 0
        }
      }

      model = %LLMDB.Model{id: "claude-3-sonnet", provider: :azure}
      opts = [operation: :chat]

      {:ok, response} = Azure.Anthropic.parse_response(body, model, opts)

      assert response.finish_reason == :stop
    end
  end

  describe "extract_usage/2" do
    test "extracts token counts from response" do
      body = %{
        "usage" => %{
          "input_tokens" => 10,
          "output_tokens" => 20
        }
      }

      {:ok, usage} = Azure.Anthropic.extract_usage(body, nil)

      assert usage["input_tokens"] == 10
      assert usage["output_tokens"] == 20
    end

    test "extracts cached tokens when present" do
      body = %{
        "usage" => %{
          "input_tokens" => 100,
          "output_tokens" => 50,
          "cache_read_input_tokens" => 75
        }
      }

      {:ok, usage} = Azure.Anthropic.extract_usage(body, nil)

      assert usage["input_tokens"] == 100
      assert usage["output_tokens"] == 50
      assert usage["cache_read_input_tokens"] == 75
    end

    test "returns error when no usage data" do
      body = %{"content" => []}

      assert {:error, :no_usage_found} = Azure.Anthropic.extract_usage(body, nil)
    end
  end

  describe "pre_validate_options/3" do
    test "translates reasoning_effort to thinking config for capable models" do
      model = %LLMDB.Model{
        id: "claude-3-sonnet",
        provider: :azure,
        capabilities: %{reasoning: %{enabled: true}}
      }

      opts = [reasoning_effort: :medium]

      {translated, _warnings} = Azure.Anthropic.pre_validate_options(:chat, model, opts)

      provider_opts = translated[:provider_options]
      additional_fields = provider_opts[:additional_model_request_fields]
      assert additional_fields[:thinking] == %{type: "enabled", budget_tokens: 2048}
      assert translated[:temperature] == 1.0
    end

    test "sets minimum max_tokens for reasoning" do
      model = %LLMDB.Model{
        id: "claude-3-sonnet",
        provider: :azure,
        capabilities: %{reasoning: %{enabled: true}}
      }

      opts = [reasoning_effort: :low, max_tokens: 100]

      {translated, _warnings} = Azure.Anthropic.pre_validate_options(:chat, model, opts)

      # min_tokens should be budget (1024) + 201 = 1225
      assert translated[:max_tokens] >= 1225
    end

    test "passes through for models without reasoning capability" do
      model = %LLMDB.Model{
        id: "claude-3-sonnet",
        provider: :azure,
        capabilities: %{}
      }

      opts = [reasoning_effort: :medium, max_tokens: 100]

      {translated, _warnings} = Azure.Anthropic.pre_validate_options(:chat, model, opts)

      # Should pass through unchanged (except reasoning_effort removed)
      refute Keyword.has_key?(
               translated[:provider_options] || [],
               :additional_model_request_fields
             )
    end

    test "warns and removes json_schema response_format" do
      import ExUnit.CaptureLog

      model = %LLMDB.Model{
        id: "claude-3-sonnet",
        provider: :azure,
        capabilities: %{}
      }

      opts = [response_format: %{type: "json_schema", json_schema: %{}}]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.Anthropic.pre_validate_options(:chat, model, opts)
          refute Keyword.has_key?(translated, :response_format)
        end)

      assert log =~ "response_format with json_schema is not supported"
      assert log =~ "Claude models on Azure"
    end

    test "warns when reasoning params used with non-reasoning model" do
      import ExUnit.CaptureLog

      model = %LLMDB.Model{
        id: "claude-3-sonnet",
        provider: :azure,
        capabilities: %{}
      }

      opts = [reasoning_effort: :high]

      log =
        capture_log(fn ->
          Azure.Anthropic.pre_validate_options(:chat, model, opts)
        end)

      assert log =~ "Reasoning parameters ignored"
    end

    test "warns and removes service_tier (OpenAI-specific option)" do
      import ExUnit.CaptureLog

      model = %LLMDB.Model{
        id: "claude-3-sonnet",
        provider: :azure,
        capabilities: %{}
      }

      opts = [provider_options: [service_tier: "priority"]]

      log =
        capture_log(fn ->
          {translated, _warnings} = Azure.Anthropic.pre_validate_options(:chat, model, opts)
          provider_opts = translated[:provider_options] || []
          refute Keyword.has_key?(provider_opts, :service_tier)
        end)

      assert log =~ "service_tier is an OpenAI-specific option"
      assert log =~ "ignored for Claude models"
    end
  end

  describe "prompt caching integration" do
    test "adds cache_control to system message when enabled" do
      messages = [
        ReqLLM.Context.system("You are a helpful assistant with a long context"),
        ReqLLM.Context.user("Hello")
      ]

      context = ReqLLM.Context.new(messages)

      opts = [
        stream: false,
        anthropic_prompt_cache: true
      ]

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, opts)

      assert is_list(body.system)
      system_block = Enum.find(body.system, &is_map/1)
      assert system_block
      assert system_block.cache_control == %{type: "ephemeral"}
    end

    test "does not add cache_control when prompt caching is disabled" do
      messages = [
        ReqLLM.Context.system("You are a helpful assistant"),
        ReqLLM.Context.user("Hello")
      ]

      context = ReqLLM.Context.new(messages)
      opts = [stream: false]

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, opts)

      assert body.system == "You are a helpful assistant"
    end

    test "adds cache_control to tools when prompt caching enabled" do
      messages = [
        ReqLLM.Context.user("What's the weather?")
      ]

      context = ReqLLM.Context.new(messages)

      tool =
        ReqLLM.Tool.new!(
          name: "get_weather",
          description: "Get weather information",
          parameter_schema: [location: [type: :string, required: true]],
          callback: fn _ -> {:ok, %{}} end
        )

      opts = [
        stream: false,
        tools: [tool],
        anthropic_prompt_cache: true
      ]

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, opts)

      assert length(body.tools) == 1
      tool_block = hd(body.tools)
      assert tool_block.cache_control == %{type: "ephemeral"}
    end

    test "adds cache_control with TTL when anthropic_prompt_cache_ttl specified" do
      messages = [
        ReqLLM.Context.system("You are a helpful assistant"),
        ReqLLM.Context.user("Hello")
      ]

      context = ReqLLM.Context.new(messages)

      opts = [
        stream: false,
        anthropic_prompt_cache: true,
        anthropic_prompt_cache_ttl: "1h"
      ]

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, opts)

      assert is_list(body.system)
      system_block = Enum.find(body.system, &is_map/1)
      assert system_block.cache_control == %{type: "ephemeral", ttl: "1h"}
    end

    test "adds cache_control to last system block when multiple blocks" do
      system_content = [
        ReqLLM.Message.ContentPart.text("First instruction."),
        ReqLLM.Message.ContentPart.text("Second instruction.")
      ]

      context =
        ReqLLM.Context.new([
          %ReqLLM.Message{role: :system, content: system_content},
          ReqLLM.Context.user("Hello!")
        ])

      opts = [
        stream: false,
        anthropic_prompt_cache: true
      ]

      body = Azure.Anthropic.format_request("claude-3-sonnet", context, opts)

      assert is_list(body.system)
      assert length(body.system) == 2

      last_block = List.last(body.system)
      assert last_block.cache_control == %{type: "ephemeral"}

      first_block = List.first(body.system)
      refute Map.has_key?(first_block, :cache_control)
    end

    test "extracts cache_read_input_tokens from usage" do
      body = %{
        "usage" => %{
          "input_tokens" => 100,
          "output_tokens" => 50,
          "cache_read_input_tokens" => 75,
          "cache_creation_input_tokens" => 25
        }
      }

      {:ok, usage} = Azure.Anthropic.extract_usage(body, nil)

      assert usage["input_tokens"] == 100
      assert usage["output_tokens"] == 50
      assert usage["cache_read_input_tokens"] == 75
      assert usage["cache_creation_input_tokens"] == 25
    end
  end

  describe "extended thinking integration" do
    test "formats request with thinking configuration for reasoning models" do
      model = %LLMDB.Model{
        id: "claude-3-sonnet",
        provider: :azure,
        capabilities: %{reasoning: %{enabled: true}}
      }

      _context = ReqLLM.Context.new([ReqLLM.Context.user("Complex problem")])
      opts = [stream: false, reasoning_effort: :high, max_tokens: 4000]

      {translated_opts, _} = Azure.Anthropic.pre_validate_options(:chat, model, opts)

      provider_opts = translated_opts[:provider_options] || []
      additional_fields = provider_opts[:additional_model_request_fields]

      assert additional_fields[:thinking][:type] == "enabled"
      assert additional_fields[:thinking][:budget_tokens] == 4096
      assert translated_opts[:temperature] == 1.0
    end

    test "parses thinking content from Claude response" do
      body = %{
        "id" => "msg_123",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-3-sonnet",
        "content" => [
          %{"type" => "thinking", "thinking" => "Let me analyze this..."},
          %{"type" => "text", "text" => "Here's my answer"}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 15}
      }

      model = %LLMDB.Model{id: "claude-3-sonnet", provider: :azure}
      {:ok, response} = Azure.Anthropic.parse_response(body, model, operation: :chat)

      assert response.message
      content = response.message.content

      assert is_list(content)
      assert content != []

      text_part = Enum.find(content, &(&1.type == :text))
      assert text_part.text == "Here's my answer"
    end

    test "reasoning_token_budget sets explicit thinking budget" do
      model = %LLMDB.Model{
        id: "claude-3-sonnet",
        provider: :azure,
        capabilities: %{reasoning: %{enabled: true}}
      }

      opts = [reasoning_token_budget: 8000, max_tokens: 10_000]

      {translated_opts, _} = Azure.Anthropic.pre_validate_options(:chat, model, opts)

      provider_opts = translated_opts[:provider_options] || []
      additional_fields = provider_opts[:additional_model_request_fields]

      assert additional_fields[:thinking][:type] == "enabled"
      assert additional_fields[:thinking][:budget_tokens] == 8000
    end

    test "reasoning_token_budget enforces minimum max_tokens" do
      model = %LLMDB.Model{
        id: "claude-3-sonnet",
        provider: :azure,
        capabilities: %{reasoning: %{enabled: true}}
      }

      opts = [reasoning_token_budget: 5000, max_tokens: 1000]

      {translated_opts, _} = Azure.Anthropic.pre_validate_options(:chat, model, opts)

      assert translated_opts[:max_tokens] >= 5201
    end

    test "reasoning_token_budget takes precedence over reasoning_effort when both specified" do
      model = %LLMDB.Model{
        id: "claude-3-sonnet",
        provider: :azure,
        capabilities: %{reasoning: %{enabled: true}}
      }

      opts = [reasoning_effort: :low, reasoning_token_budget: 8000]

      {translated_opts, _} = Azure.Anthropic.pre_validate_options(:chat, model, opts)

      provider_opts = translated_opts[:provider_options] || []
      additional_fields = provider_opts[:additional_model_request_fields]

      assert additional_fields[:thinking][:budget_tokens] == 8000
    end
  end

  describe "maybe_clean_thinking_after_translation/2" do
    test "removes thinking when tool_choice forces specific tool" do
      opts = [
        temperature: 1.0,
        tool_choice: %{type: "tool", name: "get_weather"},
        provider_options: [
          additional_model_request_fields: %{
            thinking: %{type: "enabled", budget_tokens: 4000}
          }
        ]
      ]

      cleaned = Azure.Anthropic.maybe_clean_thinking_after_translation(opts, :chat)

      additional_fields = cleaned[:provider_options][:additional_model_request_fields]
      refute Map.has_key?(additional_fields, :thinking)
    end

    test "removes thinking for :object operations" do
      opts = [
        temperature: 1.0,
        provider_options: [
          additional_model_request_fields: %{
            thinking: %{type: "enabled", budget_tokens: 4000}
          }
        ]
      ]

      cleaned = Azure.Anthropic.maybe_clean_thinking_after_translation(opts, :object)

      additional_fields = cleaned[:provider_options][:additional_model_request_fields]
      refute Map.has_key?(additional_fields, :thinking)
    end

    test "removes thinking when temperature is not 1.0" do
      opts = [
        temperature: 0.7,
        provider_options: [
          additional_model_request_fields: %{
            thinking: %{type: "enabled", budget_tokens: 4000}
          }
        ]
      ]

      cleaned = Azure.Anthropic.maybe_clean_thinking_after_translation(opts, :chat)

      additional_fields = cleaned[:provider_options][:additional_model_request_fields]
      refute Map.has_key?(additional_fields, :thinking)
    end

    test "preserves thinking when no incompatibilities exist" do
      opts = [
        temperature: 1.0,
        tool_choice: :auto,
        provider_options: [
          additional_model_request_fields: %{
            thinking: %{type: "enabled", budget_tokens: 4000}
          }
        ]
      ]

      cleaned = Azure.Anthropic.maybe_clean_thinking_after_translation(opts, :chat)

      additional_fields = cleaned[:provider_options][:additional_model_request_fields]
      assert additional_fields[:thinking] == %{type: "enabled", budget_tokens: 4000}
    end

    test "preserves other additional_fields when removing thinking" do
      opts = [
        tool_choice: %{type: "tool", name: "test"},
        provider_options: [
          additional_model_request_fields: %{
            thinking: %{type: "enabled", budget_tokens: 4000},
            other_field: "preserved"
          }
        ]
      ]

      cleaned = Azure.Anthropic.maybe_clean_thinking_after_translation(opts, :chat)

      additional_fields = cleaned[:provider_options][:additional_model_request_fields]
      refute Map.has_key?(additional_fields, :thinking)
      assert additional_fields.other_field == "preserved"
    end
  end
end

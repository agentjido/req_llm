defmodule ReqLLM.TelemetryProviderTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Step.Telemetry

  @reasoning_cases [
    %{
      name: "OpenAI Responses",
      provider_mod: ReqLLM.Providers.OpenAI,
      model: %{
        provider: :openai,
        id: "gpt-5",
        capabilities: %{reasoning: %{enabled: true}}
      },
      opts: [api_key: "test-key", reasoning_effort: :high],
      expected: %{
        requested_mode: :enabled,
        requested_effort: :high,
        effective_mode: :enabled,
        effective_effort: :high
      }
    },
    %{
      name: "Anthropic",
      provider_mod: ReqLLM.Providers.Anthropic,
      model: %{
        provider: :anthropic,
        id: "claude-sonnet-4-5",
        capabilities: %{reasoning: %{enabled: true}}
      },
      opts: [api_key: "test-key", reasoning_effort: :high],
      expected: %{
        requested_mode: :enabled,
        requested_effort: :high,
        effective_mode: :enabled,
        effective_budget_tokens: 4096
      }
    },
    %{
      name: "Google Gemini",
      provider_mod: ReqLLM.Providers.Google,
      model: %{
        provider: :google,
        id: "gemini-2.5-pro",
        capabilities: %{reasoning: %{enabled: true}}
      },
      opts: [api_key: "test-key", reasoning_effort: :medium],
      expected: %{
        requested_mode: :enabled,
        requested_effort: :medium,
        effective_mode: :enabled,
        effective_budget_tokens: 8192
      }
    },
    %{
      name: "Google Vertex Gemini",
      provider_mod: ReqLLM.Providers.GoogleVertex,
      model: %{
        provider: :google_vertex,
        id: "gemini-2.5-pro",
        capabilities: %{reasoning: %{enabled: true}}
      },
      opts: [access_token: "test-token", project_id: "test-project", reasoning_effort: :high],
      expected: %{
        requested_mode: :enabled,
        requested_effort: :high,
        effective_mode: :enabled,
        effective_budget_tokens: 16384
      }
    },
    %{
      name: "Google Vertex Gemini via family metadata",
      provider_mod: ReqLLM.Providers.GoogleVertex,
      model: %{
        provider: :google_vertex,
        id: "vertex-custom-reasoning-alias",
        extra: %{family: "gemini-flash"},
        capabilities: %{reasoning: %{enabled: true}}
      },
      opts: [access_token: "test-token", project_id: "test-project", reasoning_effort: :high],
      expected: %{
        requested_mode: :enabled,
        requested_effort: :high,
        effective_mode: :enabled,
        effective_budget_tokens: 16384
      }
    },
    %{
      name: "Google Vertex Anthropic",
      provider_mod: ReqLLM.Providers.GoogleVertex,
      model: %{
        provider: :google_vertex,
        id: "claude-sonnet-4-5",
        capabilities: %{reasoning: %{enabled: true}}
      },
      opts: [access_token: "test-token", project_id: "test-project", reasoning_effort: :medium],
      expected: %{
        requested_mode: :enabled,
        requested_effort: :medium,
        effective_mode: :enabled,
        effective_budget_tokens: 2048
      }
    },
    %{
      name: "Azure OpenAI",
      provider_mod: ReqLLM.Providers.Azure,
      model: %{
        provider: :azure,
        id: "o1",
        capabilities: %{reasoning: %{enabled: true}}
      },
      opts: [
        api_key: "test-key",
        base_url: "https://example.openai.azure.com/openai",
        deployment: "o1-deployment",
        reasoning_effort: :high
      ],
      expected: %{
        requested_mode: :enabled,
        requested_effort: :high,
        effective_mode: :disabled,
        effective_effort: nil
      }
    },
    %{
      name: "Azure OpenAI DeepSeek Thinking",
      provider_mod: ReqLLM.Providers.Azure,
      model: %{
        provider: :azure,
        id: "deepseek-r1",
        capabilities: %{reasoning: %{enabled: true}}
      },
      opts: [
        api_key: "test-key",
        base_url: "https://example.openai.azure.com/openai",
        deployment: "deepseek-deployment",
        provider_options: [
          additional_model_request_fields: %{thinking: %{type: "enabled", budget_tokens: 4000}}
        ]
      ],
      expected: %{
        requested_mode: :enabled,
        effective_mode: :enabled,
        effective_budget_tokens: 4000
      }
    },
    %{
      name: "Azure Anthropic",
      provider_mod: ReqLLM.Providers.Azure,
      model: %{
        provider: :azure,
        id: "claude-sonnet-4-5",
        capabilities: %{reasoning: %{enabled: true}}
      },
      opts: [
        api_key: "test-key",
        base_url: "https://example.openai.azure.com/openai",
        deployment: "claude-deployment",
        reasoning_effort: :high
      ],
      expected: %{
        requested_mode: :enabled,
        requested_effort: :high,
        effective_mode: :enabled,
        effective_budget_tokens: 4096
      }
    },
    %{
      name: "Amazon Bedrock Anthropic",
      provider_mod: ReqLLM.Providers.AmazonBedrock,
      model: %{
        provider: :amazon_bedrock,
        id: "claude-sonnet-4-5",
        provider_model_id: "anthropic.claude-sonnet-4-5-20250929-v1:0",
        capabilities: %{reasoning: %{enabled: true}}
      },
      opts: [api_key: "test-key", region: "us-east-1", reasoning_effort: :high],
      expected: %{
        requested_mode: :enabled,
        requested_effort: :high,
        effective_mode: :enabled,
        effective_budget_tokens: 4096
      }
    },
    %{
      name: "Zenmux Reasoning Config",
      provider_mod: ReqLLM.Providers.Zenmux,
      model: %{
        provider: :zenmux,
        id: "gpt-5",
        capabilities: %{reasoning: %{enabled: true}}
      },
      opts: [api_key: "test-key", provider_options: [reasoning: %{enable: true}]],
      expected: %{
        requested_mode: :enabled,
        effective_mode: :enabled
      }
    },
    %{
      name: "xAI",
      provider_mod: ReqLLM.Providers.XAI,
      model: %{
        provider: :xai,
        id: "grok-3-mini",
        capabilities: %{reasoning: %{enabled: true}}
      },
      opts: [api_key: "test-key", reasoning_effort: :high],
      expected: %{
        requested_mode: :enabled,
        requested_effort: :high,
        effective_mode: :enabled,
        effective_effort: :high
      }
    },
    %{
      name: "Groq",
      provider_mod: ReqLLM.Providers.Groq,
      model: %{
        provider: :groq,
        id: "llama-3.3-70b-versatile",
        capabilities: %{reasoning: %{enabled: true}}
      },
      opts: [api_key: "test-key", reasoning_effort: :high],
      expected: %{
        requested_mode: :enabled,
        requested_effort: :high,
        effective_mode: :enabled,
        effective_effort: :high
      }
    },
    %{
      name: "OpenRouter",
      provider_mod: ReqLLM.Providers.OpenRouter,
      model: %{
        provider: :openrouter,
        id: "openai/o3-mini",
        capabilities: %{reasoning: %{enabled: true}}
      },
      opts: [api_key: "test-key", reasoning_effort: :medium],
      expected: %{
        requested_mode: :enabled,
        requested_effort: :medium,
        effective_mode: :enabled,
        effective_effort: :medium
      }
    },
    %{
      name: "Alibaba",
      provider_mod: ReqLLM.Providers.Alibaba,
      model: %{
        provider: :alibaba,
        id: "qwen3-max",
        capabilities: %{reasoning: %{enabled: true}}
      },
      opts: [api_key: "test-key", enable_thinking: true, thinking_budget: 4096],
      expected: %{
        requested_mode: :enabled,
        requested_budget_tokens: 4096,
        effective_mode: :enabled,
        effective_budget_tokens: 4096
      }
    },
    %{
      name: "Z.AI",
      provider_mod: ReqLLM.Providers.Zai,
      model: %{
        provider: :zai,
        id: "glm-4.6",
        capabilities: %{reasoning: %{enabled: true}}
      },
      opts: [api_key: "test-key", provider_options: [thinking: %{type: "enabled"}]],
      expected: %{
        requested_mode: :enabled,
        effective_mode: :enabled
      }
    },
    %{
      name: "Z.AI Coder",
      provider_mod: ReqLLM.Providers.ZaiCoder,
      model: %{
        provider: :zai_coder,
        id: "glm-4.6",
        capabilities: %{reasoning: %{enabled: true}}
      },
      opts: [api_key: "test-key", provider_options: [thinking: %{type: "enabled"}]],
      expected: %{
        requested_mode: :enabled,
        effective_mode: :enabled
      }
    }
  ]

  for test_case <- @reasoning_cases do
    @test_case test_case
    test "#{@test_case.name} telemetry normalization uses prepared provider requests" do
      reasoning = reasoning_snapshot(@test_case.provider_mod, @test_case.model, @test_case.opts)

      assert reasoning[:supported?] == true
      assert reasoning[:requested?] == (@test_case.expected[:requested_mode] == :enabled)
      assert reasoning[:effective?] == (@test_case.expected[:effective_mode] == :enabled)

      Enum.each(@test_case.expected, fn {key, expected} ->
        assert Map.fetch!(reasoning, key) == expected
      end)
    end
  end

  defp reasoning_snapshot(provider_mod, model_attrs, opts) do
    model = ReqLLM.model!(model_attrs)
    {:ok, request} = provider_mod.prepare_request(:chat, model, "Hello", opts)

    request
    |> materialize_request_body()
    |> Telemetry.handle_request()
    |> ReqLLM.Telemetry.request_context()
    |> ReqLLM.Telemetry.reasoning_metadata()
    |> Map.fetch!(:reasoning)
  end

  defp materialize_request_body(%Req.Request{request_steps: request_steps} = request) do
    case request_steps[:llm_encode_body] do
      nil ->
        cond do
          match?({:json, _}, request.body) ->
            {:json, body} = request.body
            %{request | body: Jason.encode!(body)}

          request.options[:json] ->
            %{request | body: Jason.encode!(request.options[:json])}

          true ->
            request
        end

      encode_step ->
        encode_step.(request)
    end
  end
end

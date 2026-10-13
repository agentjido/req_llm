defmodule ReqLLM.Providers.ClaudePlatformReasoningTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Providers.{AmazonBedrock, Anthropic, Azure, GoogleVertex}
  alias ReqLLM.Providers.Anthropic.PlatformReasoning

  defp model(provider) do
    id =
      if provider == :amazon_bedrock, do: "anthropic.claude-opus-4-6-v1", else: "claude-opus-4-6"

    LLMDB.Model.new!(%{
      provider: provider,
      id: id,
      capabilities: %{
        reasoning: %{
          enabled: true,
          thinking: %{types: ["adaptive"]},
          effort: %{supported: true, values: ["low", "medium", "high", "max"]}
        }
      }
    })
  end

  test "adaptive effort matches native Anthropic across cloud providers" do
    for provider <- [Azure, GoogleVertex, AmazonBedrock],
        effort <- [:minimal, :low, :medium, :high, :xhigh, :max, :default],
        nested <- [false, true] do
      model = model(provider.provider_id())

      input =
        if nested,
          do: [provider_options: [reasoning_effort: effort]],
          else: [reasoning_effort: effort]

      input = Keyword.merge(input, temperature: 0.5, top_p: 0.8, top_k: 20, max_tokens: 512)
      opts = ReqLLM.Provider.Options.process!(provider, :chat, model, input)
      fields = opts[:provider_options][:additional_model_request_fields]
      {native, []} = Anthropic.translate_options(:chat, model, reasoning_effort: effort)

      assert fields.thinking == native[:thinking]
      assert fields.output_config == native[:output_config]
      assert opts[:max_tokens] == 512
      refute Keyword.has_key?(opts, :temperature)
      refute Keyword.has_key?(opts, :top_p)
      refute Keyword.has_key?(opts, :top_k)

      formatter =
        case provider do
          Azure -> Azure.Anthropic
          GoogleVertex -> GoogleVertex.Anthropic
          AmazonBedrock -> AmazonBedrock.Anthropic
        end

      for stream <- [false, true] do
        body =
          formatter.format_request(
            model.id,
            Context.new([Context.user("Hello")]),
            Keyword.merge(opts, operation: :chat, stream: stream)
          )

        assert body.thinking == native[:thinking]
        assert body.output_config.effort == native[:output_config][:effort]
      end
    end
  end

  test "sparse hosted metadata preserves native max and xhigh levels" do
    native = ReqLLM.model!("anthropic:claude-opus-4-7")

    for {provider, id} <- [
          {Azure, "claude-opus-4-7"},
          {GoogleVertex, "claude-opus-4-7@default"},
          {AmazonBedrock, "us.anthropic.claude-opus-4-7"}
        ],
        effort <- [:xhigh, :max] do
      model =
        LLMDB.Model.new!(%{
          provider: provider.provider_id(),
          id: id,
          capabilities: %{reasoning: %{enabled: true}}
        })

      opts = ReqLLM.Provider.Options.process!(provider, :chat, model, reasoning_effort: effort)
      {native_opts, []} = Anthropic.translate_options(:chat, native, reasoning_effort: effort)

      assert opts[:provider_options][:additional_model_request_fields][:output_config] ==
               native_opts[:output_config]
    end
  end

  test "explicit platform effort limits override native metadata" do
    model =
      LLMDB.Model.new!(%{
        provider: :google_vertex,
        id: "claude-opus-4-7@default",
        capabilities: %{
          reasoning: %{
            enabled: true,
            effort: %{supported: true, values: ["low", "medium", "high"]}
          }
        }
      })

    opts = ReqLLM.Provider.Options.process!(GoogleVertex, :chat, model, reasoning_effort: :max)

    assert opts[:provider_options][:additional_model_request_fields][:output_config][:effort] ==
             "high"
  end

  test "Vertex structured output preserves adaptive thinking and effort" do
    model = model(:google_vertex)
    {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string, required: true])

    opts =
      ReqLLM.Provider.Options.process!(GoogleVertex, :object, model,
        reasoning_effort: :high,
        provider_options: [anthropic_structured_output_mode: :json_schema]
      )

    opts = GoogleVertex.Anthropic.maybe_clean_thinking_after_translation(opts, :object)
    opts = Keyword.merge(opts, operation: :object, compiled_schema: schema)

    body =
      GoogleVertex.Anthropic.format_request(
        model.id,
        Context.new([Context.user("Return a name")]),
        opts
      )

    assert body.thinking.type == "adaptive"
    assert body.output_config.effort == "high"
    assert body.output_config.format.type == "json_schema"
    refute Map.has_key?(body, :tools)
  end

  test "adaptive token budgets do not inflate max_tokens and use native effort mapping" do
    for provider <- [Azure, GoogleVertex, AmazonBedrock] do
      model = model(provider.provider_id())

      opts =
        ReqLLM.Provider.Options.process!(provider, :chat, model,
          reasoning_token_budget: 8000,
          max_tokens: 512
        )

      fields = opts[:provider_options][:additional_model_request_fields]
      assert fields.thinking.type == "adaptive"
      refute Map.has_key?(fields.thinking, :budget_tokens)
      assert fields.output_config.effort == "high"
      assert opts[:max_tokens] == 512
    end
  end

  test "preserves existing string-keyed output configuration without duplicate JSON keys" do
    opts = [
      reasoning_effort: :high,
      provider_options: [
        additional_model_request_fields: %{
          "output_config" => %{"effort" => "low", "format" => %{"type" => "json_schema"}},
          "other" => true
        }
      ]
    ]

    {opts, []} = GoogleVertex.pre_validate_options(:chat, model(:google_vertex), opts)
    fields = opts[:provider_options][:additional_model_request_fields]
    refute Map.has_key?(fields, "output_config")
    refute Map.has_key?(fields.output_config, "effort")
    assert fields.output_config.effort == "high"
    assert fields.output_config.format["type"] == "json_schema"
    assert fields["other"]
  end

  test "prepared and streaming requests carry adaptive effort on all cloud providers" do
    context = Context.new([Context.user("Hello")])

    for {provider, credentials} <- [
          {Azure,
           [
             api_key: "test-key",
             base_url: "https://example.services.ai.azure.com/anthropic",
             deployment: "claude-opus-4-6"
           ]},
          {GoogleVertex,
           [access_token: "test-token", project_id: "test-project", region: "us-east5"]},
          {AmazonBedrock,
           [access_key_id: "AKIATEST", secret_access_key: "secretTEST", region: "us-east-1"]}
        ] do
      model = model(provider.provider_id())
      opts = Keyword.merge(credentials, reasoning_effort: :high, max_tokens: 512)
      {:ok, request} = provider.prepare_request(:chat, model, context, opts)
      request = Req.Steps.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(request)
      assert body["thinking"]["type"] == "adaptive"
      assert body["output_config"]["effort"] == "high"
      assert body["max_tokens"] == 512

      {:ok, request} = provider.attach_stream(model, context, opts, ReqLLM.Finch)
      body = Jason.decode!(request.body)
      assert body["thinking"]["type"] == "adaptive"
      assert body["output_config"]["effort"] == "high"
      assert body["max_tokens"] == 512
    end
  end

  test "removes reasoning for forced structured tools and preserves other fields" do
    opts = [
      provider_options: [
        additional_model_request_fields: %{
          thinking: %{type: "adaptive"},
          output_config: %{effort: "high", format: %{type: "json_schema"}},
          other: true
        }
      ]
    ]

    cleaned = PlatformReasoning.maybe_clean_thinking_after_translation(opts, :object)
    fields = cleaned[:provider_options][:additional_model_request_fields]
    refute Map.has_key?(fields, :thinking)
    refute Map.has_key?(fields.output_config, :effort)
    assert fields.output_config.format.type == "json_schema"
    assert fields.other
  end
end

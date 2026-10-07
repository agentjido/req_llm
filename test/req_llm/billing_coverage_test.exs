defmodule ReqLLM.BillingCoverageTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Usage.{Cost, Normalize}

  defmodule InProcess do
    def stream_transport(_, _), do: :in_process

    def attach_in_process_stream(_, _, opts) do
      chunks = [
        ReqLLM.StreamChunk.text("done"),
        ReqLLM.StreamChunk.meta(%{usage: opts[:test_usage], finish_reason: :stop})
      ]

      {:ok, %ReqLLM.Provider.InProcessStream{stream: chunks}}
    end
  end

  def handle_telemetry(event, _, metadata, owner),
    do: send(owner, {:billing_telemetry, event, metadata})

  defp token_model do
    %LLMDB.Model{
      provider: :test,
      id: "probe",
      pricing: %{
        components: [
          %{id: "token.input", kind: "token", per: 1_000_000, rate: 1.0},
          %{id: "token.output", kind: "token", per: 1_000_000, rate: 2.0},
          %{id: "token.cache_read", kind: "token", per: 1_000_000, rate: 0.1},
          %{id: "token.cache_write", kind: "token", per: 1_000_000, rate: 0.2}
        ]
      }
    }
  end

  test "positive tool usage requires a matching tool and unit" do
    usage = %{
      input_tokens: 1000,
      output_tokens: 100,
      tool_usage: %{web_search: %{count: 2, unit: :query}}
    }

    model = token_model()
    assert Cost.apply(usage, model).pricing.status == :unknown

    for {tool, unit, expected} <- [
          {"other_tool", :query, :unknown},
          {"web_search", :source, :unknown},
          {"web_search", :query, :priced}
        ] do
      rate = %{id: "tool.search", kind: "tool", tool: tool, unit: unit, per: 1, rate: 0.0}

      priced =
        Cost.apply(usage, %{model | pricing: %{components: model.pricing.components ++ [rate]}})

      assert priced.pricing.status == expected
      if expected == :priced, do: assert(priced.cost.tools == 0.0)
    end

    usage = %{usage | tool_usage: %{"web_search" => %{"count" => 0, "unit" => "query"}}}
    assert Cost.apply(usage, model).pricing.status == :priced
  end

  test "positive image usage requires a matching size or an image token tariff" do
    rate = %{
      id: "image.generated",
      kind: "image",
      size_class: "1024x1024:medium",
      per: 1,
      rate: 0.1
    }

    model = %LLMDB.Model{provider: :test, id: "probe", pricing: %{components: [rate]}}

    usage = %{
      input_tokens: 0,
      output_tokens: 0,
      image_usage: %{generated: %{count: 1, size_class: "1536x1024:medium"}}
    }

    assert Cost.apply(usage, model).pricing.status == :unknown

    for value <- [0.0, 0.25] do
      matching = %{rate | size_class: "1536x1024:medium", rate: value}
      priced = Cost.apply(usage, %{model | pricing: %{components: [matching]}})
      assert priced.pricing.status == :priced
      assert priced.total_cost == value
    end

    assert Cost.apply(%{usage | image_usage: %{generated: %{count: 0}}}, model).pricing.status ==
             :priced

    assert Cost.apply(usage, token_model()).pricing.status == :unknown
  end

  test "all extracted cache aliases share raw count validation" do
    readers = [
      &Map.put(&1, :cache_read_tokens, &2),
      &Map.put(&1, "cache_read_input_tokens", &2),
      &Map.put(&1, :cacheReadInputTokens, &2),
      &Map.put(&1, "cacheReadInputTokens", &2),
      &Map.put(&1, :cacheReadInputTokenCount, &2),
      &Map.put(&1, "cacheReadInputTokenCount", &2),
      &Map.put(&1, :cached_input, &2),
      &Map.put(&1, :prompt_tokens_details, %{cached_tokens: &2}),
      &Map.put(&1, "prompt_tokens_details", %{"cached_tokens" => &2}),
      &Map.put(&1, :input_tokens_details, %{cached_tokens: &2})
    ]

    writers = [
      &Map.put(&1, :cache_write_tokens, &2),
      &Map.put(&1, "cache_creation_input_tokens", &2),
      &Map.put(&1, :cache_creation, &2),
      &Map.put(&1, :cache_creation_tokens, &2),
      &Map.put(&1, :cacheWriteInputTokens, &2),
      &Map.put(&1, "cacheWriteInputTokens", &2),
      &Map.put(&1, :cacheWriteInputTokenCount, &2),
      &Map.put(&1, "cacheWriteInputTokenCount", &2),
      &Map.put(&1, :cache_write_input_tokens, &2),
      &Map.put(&1, :prompt_tokens_details, %{cache_write_tokens: &2}),
      &Map.put(&1, "prompt_tokens_details", %{"cache_write_tokens" => &2}),
      &Map.put(&1, :input_tokens_details, %{cache_write_tokens: &2})
    ]

    for set_field <- readers ++ writers, raw <- [false, "bad", -1, 2.5, "2", 2] do
      usage = %{input_tokens: 100, output_tokens: 10} |> set_field.(raw) |> Normalize.normalize()
      valid? = raw in ["2", 2]
      assert usage.billing_usage_complete == valid?

      assert Cost.apply(usage, token_model()).pricing.status ==
               if(valid?, do: :priced, else: :unknown)

      assert usage.cache_read_tokens >= 0
      assert usage.cache_write_tokens >= 0
    end
  end

  test "cache creation groups remain valid and malformed group values remain unknown" do
    for raw <- [2, -1, 2.5, "bad"] do
      usage =
        Normalize.normalize(%{
          input_tokens: 100,
          output_tokens: 10,
          cache_creation: %{ephemeral_5m_input_tokens: raw}
        })

      assert usage.billing_usage_complete == (raw == 2)
    end

    usage = Normalize.normalize(%{input_tokens: 100, output_tokens: 10, cached_tokens: %{bad: 2}})
    refute usage.billing_usage_complete
    assert usage.cache_read_tokens == 0
    assert Cost.apply(usage, token_model()).pricing.status == :unknown
  end

  test "unpriced compute units keep billing unknown" do
    model = token_model()

    for compute_units <- [1, "1", "unknown", -1, 0.0] do
      usage =
        Normalize.normalize(%{
          input_tokens: 100,
          output_tokens: 10,
          compute_units: compute_units
        })

      refute usage.billing_usage_complete
      assert Cost.apply(usage, model).pricing.status == :unknown
      refute Map.has_key?(Cost.apply(usage, model), :total_cost)
    end
  end

  test "false cache counts and claimed completeness cannot produce a price" do
    for field <- [:cached_tokens, :cacheReadInputTokens, "cacheWriteInputTokens"],
        value <- [false, "bad", -1, 2.5],
        flag <- [:billing_usage_complete, "billing_usage_complete"] do
      usage =
        %{input_tokens: 100, output_tokens: 10}
        |> Map.put(field, value)
        |> Map.put(flag, true)
        |> Normalize.normalize()

      refute usage.billing_usage_complete
      assert Cost.apply(usage, token_model()).pricing.status == :unknown
      refute Normalize.normalize(usage).billing_usage_complete
    end
  end

  test "malformed tool names and quantities remain unknown through normalization" do
    model = token_model()
    rate = %{id: "tool.search", kind: "tool", tool: "web_search", per: 1, rate: 0.1}
    model = %{model | pricing: %{components: model.pricing.components ++ [rate]}}

    for tools <- [
          %{%{bad: "name"} => %{count: 1}},
          %{["web_search"] => %{count: 1}},
          %{web_search: %{count: false}},
          %{web_search: %{count: 1, unit: %{bad: "unit"}}},
          "bad"
        ] do
      usage = %{input_tokens: 100, output_tokens: 10, tool_usage: tools}

      for usage <- [usage, Normalize.normalize(usage)] do
        assert Cost.apply(usage, model).pricing.status == :unknown
        refute Map.has_key?(Cost.apply(usage, model), :total_cost)
      end
    end

    usage = %{input_tokens: 100, output_tokens: 10, tool_usage: %{web_search: %{count: 1}}}
    malformed_rate = %{rate | tool: %{bad: "tariff name"}}

    model = %{
      model
      | pricing: %{components: token_model().pricing.components ++ [malformed_rate]}
    }

    assert Cost.apply(usage, model).pricing.status == :unknown
  end

  test "false and malformed image quantities cannot be priced as zero" do
    model = token_model()
    rate = %{id: "image.generated", kind: "image", per: 1, rate: 0.1}
    model = %{model | pricing: %{components: model.pricing.components ++ [rate]}}

    for images <- [%{generated: %{count: false}}, %{generated: "bad"}, "bad"] do
      usage = %{input_tokens: 100, output_tokens: 10, image_usage: images}

      for usage <- [usage, Normalize.normalize(usage)] do
        assert Cost.apply(usage, model).pricing.status == :unknown
      end
    end
  end

  test "sync and stream usage retain unknown pricing for incomplete tool and image tariffs" do
    model = token_model()

    for usage <- [
          %{
            input_tokens: 100,
            output_tokens: 10,
            tool_usage: %{search: %{count: 1, unit: :call}}
          },
          %{
            input_tokens: 100,
            output_tokens: 10,
            image_usage: %{generated: %{count: 1, size_class: "1536x1024:medium"}}
          }
        ] do
      body = %ReqLLM.Response{
        id: "billing",
        model: model.id,
        context: ReqLLM.Context.new([]),
        usage: usage
      }

      request = %Req.Request{options: %{}, private: %{req_llm_model: model}}
      {_, sync} = ReqLLM.Step.Usage.handle({request, %Req.Response{body: body}})
      assert sync.body.usage.pricing.status == :unknown
      refute Map.has_key?(sync.body.usage, :total_cost)
      assert sync.private.req_llm.usage.pricing.status == :unknown

      assert {:ok, stream} =
               ReqLLM.Streaming.start_stream(InProcess, model, ReqLLM.Context.new([]),
                 test_usage: usage
               )

      on_exit(fn -> ReqLLM.StreamResponse.close(stream) end)
      assert {:ok, response} = ReqLLM.StreamResponse.to_response(stream)
      assert response.usage.pricing.status == :unknown
      refute Map.has_key?(response.usage, :total_cost)
    end
  end

  test "public image generation and stop telemetry reject a tariff for another size" do
    id = "billing-size-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(id, [:req_llm, :request, :stop], &__MODULE__.handle_telemetry/4, self())

    on_exit(fn -> :telemetry.detach(id) end)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "created" => 1,
        "data" => [%{"b64_json" => Base.encode64("image")}]
      })
    end)

    model = %LLMDB.Model{
      provider: :openai,
      id: "gpt-image-1.5",
      modalities: %{output: [:image]},
      pricing: %{
        components: [
          %{
            id: "image.generated",
            kind: "image",
            size_class: "1024x1024:medium",
            per: 1,
            rate: 0.1
          }
        ]
      }
    }

    assert {:ok, response} =
             ReqLLM.generate_image(model, "A square",
               api_key: "probe",
               size: "1536x1024",
               quality: :medium,
               req_http_options: [plug: {Req.Test, __MODULE__}]
             )

    assert response.usage.pricing.status == :unknown
    refute Map.has_key?(response.usage, :total_cost)
    assert_receive {:billing_telemetry, [:req_llm, :request, :stop], metadata}
    assert metadata.usage.pricing.status == :unknown
    refute Map.has_key?(metadata.usage, :total_cost)
  end
end

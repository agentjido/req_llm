defmodule ReqLLM.Step.UsageTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Step.Usage

  # Shared helpers
  defp mock_request(options \\ [], private \\ %{}) do
    %Req.Request{options: options, private: private}
  end

  defp mock_response(body, private \\ %{}) do
    %Req.Response{body: body, private: private}
  end

  defp assert_request_preserved(original_req, updated_req, additional_checks) do
    for {field, value} <- Map.from_struct(original_req) do
      case field do
        :response_steps ->
          for check <- additional_checks, do: check.(updated_req)

        :private ->
          # Allow private to be updated when model is provided
          :ok

        _ ->
          assert Map.get(updated_req, field) == value
      end
    end
  end

  defp setup_telemetry do
    test_pid = self()
    ref = System.unique_integer([:positive])
    handler_id = "test-usage-handler-#{ref}"

    :telemetry.attach(
      handler_id,
      [:req_llm, :token_usage],
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    {:ok, test_pid: test_pid}
  end

  describe "attach/2" do
    test "attaches usage step and preserves request structure" do
      {:ok, model} = ReqLLM.model("openai:gpt-4")

      request = %Req.Request{
        options: [test: "value"],
        headers: [{"content-type", "application/json"}]
      }

      updated_request = Usage.attach(request, model)

      assert_request_preserved(request, updated_request, [
        fn req -> assert Keyword.has_key?(req.response_steps, :llm_usage) end,
        fn req -> assert req.response_steps[:llm_usage] == (&Usage.handle/1) end
      ])

      assert updated_request.private[:req_llm_model] == model
    end

    test "handles nil model gracefully" do
      request = mock_request()
      updated_request = Usage.attach(request, nil)

      assert Keyword.has_key?(updated_request.response_steps, :llm_usage)
      assert updated_request.private[:req_llm_model] == nil
    end
  end

  describe "handle/1 - usage extraction and processing" do
    setup do
      setup_telemetry()
    end

    @usage_formats [
      # {format_name, response_body, expected_input, expected_output, expected_reasoning}
      {"OpenAI format", %{"usage" => %{"prompt_tokens" => 100, "completion_tokens" => 50}}, 100,
       50, 0},
      {"OpenAI with reasoning",
       %{
         "usage" => %{
           "prompt_tokens" => 100,
           "completion_tokens" => 50,
           "completion_tokens_details" => %{"reasoning_tokens" => 25}
         }
       }, 100, 50, 25},
      {"Anthropic format", %{"usage" => %{"input_tokens" => 200, "output_tokens" => 75}}, 200, 75,
       0},
      {"Direct tokens", %{"prompt_tokens" => 150, "completion_tokens" => 80}, 150, 80, 0},
      {"Alt direct tokens", %{"input_tokens" => 120, "output_tokens" => 60}, 120, 60, 0}
    ]

    for {format_name, response_body, expected_input, expected_output, expected_reasoning} <-
          @usage_formats do
      test "extracts usage from #{format_name}" do
        model = %LLMDB.Model{provider: :test, id: "test-model"}
        request = mock_request(model: model)
        response = mock_response(unquote(Macro.escape(response_body)))

        {_req, updated_resp} = Usage.handle({request, response})

        usage_data = updated_resp.private[:req_llm][:usage]
        assert usage_data.tokens.input == unquote(expected_input)
        assert usage_data.tokens.output == unquote(expected_output)
        assert usage_data.tokens.reasoning == unquote(expected_reasoning)
      end
    end

    test "emits telemetry and calculates cost" do
      model = %LLMDB.Model{provider: :openai, id: "gpt-4", cost: %{input: 0.01, output: 0.03}}
      request = mock_request(model: model)
      response = mock_response(%{"usage" => %{"prompt_tokens" => 100, "completion_tokens" => 50}})

      {_req, updated_resp} = Usage.handle({request, response})

      usage_data = updated_resp.private[:req_llm][:usage]
      assert usage_data.cost == 0.000003

      assert_receive {:telemetry_event, [:req_llm, :token_usage], measurements, metadata}
      assert measurements.cost == 0.000003
      assert metadata.model == model
    end

    test "preserves existing private data" do
      model = %LLMDB.Model{provider: :test, id: "test-model"}
      request = mock_request(model: model)
      existing_private = %{req_llm: %{other_data: "preserved"}, other_key: "also_preserved"}

      response =
        mock_response(
          %{"usage" => %{"prompt_tokens" => 100, "completion_tokens" => 50}},
          existing_private
        )

      {_req, updated_resp} = Usage.handle({request, response})

      assert updated_resp.private[:req_llm][:other_data] == "preserved"
      assert updated_resp.private[:other_key] == "also_preserved"
      assert updated_resp.private[:req_llm][:usage] != nil
    end
  end

  describe "handle/1 - cost calculation" do
    @cost_scenarios [
      # {description, cost_map, input_tokens, output_tokens, expected_cost}
      {"atom keys", %{input: 0.003, output: 0.015}, 1000, 500, 0.000011},
      {"string keys", %{"input" => 0.002, "output" => 0.004}, 1000, 1000, 0.000006},
      {"no cost", nil, 1000, 500, nil},
      {"incomplete cost", %{input: 0.002}, 100, 50, nil}
    ]

    for {description, cost_map, input_tokens, output_tokens, expected_cost} <- @cost_scenarios do
      test "handles cost calculation: #{description}" do
        model = %LLMDB.Model{
          provider: :test,
          id: "test-model",
          cost: unquote(Macro.escape(cost_map))
        }

        request = mock_request(model: model)

        response =
          mock_response(%{
            "usage" => %{
              "prompt_tokens" => unquote(input_tokens),
              "completion_tokens" => unquote(output_tokens)
            }
          })

        {_req, updated_resp} = Usage.handle({request, response})

        usage_data = updated_resp.private[:req_llm][:usage]
        assert usage_data.cost == unquote(expected_cost)
      end
    end

    test "rounds cost to 6 decimal places" do
      model = %LLMDB.Model{
        provider: :test,
        id: "test-model",
        cost: %{input: 0.0033333, output: 0.0066666}
      }

      request = mock_request(model: model)

      response =
        mock_response(%{"usage" => %{"prompt_tokens" => 333, "completion_tokens" => 666}})

      {_req, updated_resp} = Usage.handle({request, response})

      usage_data = updated_resp.private[:req_llm][:usage]
      assert is_float(usage_data.cost)
      cost_str = Float.to_string(usage_data.cost)
      decimal_places = String.split(cost_str, ".") |> List.last() |> String.length()
      assert decimal_places <= 6
    end
  end

  describe "handle/1 - model resolution" do
    test "prefers model from private over options" do
      private_model =
        %LLMDB.Model{
          provider: :anthropic,
          id: "claude-3-5-sonnet",
          cost: %{input: 0.003, output: 0.015}
        }

      options_model = %LLMDB.Model{
        provider: :openai,
        id: "gpt-4",
        cost: %{input: 0.01, output: 0.03}
      }

      request = %Req.Request{
        private: %{req_llm_model: private_model},
        options: [model: options_model]
      }

      response = mock_response(%{"usage" => %{"input_tokens" => 1000, "output_tokens" => 1000}})

      {_req, updated_resp} = Usage.handle({request, response})

      usage_data = updated_resp.private[:req_llm][:usage]
      # Should use private_model's pricing
      assert usage_data.cost == 0.000018
    end

    @model_sources [
      {"from private", %{req_llm_model: %LLMDB.Model{provider: :test, id: "test"}}, []},
      {"from options", %{}, [model: %LLMDB.Model{provider: :test, id: "test"}]}
    ]

    for {source_name, private, options} <- @model_sources do
      test "finds model #{source_name}" do
        request = %Req.Request{
          private: unquote(Macro.escape(private)),
          options: unquote(Macro.escape(options))
        }

        response =
          mock_response(%{"usage" => %{"prompt_tokens" => 100, "completion_tokens" => 50}})

        {_req, updated_resp} = Usage.handle({request, response})

        usage_data = updated_resp.private[:req_llm][:usage]
        assert usage_data.tokens.input == 100
      end
    end
  end

  describe "handle/1 - error cases" do
    @error_scenarios [
      {"no usage data", %{"other_data" => "no usage here"}},
      {"nil response body", nil},
      {"non-map response body", "string body"},
      {"malformed usage data",
       %{"usage" => %{"prompt_tokens" => "not_a_number", "completion_tokens" => 50}}}
    ]

    for {description, response_body} <- @error_scenarios do
      test "handles #{description}" do
        model = %LLMDB.Model{provider: :test, id: "test-model"}
        request = mock_request(model: model)
        response = mock_response(unquote(Macro.escape(response_body)))

        {returned_req, returned_resp} = Usage.handle({request, response})

        if unquote(description) == "malformed usage data" do
          # Special case - malformed data still gets extracted
          usage_data = returned_resp.private[:req_llm][:usage]
          assert usage_data.tokens.input == "not_a_number"
          assert usage_data.cost == nil
        else
          # Should return unchanged
          assert returned_req == request
          assert returned_resp == response
        end
      end
    end

    test "returns unchanged when model cannot be found" do
      request = mock_request()
      response = mock_response(%{"usage" => %{"prompt_tokens" => 100, "completion_tokens" => 50}})

      {returned_req, returned_resp} = Usage.handle({request, response})

      assert returned_req == request
      assert returned_resp == response
    end

    test "handles invalid model in options" do
      request = mock_request(id: "not_a_model_struct")
      response = mock_response(%{"usage" => %{"prompt_tokens" => 100, "completion_tokens" => 50}})

      {returned_req, returned_resp} = Usage.handle({request, response})

      assert returned_req == request
      assert returned_resp == response
    end
  end

  describe "handle/1 - reasoning token edge cases" do
    @reasoning_scenarios [
      {"valid reasoning tokens", 35, 35},
      {"zero reasoning tokens", 0, 0},
      {"missing reasoning tokens", nil, 0},
      {"non-integer reasoning tokens", "not_a_number", 0}
    ]

    for {description, reasoning_value, expected_reasoning} <- @reasoning_scenarios do
      test "handles #{description}" do
        {:ok, model} = ReqLLM.model("openai:gpt-4")
        request = mock_request(model: model)

        response_body = %{
          "usage" => %{
            "prompt_tokens" => 100,
            "completion_tokens" => 50
          }
        }

        response_body =
          case unquote(reasoning_value) do
            nil ->
              response_body

            val ->
              response_body
              |> put_in(["usage", "completion_tokens_details"], %{})
              |> put_in(["usage", "completion_tokens_details", "reasoning_tokens"], val)
          end

        response = mock_response(response_body)

        {_req, updated_resp} = Usage.handle({request, response})

        usage_data = updated_resp.private[:req_llm][:usage]
        assert usage_data.tokens.reasoning == unquote(expected_reasoning)
      end
    end
  end

  describe "handle/1 - cached tokens support" do
    setup do
      setup_telemetry()
    end

    test "extracts cached tokens from OpenAI usage format" do
      model = %LLMDB.Model{
        provider: :openai,
        id: "gpt-4",
        cost: %{input: 0.01, output: 0.03, cached_input: 0.005}
      }

      request = mock_request(model: model)

      # OpenAI format with cached tokens in prompt_tokens_details
      response_body = %{
        "usage" => %{
          "prompt_tokens" => 2006,
          "completion_tokens" => 300,
          "total_tokens" => 2306,
          "prompt_tokens_details" => %{
            "cached_tokens" => 1920
          },
          "completion_tokens_details" => %{
            "reasoning_tokens" => 0
          }
        }
      }

      response = mock_response(response_body)
      {_req, updated_resp} = Usage.handle({request, response})

      usage_data = updated_resp.private[:req_llm][:usage]
      assert usage_data.tokens.input == 2006
      assert usage_data.tokens.output == 300
      assert usage_data.tokens.reasoning == 0
      assert usage_data.tokens.cached_input == 1920

      # Check cost calculation with cached vs uncached split
      # Uncached: 86 tokens * 0.01 / 1000000 = 0.00000086
      # Cached: 1920 tokens * 0.005 / 1000000 = 0.0000096
      # Input cost: 0.00000086 + 0.0000096 = 0.000010460
      # Output cost: 300 * 0.03 / 1000000 = 0.000009
      # Total: 0.000019460
      expected_input_cost = Float.round((86 * 0.01 + 1920 * 0.005) / 1_000_000, 6)
      expected_output_cost = Float.round(300 * 0.03 / 1_000_000, 6)
      expected_total_cost = Float.round(expected_input_cost + expected_output_cost, 6)

      assert usage_data.cost == expected_total_cost
      assert usage_data.input_cost == expected_input_cost
      assert usage_data.output_cost == expected_output_cost
    end

    test "handles cached tokens without cached_input rate (uses input rate)" do
      model = %LLMDB.Model{provider: :openai, id: "gpt-4", cost: %{input: 0.01, output: 0.03}}
      request = mock_request(model: model)

      response_body = %{
        "usage" => %{
          "prompt_tokens" => 1000,
          "completion_tokens" => 100,
          "prompt_tokens_details" => %{"cached_tokens" => 500}
        }
      }

      response = mock_response(response_body)
      {_req, updated_resp} = Usage.handle({request, response})

      usage_data = updated_resp.private[:req_llm][:usage]
      assert usage_data.tokens.cached_input == 500

      # Both cached and uncached should use input rate when cached_input not specified
      # Input cost: 1000 * 0.01 / 1000000 = 0.00001 (same as before)
      expected_input_cost = Float.round(1000 * 0.01 / 1_000_000, 6)
      expected_output_cost = Float.round(100 * 0.03 / 1_000_000, 6)

      assert usage_data.input_cost == expected_input_cost
      assert usage_data.output_cost == expected_output_cost
    end

    test "handles Response struct with cached tokens" do
      model = %LLMDB.Model{
        provider: :openai,
        id: "gpt-4",
        cost: %{input: 0.01, output: 0.03, cached_input: 0.005}
      }

      request = mock_request(model: model)

      response_body = %ReqLLM.Response{
        id: "test-id",
        model: model,
        context: %ReqLLM.Context{messages: []},
        message: nil,
        usage: %{
          input_tokens: 1000,
          output_tokens: 200,
          total_tokens: 1200,
          # Simulate cached tokens already extracted by provider
          cached_tokens: 800
        },
        finish_reason: nil
      }

      response = mock_response(response_body)
      {_req, updated_resp} = Usage.handle({request, response})

      # Check Response.usage includes cached_tokens and correct costs
      response_usage = updated_resp.body.usage
      assert response_usage.input_tokens == 1000
      assert response_usage.output_tokens == 200
      assert response_usage.cached_tokens == 800

      # Cost calculation: uncached=200, cached=800
      # Input: (200*0.01 + 800*0.005)/1000000 = 0.000006
      # Output: 200*0.03/1000000 = 0.000006
      # Total: 0.000012
      expected_input_cost = Float.round((200 * 0.01 + 800 * 0.005) / 1_000_000, 6)
      expected_output_cost = Float.round(200 * 0.03 / 1_000_000, 6)

      assert response_usage.input_cost == expected_input_cost
      assert response_usage.output_cost == expected_output_cost
      assert response_usage.total_cost == expected_input_cost + expected_output_cost
    end

    test "uses cache_read pricing when cached_input not specified" do
      model = %LLMDB.Model{
        provider: :openai,
        id: "gpt-4",
        cost: %{input: 0.01, output: 0.03, cache_read: 0.005}
      }

      request = mock_request(model: model)

      response_body = %{
        "usage" => %{
          "prompt_tokens" => 1000,
          "completion_tokens" => 100,
          "prompt_tokens_details" => %{"cached_tokens" => 600}
        }
      }

      response = mock_response(response_body)
      {_req, updated_resp} = Usage.handle({request, response})

      usage_data = updated_resp.private[:req_llm][:usage]
      assert usage_data.tokens.input == 1000
      assert usage_data.tokens.output == 100
      assert usage_data.tokens.cached_input == 600

      # Cost calculation with cache_read fallback:
      # Uncached: 400 tokens * 0.01 / 1000000 = 0.000004
      # Cached: 600 tokens * 0.005 / 1000000 = 0.000003
      # Input cost: 0.000004 + 0.000003 = 0.000007
      # Output cost: 100 * 0.03 / 1000000 = 0.000003
      # Total: 0.00001
      expected_input_cost = Float.round((400 * 0.01 + 600 * 0.005) / 1_000_000, 6)
      expected_output_cost = Float.round(100 * 0.03 / 1_000_000, 6)
      expected_total_cost = Float.round(expected_input_cost + expected_output_cost, 6)

      assert usage_data.cost == expected_total_cost
      assert usage_data.input_cost == expected_input_cost
      assert usage_data.output_cost == expected_output_cost
    end

    test "handles edge cases with cached tokens" do
      model = %LLMDB.Model{
        provider: :openai,
        id: "gpt-4",
        cost: %{input: 0.01, output: 0.03, cached_input: 0.005}
      }

      request = mock_request(model: model)

      test_cases = [
        # Cached tokens > input tokens (should be clamped)
        %{
          "usage" => %{
            "prompt_tokens" => 100,
            "completion_tokens" => 50,
            "prompt_tokens_details" => %{"cached_tokens" => 150}
          }
        },
        # Cached tokens = 0
        %{
          "usage" => %{
            "prompt_tokens" => 100,
            "completion_tokens" => 50,
            "prompt_tokens_details" => %{"cached_tokens" => 0}
          }
        },
        # Non-integer cached tokens (should be converted)
        %{
          "usage" => %{
            "prompt_tokens" => 100,
            "completion_tokens" => 50,
            "prompt_tokens_details" => %{"cached_tokens" => 80.7}
          }
        }
      ]

      for {response_body, expected_cached} <- Enum.zip(test_cases, [100, 0, 80]) do
        response = mock_response(response_body)
        {_req, updated_resp} = Usage.handle({request, response})

        usage_data = updated_resp.private[:req_llm][:usage]
        assert usage_data.tokens.cached_input == expected_cached
      end
    end
  end

  describe "token clamping behavior" do
    setup do
      setup_telemetry()
    end

    test "clamps cached tokens when greater than input tokens" do
      model = %LLMDB.Model{
        provider: :openai,
        id: "gpt-4",
        cost: %{input: 0.01, output: 0.03, cached_input: 0.005}
      }

      request = mock_request(model: model)

      response_body = %{
        "usage" => %{
          "prompt_tokens" => 500,
          "completion_tokens" => 200,
          "prompt_tokens_details" => %{"cached_tokens" => 750}
        }
      }

      response = mock_response(response_body)
      {_req, updated_resp} = Usage.handle({request, response})

      usage_data = updated_resp.private[:req_llm][:usage]
      assert usage_data.tokens.input == 500
      assert usage_data.tokens.cached_input == 500

      # Cost should reflect clamped cached tokens: all input tokens are cached
      expected_input_cost = Float.round(500 * 0.005 / 1_000_000, 6)
      expected_output_cost = Float.round(200 * 0.03 / 1_000_000, 6)
      assert usage_data.input_cost == expected_input_cost
      assert usage_data.output_cost == expected_output_cost
    end

    test "clamps cached tokens when less than 0" do
      model = %LLMDB.Model{
        provider: :openai,
        id: "gpt-4",
        cost: %{input: 0.01, output: 0.03, cached_input: 0.005}
      }

      request = mock_request(model: model)

      response_body = %{
        "usage" => %{
          "prompt_tokens" => 300,
          "completion_tokens" => 150,
          "prompt_tokens_details" => %{"cached_tokens" => -50}
        }
      }

      response = mock_response(response_body)
      {_req, updated_resp} = Usage.handle({request, response})

      usage_data = updated_resp.private[:req_llm][:usage]
      assert usage_data.tokens.input == 300
      assert usage_data.tokens.cached_input == 0

      # Cost should reflect no cached tokens: all input tokens use regular rate
      expected_input_cost = Float.round(300 * 0.01 / 1_000_000, 6)
      assert usage_data.input_cost == expected_input_cost
      assert usage_data.output_cost == 0.000004
    end

    test "handles input tokens = 0 with cached tokens set to 0" do
      model = %LLMDB.Model{
        provider: :openai,
        id: "gpt-4",
        cost: %{input: 0.01, output: 0.03, cached_input: 0.005}
      }

      request = mock_request(model: model)

      response_body = %{
        "usage" => %{
          "prompt_tokens" => 0,
          "completion_tokens" => 100,
          "prompt_tokens_details" => %{"cached_tokens" => 25}
        }
      }

      response = mock_response(response_body)
      {_req, updated_resp} = Usage.handle({request, response})

      usage_data = updated_resp.private[:req_llm][:usage]
      assert usage_data.tokens.input == 0
      assert usage_data.tokens.cached_input == 0

      # No input cost, only output cost
      assert usage_data.input_cost == 0.0
      expected_output_cost = Float.round(100 * 0.03 / 1_000_000, 6)
      assert usage_data.output_cost == expected_output_cost
    end

    test "handles invalid cached token values by defaulting to 0" do
      model = %LLMDB.Model{
        provider: :openai,
        id: "gpt-4",
        cost: %{input: 0.01, output: 0.03, cached_input: 0.005}
      }

      request = mock_request(model: model)

      invalid_values = ["string", nil, %{invalid: "map"}, [1, 2, 3]]

      for invalid_value <- invalid_values do
        response_body = %{
          "usage" => %{
            "prompt_tokens" => 200,
            "completion_tokens" => 80,
            "prompt_tokens_details" => %{"cached_tokens" => invalid_value}
          }
        }

        response = mock_response(response_body)
        {_req, updated_resp} = Usage.handle({request, response})

        usage_data = updated_resp.private[:req_llm][:usage]
        assert usage_data.tokens.input == 200
        assert usage_data.tokens.cached_input == 0

        # Should use regular input rate for all tokens
        expected_input_cost = Float.round(200 * 0.01 / 1_000_000, 6)
        expected_output_cost = Float.round(80 * 0.03 / 1_000_000, 6)
        assert usage_data.input_cost == expected_input_cost
        assert usage_data.output_cost == expected_output_cost
      end
    end

    test "truncates float cached token values to integers" do
      model = %LLMDB.Model{
        provider: :openai,
        id: "gpt-4",
        cost: %{input: 0.01, output: 0.03, cached_input: 0.005}
      }

      request = mock_request(model: model)

      float_test_cases = [
        {123.45, 123},
        {67.89, 67},
        {0.9, 0},
        {999.1, 999}
      ]

      for {float_value, expected_int} <- float_test_cases do
        response_body = %{
          "usage" => %{
            "prompt_tokens" => 1000,
            "completion_tokens" => 100,
            "prompt_tokens_details" => %{"cached_tokens" => float_value}
          }
        }

        response = mock_response(response_body)
        {_req, updated_resp} = Usage.handle({request, response})

        usage_data = updated_resp.private[:req_llm][:usage]
        assert usage_data.tokens.input == 1000
        assert usage_data.tokens.cached_input == expected_int

        # Cost calculation should use truncated value
        uncached_tokens = 1000 - expected_int

        expected_input_cost =
          Float.round((uncached_tokens * 0.01 + expected_int * 0.005) / 1_000_000, 6)

        expected_output_cost = Float.round(100 * 0.03 / 1_000_000, 6)
        assert usage_data.input_cost == expected_input_cost
        assert usage_data.output_cost == expected_output_cost
      end
    end

    test "normal valid case with cached tokens between 0 and input tokens" do
      model = %LLMDB.Model{
        provider: :openai,
        id: "gpt-4",
        cost: %{input: 0.01, output: 0.03, cached_input: 0.005}
      }

      request = mock_request(model: model)

      response_body = %{
        "usage" => %{
          "prompt_tokens" => 800,
          "completion_tokens" => 300,
          "prompt_tokens_details" => %{"cached_tokens" => 400}
        }
      }

      response = mock_response(response_body)
      {_req, updated_resp} = Usage.handle({request, response})

      usage_data = updated_resp.private[:req_llm][:usage]
      assert usage_data.tokens.input == 800
      assert usage_data.tokens.cached_input == 400

      # Cost calculation: 400 uncached at 0.01, 400 cached at 0.005
      # 0.000004
      uncached_cost = 400 * 0.01 / 1_000_000
      # 0.000002
      cached_cost = 400 * 0.005 / 1_000_000
      expected_input_cost = Float.round(uncached_cost + cached_cost, 6)
      expected_output_cost = Float.round(300 * 0.03 / 1_000_000, 6)
      expected_total_cost = Float.round(expected_input_cost + expected_output_cost, 6)

      assert usage_data.input_cost == expected_input_cost
      assert usage_data.output_cost == expected_output_cost
      assert usage_data.cost == expected_total_cost

      # Verify telemetry includes clamped values
      assert_receive {:telemetry_event, [:req_llm, :token_usage], measurements, _metadata}
      assert measurements.cost == expected_total_cost
      assert measurements.input_cost == expected_input_cost
      assert measurements.output_cost == expected_output_cost
    end

    test "clamping works with Response struct usage" do
      model = %LLMDB.Model{
        provider: :openai,
        id: "gpt-4",
        cost: %{input: 0.01, output: 0.03, cached_input: 0.005}
      }

      request = mock_request(model: model)

      # Test Response struct with cached_tokens > input_tokens
      response_body = %ReqLLM.Response{
        id: "test-id",
        model: model,
        context: %ReqLLM.Context{messages: []},
        message: nil,
        usage: %{
          input_tokens: 250,
          output_tokens: 100,
          total_tokens: 350,
          cached_tokens: 400
        },
        finish_reason: nil
      }

      response = mock_response(response_body)
      {_req, updated_resp} = Usage.handle({request, response})

      # Check Response.usage has clamped cached_tokens
      response_usage = updated_resp.body.usage
      assert response_usage.input_tokens == 250
      assert response_usage.output_tokens == 100
      # Should be clamped to input_tokens
      assert response_usage.cached_tokens == 250

      # Cost should reflect all input tokens as cached
      expected_input_cost = Float.round(250 * 0.005 / 1_000_000, 6)
      expected_output_cost = Float.round(100 * 0.03 / 1_000_000, 6)

      assert response_usage.input_cost == expected_input_cost
      assert response_usage.output_cost == expected_output_cost
    end
  end

  describe "handle/1 - Response struct with cost breakdown" do
    setup do
      setup_telemetry()
    end

    test "extracts usage from Response struct and adds cost fields" do
      model = %LLMDB.Model{provider: :openai, id: "gpt-4", cost: %{input: 0.01, output: 0.03}}
      request = mock_request(model: model)

      response_body = %ReqLLM.Response{
        id: "test-id",
        model: model,
        context: %ReqLLM.Context{messages: []},
        message: nil,
        usage: %{input_tokens: 100, output_tokens: 50, total_tokens: 150},
        finish_reason: nil
      }

      response = mock_response(response_body)

      {_req, updated_resp} = Usage.handle({request, response})

      # Check private storage has breakdown
      usage_data = updated_resp.private[:req_llm][:usage]
      assert usage_data.tokens.input == 100
      assert usage_data.tokens.output == 50
      assert usage_data.cost == 0.000003
      assert usage_data.input_cost == 0.000001
      assert usage_data.output_cost == 0.000002
      assert usage_data.total_cost == 0.000003

      # Check Response.usage now includes cost fields
      response_usage = updated_resp.body.usage
      assert response_usage.input_tokens == 100
      assert response_usage.output_tokens == 50
      assert response_usage.total_tokens == 150
      assert response_usage.input_cost == 0.000001
      assert response_usage.output_cost == 0.000002
      assert response_usage.total_cost == 0.000003

      # Check telemetry includes breakdown
      assert_receive {:telemetry_event, [:req_llm, :token_usage], measurements, metadata}
      assert measurements.cost == 0.000003
      assert measurements.input_cost == 0.000001
      assert measurements.output_cost == 0.000002
      assert measurements.total_cost == 0.000003
      assert metadata.model == model
    end

    test "handles Response struct without cost data gracefully" do
      # no cost map
      {:ok, model} = ReqLLM.model("openai:gpt-4")
      request = mock_request(model: model)

      response_body = %ReqLLM.Response{
        id: "test-id",
        model: model,
        context: %ReqLLM.Context{messages: []},
        message: nil,
        usage: %{input_tokens: 100, output_tokens: 50, total_tokens: 150},
        finish_reason: nil
      }

      response = mock_response(response_body)

      {_req, updated_resp} = Usage.handle({request, response})

      # Check no cost fields are added
      response_usage = updated_resp.body.usage
      assert response_usage.input_tokens == 100
      assert response_usage.output_tokens == 50
      assert response_usage.total_tokens == 150
      refute Map.has_key?(response_usage, :input_cost)
      refute Map.has_key?(response_usage, :output_cost)
      refute Map.has_key?(response_usage, :total_cost)
    end

    test "handles Response struct with malformed usage gracefully" do
      {:ok, model} = ReqLLM.model("openai:gpt-4")
      request = mock_request(model: model)

      response_body = %ReqLLM.Response{
        id: "test-id",
        model: model,
        context: %ReqLLM.Context{messages: []},
        message: nil,
        usage: %{input_tokens: "not_a_number", output_tokens: 50, total_tokens: 150},
        finish_reason: nil
      }

      response = mock_response(response_body)

      {_req, updated_resp} = Usage.handle({request, response})

      # Should not add cost fields when tokens are malformed
      response_usage = updated_resp.body.usage
      assert response_usage.input_tokens == "not_a_number"
      assert response_usage.output_tokens == 50
      refute Map.has_key?(response_usage, :input_cost)
      refute Map.has_key?(response_usage, :output_cost)
      refute Map.has_key?(response_usage, :total_cost)
    end

    test "preserves Response fields when adding cost breakdown" do
      model = %LLMDB.Model{provider: :openai, id: "gpt-4", cost: %{input: 0.01, output: 0.03}}
      request = mock_request(model: model)

      original_message = %ReqLLM.Message{
        role: :assistant,
        content: [%{type: :text, text: "Hello"}]
      }

      response_body = %ReqLLM.Response{
        id: "test-id",
        model: model,
        context: %ReqLLM.Context{messages: []},
        message: original_message,
        usage: %{input_tokens: 100, output_tokens: 50},
        finish_reason: :stop,
        provider_meta: %{custom: "data"}
      }

      response = mock_response(response_body)

      {_req, updated_resp} = Usage.handle({request, response})

      # All original fields should be preserved
      assert updated_resp.body.id == "test-id"
      assert updated_resp.body.model == model
      assert updated_resp.body.message == original_message
      assert updated_resp.body.finish_reason == :stop
      assert updated_resp.body.provider_meta == %{custom: "data"}

      # And cost fields should be added
      assert updated_resp.body.usage.input_cost == 0.000001
      assert updated_resp.body.usage.output_cost == 0.000002
      assert updated_resp.body.usage.total_cost == 0.000003
    end
  end

  describe "integration with Req pipeline" do
    test "usage step works properly in Req pipeline" do
      model = %LLMDB.Model{provider: :openai, id: "gpt-4", cost: %{input: 0.01, output: 0.03}}
      request = mock_request(model: model)
      updated_request = Usage.attach(request, model)

      mock_response =
        mock_response(%{"usage" => %{"prompt_tokens" => 150, "completion_tokens" => 75}})

      response_step_fun = updated_request.response_steps[:llm_usage]
      {_req, processed_response} = response_step_fun.({updated_request, mock_response})

      usage_data = processed_response.private[:req_llm][:usage]
      assert usage_data.tokens.input == 150
      assert usage_data.tokens.output == 75
      assert usage_data.cost == 0.000003
    end
  end
end

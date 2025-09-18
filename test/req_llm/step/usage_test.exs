defmodule ReqLLM.Step.UsageTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Model
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
      model = Model.new(:openai, "gpt-4")

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
        model = Model.new(:test, "test-model")
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
      model = Model.new(:openai, "gpt-4", cost: %{input: 0.01, output: 0.03})
      request = mock_request(model: model)
      response = mock_response(%{"usage" => %{"prompt_tokens" => 100, "completion_tokens" => 50}})

      {_req, updated_resp} = Usage.handle({request, response})

      usage_data = updated_resp.private[:req_llm][:usage]
      assert usage_data.cost == 0.0025

      assert_receive {:telemetry_event, [:req_llm, :token_usage], measurements, metadata}
      assert measurements.cost == 0.0025
      assert metadata.model == model
    end

    test "preserves existing private data" do
      model = Model.new(:test, "test-model")
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
      {"atom keys", %{input: 0.003, output: 0.015}, 1000, 500, 0.0105},
      {"string keys", %{"input" => 0.002, "output" => 0.004}, 1000, 1000, 0.006},
      {"no cost", nil, 1000, 500, nil},
      {"incomplete cost", %{input: 0.002}, 100, 50, nil}
    ]

    for {description, cost_map, input_tokens, output_tokens, expected_cost} <- @cost_scenarios do
      test "handles cost calculation: #{description}" do
        model = Model.new(:test, "test-model", cost: unquote(Macro.escape(cost_map)))
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
      model = Model.new(:test, "test-model", cost: %{input: 0.0033333, output: 0.0066666})
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
        Model.new(:anthropic, "claude-3-5-sonnet", cost: %{input: 0.003, output: 0.015})

      options_model = Model.new(:openai, "gpt-4", cost: %{input: 0.01, output: 0.03})

      request = %Req.Request{
        private: %{req_llm_model: private_model},
        options: [model: options_model]
      }

      response = mock_response(%{"usage" => %{"input_tokens" => 1000, "output_tokens" => 1000}})

      {_req, updated_resp} = Usage.handle({request, response})

      usage_data = updated_resp.private[:req_llm][:usage]
      # Should use private_model's pricing
      assert usage_data.cost == 0.018
    end

    @model_sources [
      {"from private", %{req_llm_model: Model.new(:test, "test")}, []},
      {"from options", %{}, [model: Model.new(:test, "test")]}
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
        model = Model.new(:test, "test-model")
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
      request = mock_request(model: "not_a_model_struct")
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
        model = Model.new(:openai, "gpt-4")
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

  describe "integration with Req pipeline" do
    test "usage step works properly in Req pipeline" do
      model = Model.new(:openai, "gpt-4", cost: %{input: 0.01, output: 0.03})
      request = mock_request(model: model)
      updated_request = Usage.attach(request, model)

      mock_response =
        mock_response(%{"usage" => %{"prompt_tokens" => 150, "completion_tokens" => 75}})

      response_step_fun = updated_request.response_steps[:llm_usage]
      {_req, processed_response} = response_step_fun.({updated_request, mock_response})

      usage_data = processed_response.private[:req_llm][:usage]
      assert usage_data.tokens.input == 150
      assert usage_data.tokens.output == 75
      assert usage_data.cost == 0.00375
    end
  end
end

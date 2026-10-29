defmodule ReqLLM.Providers.GroqTest do
  @moduledoc """
  Provider-level tests for Groq implementation.

  Tests the provider contract directly without going through Generation layer.
  Focus: prepare_request -> attach -> request -> decode pipeline.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Groq, async: true

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.Providers.Groq

  defp groq_gpt_oss_model do
    %LLMDB.Model{
      id: "openai/gpt-oss-120b",
      model: "openai/gpt-oss-120b",
      provider: :groq,
      capabilities: %{chat: true, streaming: true},
      limits: %{context: 131_072, output: 8192}
    }
  end

  defp reasoning_context do
    %Context{
      messages: [
        %Message{
          role: :user,
          content: [ContentPart.text("How would you build a pyramid?")]
        },
        %Message{
          role: :assistant,
          content: [
            ContentPart.thinking("Plan the answer carefully."),
            ContentPart.text("Use a stable foundation and stack stone courses.")
          ],
          reasoning_details: [
            %ReasoningDetails{
              text: "Plan the answer carefully.",
              provider: :groq,
              format: "groq-reasoning",
              index: 0
            }
          ]
        },
        %Message{
          role: :user,
          content: [ContentPart.text("What is your favorite pyramid?")]
        }
      ]
    }
  end

  describe "request preparation & pipeline wiring" do
    test "error handling for invalid configurations" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
      prompt = "Hello world"

      # Unsupported operation
      {:error, error} = Groq.prepare_request(:unsupported, model, prompt, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error

      # Provider mismatch
      {:ok, wrong_model} = ReqLLM.model(%{provider: :openai, id: "gpt-4"})

      assert_raise ReqLLM.Error.Invalid.Provider, fn ->
        Req.new() |> Groq.attach(wrong_model, [])
      end
    end
  end

  describe "body encoding & context translation" do
    test "encode_body preserves atom tool_choice values" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
      context = context_fixture()

      tool =
        ReqLLM.Tool.new!(
          name: "specific_tool",
          description: "A specific tool",
          parameter_schema: [
            value: [type: :string, required: true, doc: "A value parameter"]
          ],
          callback: fn _ -> {:ok, "result"} end
        )

      for tool_choice <- [:auto, :none, :required] do
        mock_request = %Req.Request{
          options: [
            context: context,
            model: model.model,
            stream: false,
            tools: [tool],
            tool_choice: tool_choice
          ]
        }

        updated_request = Groq.encode_body(mock_request)
        assert_no_duplicate_json_keys(ReqLLM.Test.Helpers.json_iodata(updated_request))
        decoded = ReqLLM.Test.Helpers.json_body(updated_request)

        assert is_list(decoded["tools"])
        assert decoded["tool_choice"] == to_string(tool_choice)
      end
    end

    test "encode_body with response_format" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
      context = context_fixture()

      response_format = %{type: "json_object"}

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          response_format: response_format
        ]
      }

      updated_request = Groq.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert decoded["response_format"] == %{"type" => "json_object"}
    end

    test "encode_body provider-specific options with skip values" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
      context = context_fixture()

      test_cases = [
        # Skip values should not appear in JSON
        {[service_tier: "auto"], fn json -> refute Map.has_key?(json, "service_tier") end},
        {[reasoning_effort: "default"],
         fn json -> refute Map.has_key?(json, "reasoning_effort") end},
        # Non-skip values should appear
        {[service_tier: "performance"],
         fn json -> assert json["service_tier"] == "performance" end},
        {[reasoning_effort: "high"], fn json -> assert json["reasoning_effort"] == "high" end},
        {[reasoning_format: "json"], fn json -> assert json["reasoning_format"] == "json" end},
        {[search_settings: %{domains: ["example.com"]}],
         fn json ->
           assert json["search_settings"] == %{"domains" => ["example.com"]}
         end}
      ]

      for {provider_opts, assertion} <- test_cases do
        options = [context: context, model: model.model, stream: false] ++ provider_opts
        mock_request = %Req.Request{options: options}
        updated_request = Groq.encode_body(mock_request)
        decoded = ReqLLM.Test.Helpers.json_body(updated_request)
        assertion.(decoded)
      end
    end

    test "encode_body handles standard OpenAI options" do
      {:ok, model} = ReqLLM.model("groq:llama-3.1-8b-instant")
      context = context_fixture()

      test_cases = [
        {[temperature: 0.2, max_tokens: 55, top_p: 0.9, frequency_penalty: 0.1],
         fn json ->
           assert json["temperature"] == 0.2
           assert json["max_tokens"] == 55
           assert json["top_p"] == 0.9
           assert json["frequency_penalty"] == 0.1
         end},
        {[presence_penalty: 0.2, user: "test_user", seed: 12_345],
         fn json ->
           assert json["presence_penalty"] == 0.2
           assert json["user"] == "test_user"
           assert json["seed"] == 12_345
         end},
        {[logit_bias: %{"50256" => -100}],
         fn json -> assert json["logit_bias"] == %{"50256" => -100} end}
      ]

      for {options, assertion} <- test_cases do
        full_options = [context: context, model: model.model, stream: false] ++ options
        mock_request = %Req.Request{options: full_options}
        updated_request = Groq.encode_body(mock_request)
        decoded = ReqLLM.Test.Helpers.json_body(updated_request)
        assertion.(decoded)
      end
    end

    test "encode_body omits unsupported reasoning fields from assistant history" do
      mock_request = %Req.Request{
        options: [
          context: reasoning_context(),
          model: "openai/gpt-oss-120b",
          stream: false,
          reasoning_effort: "high"
        ]
      }

      updated_request = Groq.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assistant_message = Enum.find(decoded["messages"], &(&1["role"] == "assistant"))

      assert decoded["reasoning_effort"] == "high"
      assert assistant_message["content"] == "Use a stable foundation and stack stone courses."
      refute Map.has_key?(assistant_message, "reasoning_content")
      refute Map.has_key?(assistant_message, "reasoning_details")
    end

    test "attach_stream omits unsupported reasoning fields from assistant history" do
      {:ok, request} =
        Groq.attach_stream(
          groq_gpt_oss_model(),
          reasoning_context(),
          [reasoning_effort: :high],
          ReqLLM.Finch
        )

      decoded =
        request.body
        |> IO.iodata_to_binary()
        |> Jason.decode!()

      assistant_message = Enum.find(decoded["messages"], &(&1["role"] == "assistant"))

      assert decoded["stream"] == true
      assert decoded["reasoning_effort"] == "high"
      assert assistant_message["content"] == "Use a stable foundation and stack stone courses."
      refute Map.has_key?(assistant_message, "reasoning_content")
      refute Map.has_key?(assistant_message, "reasoning_details")
    end
  end

  describe "response decoding & normalization" do
    test "decode_response handles streaming responses" do
      # Create a mock Req response with streaming body
      mock_resp = %Req.Response{
        status: 200,
        body: []
      }

      # Create a mock request with context and model and real-time stream
      context = context_fixture()
      model = "llama-3.1-8b-instant"

      # Mock the real-time stream that would be created by the Stream step
      mock_stream = ["Hello", " world", "!"]

      mock_req = %Req.Request{
        options: [context: context, stream: true, model: model],
        private: %{real_time_stream: mock_stream}
      }

      # Test decode_response directly
      {req, resp} = Groq.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Response{} = resp.body

      response = resp.body
      assert response.stream? == true
      assert response.stream == mock_stream
      assert response.model == model

      # Verify context is preserved (original messages only in streaming)
      assert length(response.context.messages) == 2

      # Verify stream structure and processing
      assert response.usage == %{
               input_tokens: 0,
               output_tokens: 0,
               total_tokens: 0,
               cached_tokens: 0,
               reasoning_tokens: 0
             }

      assert response.finish_reason == nil
      assert is_map(response.provider_meta)
      # In test scenario with mock stream, no http_task is created
    end
  end

  describe "option translation" do
    test "provider uses default translate_options/3" do
      # Groq uses default pass-through translate_options implementation
      assert function_exported?(Groq, :translate_options, 3)
    end

    test "provider-specific option handling" do
      # Test that provider-specific options are present in the provider schema
      schema_keys = Groq.provider_schema().schema |> Keyword.keys()

      # Test that these options are supported
      supported_opts = Groq.supported_provider_options()

      for provider_option <- schema_keys do
        assert provider_option in supported_opts,
               "Expected #{provider_option} to be in supported options"
      end
    end
  end

  describe "error handling & robustness" do
  end
end

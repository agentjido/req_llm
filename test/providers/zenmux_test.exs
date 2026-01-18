defmodule ReqLLM.Providers.ZenmuxTest do
  @moduledoc """
  Provider-level tests for Zenmux implementation.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Zenmux

  alias ReqLLM.Providers.Zenmux

  describe "provider contract" do
    test "provider identity and configuration" do
      assert Zenmux.provider_id() == :zenmux
      assert Zenmux.base_url() == "https://zenmux.ai/api/v1"
      assert Zenmux.default_env_key() == "ZENMUX_API_KEY"
    end

    test "provider schema separation from core options" do
      schema_keys = Zenmux.provider_schema().schema |> Keyword.keys()
      core_keys = ReqLLM.Provider.Options.generation_schema().schema |> Keyword.keys()

      overlap = MapSet.intersection(MapSet.new(schema_keys), MapSet.new(core_keys))

      assert MapSet.size(overlap) == 0,
             "Schema overlap detected: #{inspect(MapSet.to_list(overlap))}"
    end
  end

  describe "request preparation & pipeline wiring" do
    test "prepare_request creates configured request" do
      {:ok, model} = ReqLLM.model("zenmux:xiaomi/mimo-v2-flash")
      context = context_fixture()
      opts = [temperature: 0.7, max_tokens: 100]

      {:ok, request} = Zenmux.prepare_request(:chat, model, context, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
    end

    test "attach configures authentication and pipeline" do
      {:ok, model} = ReqLLM.model("zenmux:xiaomi/mimo-v2-flash")
      opts = [temperature: 0.5, max_tokens: 50]

      request = Req.new() |> Zenmux.attach(model, opts)

      assert request.options[:model] == model.model
      assert request.options[:temperature] == 0.5
      assert request.options[:max_tokens] == 50
      assert {:bearer, _key} = request.options[:auth]

      request_steps = Keyword.keys(request.request_steps)
      response_steps = Keyword.keys(request.response_steps)

      assert :llm_encode_body in request_steps
      assert :llm_decode_response in response_steps
    end

    test "error handling for invalid configurations" do
      {:ok, model} = ReqLLM.model("zenmux:xiaomi/mimo-v2-flash")
      context = context_fixture()

      # Unsupported operation
      {:error, error} = Zenmux.prepare_request(:embedding, model, context, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error
      assert error.parameter =~ "operation: :embedding not supported"
    end
  end

  describe "body encoding & option translation" do
    test "encode_body handles standard fields" do
      {:ok, model} = ReqLLM.model("zenmux:xiaomi/mimo-v2-flash")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      updated_request = Zenmux.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "xiaomi/mimo-v2-flash"
      assert is_list(decoded["messages"])
      assert length(decoded["messages"]) == 2
    end

    test "translate_options maps max_tokens to max_completion_tokens" do
      {:ok, model} = ReqLLM.model("zenmux:xiaomi/mimo-v2-flash")
      opts = [max_tokens: 100]

      {translated_opts, _warnings} = Zenmux.translate_options(:chat, model, opts)

      assert translated_opts[:max_completion_tokens] == 100
      refute Keyword.has_key?(translated_opts, :max_tokens)
    end

    test "translate_options handles reasoning_effort" do
      {:ok, model} = ReqLLM.model("zenmux:openai/o1")

      cases = [
        {:none, "none"},
        {:minimal, "minimal"},
        {:low, "low"},
        {:medium, "medium"},
        {:high, "high"},
        {:xhigh, "xhigh"},
        {:default, nil},
        {nil, nil}
      ]

      for {input, expected} <- cases do
        opts = [reasoning_effort: input]
        {translated_opts, _} = Zenmux.translate_options(:chat, model, opts)

        assert translated_opts[:reasoning_effort] == expected
      end
    end

    test "encode_body includes Zenmux-specific fields" do
      {:ok, model} = ReqLLM.model("zenmux:xiaomi/mimo-v2-flash")
      context = context_fixture()

      zenmux_opts = [
        provider: %{routing: %{type: "priority"}},
        model_routing_config: %{preference: "fastest"},
        reasoning: %{depth: "full"},
        web_search_options: %{enabled: true},
        verbosity: "high",
        max_completion_tokens: 500,
        reasoning_effort: "high"
      ]

      mock_request = %Req.Request{
        options: [context: context, model: model.model] ++ zenmux_opts
      }

      updated_request = Zenmux.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["provider"] == %{"routing" => %{"type" => "priority"}}
      assert decoded["model_routing_config"] == %{"preference" => "fastest"}
      assert decoded["reasoning"] == %{"depth" => "full"}
      assert decoded["web_search_options"] == %{"enabled" => true}
      assert decoded["verbosity"] == "high"
      assert decoded["max_completion_tokens"] == 500
      assert decoded["reasoning_effort"] == "high"
    end

    test "encode_body adds stream_options when streaming" do
      {:ok, model} = ReqLLM.model("zenmux:xiaomi/mimo-v2-flash")
      context = context_fixture()

      mock_request = %Req.Request{
        options: [context: context, model: model.model, stream: true]
      }

      updated_request = Zenmux.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["stream_options"] == %{"include_usage" => true}
    end

    test "encode_body translates tool_choice format" do
      {:ok, model} = ReqLLM.model("zenmux:xiaomi/mimo-v2-flash")
      context = context_fixture()

      # We need to simulate the body already having tool_choice in the legacy format
      # default_encode_body (which Zenmux calls) will put tool_choice from options into the body.
      # If tool_choice in options is %{type: "tool", name: "my_tool"},
      # default_encode_body encodes it.

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          # Ensure it's not :embedding
          operation: :chat,
          tool_choice: %{type: "tool", name: "my_tool"}
        ]
      }

      updated_request = Zenmux.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["tool_choice"] == %{
               "type" => "function",
               "function" => %{"name" => "my_tool"}
             }
    end
  end

  describe "object generation" do
    test "prepare_request for :object transforms into chat with tool" do
      {:ok, model} = ReqLLM.model("zenmux:xiaomi/mimo-v2-flash")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string])

      opts = [compiled_schema: schema]
      {:ok, request} = Zenmux.prepare_request(:object, model, context, opts)

      assert request.options[:tool_choice] == %{
               type: "function",
               function: %{name: "structured_output"}
             }

      assert length(request.options[:tools]) == 1

      tool = hd(request.options[:tools])
      assert tool.name == "structured_output"
      assert tool.parameter_schema == schema.schema
    end

    test "prepare_request for :object sets default max_tokens" do
      {:ok, model} = ReqLLM.model("zenmux:xiaomi/mimo-v2-flash")
      context = context_fixture()
      {:ok, schema} = ReqLLM.Schema.compile(name: [type: :string])

      # Case 1: No max_tokens -> 4096
      {:ok, req1} = Zenmux.prepare_request(:object, model, context, compiled_schema: schema)
      assert req1.options[:max_completion_tokens] == 4096

      # Case 2: Low max_tokens -> 200
      {:ok, req2} =
        Zenmux.prepare_request(:object, model, context, compiled_schema: schema, max_tokens: 50)

      assert req2.options[:max_completion_tokens] == 200

      # Case 3: High max_tokens -> kept
      {:ok, req3} =
        Zenmux.prepare_request(:object, model, context, compiled_schema: schema, max_tokens: 1000)

      assert req3.options[:max_completion_tokens] == 1000
    end
  end

  describe "response decoding" do
    test "decode_response handles DeepSeek tool calls in reasoning" do
      reasoning_text =
        ~s(Thinking... <｜tool▁call▁begin｜>weather<｜tool▁sep｜>{"location":"Paris"}<｜tool▁call▁end｜>)

      response_body = %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => "",
              "reasoning" => reasoning_text
            },
            "finish_reason" => "tool_calls"
          }
        ]
      }

      mock_resp = %Req.Response{status: 200, body: response_body}

      {:ok, model} = ReqLLM.model("zenmux:xiaomi/mimo-v2-flash")

      mock_req = %Req.Request{
        options: [context: context_fixture(), stream: false],
        private: %{req_llm_model: model}
      }

      {_, decoded_resp} = Zenmux.decode_response({mock_req, mock_resp})
      response = decoded_resp.body

      assert %ReqLLM.Response{} = response
      message = response.message

      assert is_list(message.tool_calls)
      assert length(message.tool_calls) == 1

      tool_call = hd(message.tool_calls)
      assert ReqLLM.ToolCall.name(tool_call) == "weather"
      assert ReqLLM.ToolCall.args_map(tool_call) == %{"location" => "Paris"}

      assert ReqLLM.Response.text(response) == "Thinking..."
    end

    test "decode_response extracts reasoning_details" do
      details = [%{"type" => "reasoning.text", "text" => "logic"}]

      response_body = %{
        "choices" => [
          %{
            "message" => %{
              "role" => "assistant",
              "content" => "result",
              "reasoning_details" => details
            }
          }
        ]
      }

      mock_resp = %Req.Response{status: 200, body: response_body}

      {:ok, model} = ReqLLM.model("zenmux:xiaomi/mimo-v2-flash")

      mock_req = %Req.Request{
        options: [context: context_fixture(), stream: false],
        private: %{req_llm_model: model}
      }

      {_, decoded_resp} = Zenmux.decode_response({mock_req, mock_resp})
      response = decoded_resp.body

      assert response.message.reasoning_details == details
    end
  end
end

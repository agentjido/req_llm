defmodule ReqLLM.Providers.DeepseekTest do
  @moduledoc """
  Provider-level tests for DeepSeek implementation.

  Tests the provider contract, configuration, and OpenAI-compatible
  request/response handling without making live API calls.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Deepseek, async: true

  alias ReqLLM.Providers.Deepseek

  defp deepseek_model(model_id \\ "deepseek-chat", opts \\ []) do
    %LLMDB.Model{
      id: "deepseek:#{model_id}",
      model: model_id,
      name: Keyword.get(opts, :name, "Deepseek Test Model"),
      provider: :deepseek,
      family: Keyword.get(opts, :family, "test"),
      capabilities: Keyword.get(opts, :capabilities, %{chat: true, tools: %{enabled: true}}),
      limits: Keyword.get(opts, :limits, %{context: 64_000, output: 8192})
    }
  end

  describe "provider contract" do
    test "provider schema includes thinking option" do
      schema = Deepseek.provider_schema().schema
      schema_keys = Keyword.keys(schema)

      assert :thinking in schema_keys

      thinking_schema = Keyword.get(schema, :thinking)
      assert thinking_schema[:type] == :map
    end
  end

  describe "request preparation" do
    test "prepare_request maps reasoning_effort: :xhigh to high" do
      model = deepseek_model("deepseek-reasoner")
      prompt = "Hello world"
      opts = [reasoning_effort: :xhigh]

      {:ok, request} = Deepseek.prepare_request(:chat, model, prompt, opts)
      assert request.options[:reasoning_effort] == "high"

      encoded = Deepseek.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)
      assert body["reasoning_effort"] == "high"
    end

    test "prepare_request preserves reasoning_effort: :low in the encoded body" do
      model = deepseek_model("deepseek-flash")
      prompt = "Hello world"
      opts = [reasoning_effort: :low]

      {:ok, request} = Deepseek.prepare_request(:chat, model, prompt, opts)
      assert request.options[:reasoning_effort] == "low"

      encoded = Deepseek.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)
      assert body["reasoning_effort"] == "low"
    end

    test "prepare_request accepts :ultra and encodes max effort" do
      model = deepseek_model("deepseek-flash")

      {:ok, request} =
        Deepseek.prepare_request(:chat, model, "Hello world", reasoning_effort: :ultra)

      assert request.options[:reasoning_effort] == "max"

      encoded = Deepseek.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)
      assert body["reasoning_effort"] == "max"
    end
  end

  describe "response decoding" do
    test "decode_response handles API errors" do
      error_body = %{
        "error" => %{
          "message" => "Invalid API key",
          "type" => "authentication_error"
        }
      }

      mock_resp = %Req.Response{
        status: 401,
        body: error_body
      }

      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, id: "deepseek-chat"]
      }

      {_req, error} = Deepseek.decode_response({mock_req, mock_resp})

      assert %ReqLLM.Error.API.Response{} = error
      assert error.status == 401
    end
  end

  describe "translate_options" do
    test "maps reasoning_effort atoms to correct string values" do
      model = deepseek_model()

      for {effort, expected} <- [
            {:none, "none"},
            {:minimal, "low"},
            {:low, "low"},
            {:medium, "high"},
            {:high, "high"},
            {:xhigh, "high"},
            {:max, "max"},
            {:ultra, "max"}
          ] do
        assert {opts, []} =
                 Deepseek.translate_options(:chat, model, reasoning_effort: effort)

        assert opts[:reasoning_effort] == expected
      end
    end

    test "omits the API effort when the canonical default is requested" do
      model = deepseek_model()

      assert {opts, []} = Deepseek.translate_options(:chat, model, reasoning_effort: :default)
      refute Keyword.has_key?(opts, :reasoning_effort)
    end

    test "passes through string reasoning_effort values unchanged" do
      model = deepseek_model()

      assert {opts, []} = Deepseek.translate_options(:chat, model, reasoning_effort: "high")
      assert opts[:reasoning_effort] == "high"

      assert {opts, []} = Deepseek.translate_options(:chat, model, reasoning_effort: "max")
      assert opts[:reasoning_effort] == "max"
    end

    test "handles nil reasoning_effort" do
      model = deepseek_model()

      assert {opts, []} = Deepseek.translate_options(:chat, model, reasoning_effort: nil)
      refute Keyword.has_key?(opts, :reasoning_effort)

      assert {opts, []} = Deepseek.translate_options(:chat, model, [])
      refute Keyword.has_key?(opts, :reasoning_effort)
    end
  end

  describe "build_body" do
    test "includes thinking in body when provided via provider_options" do
      model = deepseek_model()
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          provider_options: [thinking: %{type: "enabled"}]
        ]
      }

      body = Deepseek.build_body(mock_request)

      assert body[:thinking] == %{type: "enabled"}
    end

    test "normalizes thinking type from atom to string" do
      model = deepseek_model()
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          provider_options: [thinking: %{type: :disabled}]
        ]
      }

      body = Deepseek.build_body(mock_request)

      assert body[:thinking] == %{type: "disabled"}
    end

    test "includes reasoning_effort in body when provided" do
      model = deepseek_model()
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          reasoning_effort: "high"
        ]
      }

      body = Deepseek.build_body(mock_request)

      assert body[:reasoning_effort] == "high"
    end

    test "includes both thinking and reasoning_effort when both provided" do
      model = deepseek_model()
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          provider_options: [thinking: %{type: "enabled"}],
          reasoning_effort: "max"
        ]
      }

      body = Deepseek.build_body(mock_request)

      assert body[:thinking] == %{type: "enabled"}
      assert body[:reasoning_effort] == "max"
    end

    test "does not include thinking or reasoning_effort when not provided" do
      model = deepseek_model()
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      body = Deepseek.build_body(mock_request)

      refute Map.has_key?(body, :thinking)
      refute Map.has_key?(body, :reasoning_effort)
    end
  end

  describe "streaming support" do
    test "attach_stream builds streaming request" do
      model = deepseek_model()
      context = context_fixture()
      opts = [api_key: "test-key-12345", temperature: 0.7]

      {:ok, finch_request} = Deepseek.attach_stream(model, context, opts, MyApp.Finch)

      assert %Finch.Request{} = finch_request
      assert finch_request.method == "POST"
      assert String.contains?(finch_request.path, "/chat/completions")

      headers_map = Map.new(finch_request.headers)
      assert headers_map["Authorization"] == "Bearer test-key-12345"
    end
  end

  describe "build_body regression" do
    test "adds reasoning_content to assistant messages without it" do
      model = deepseek_model()

      follow_up_context =
        ReqLLM.Context.new([
          ReqLLM.Context.system("You are a helpful assistant."),
          ReqLLM.Context.user("Hello"),
          ReqLLM.Context.assistant("Hi there!"),
          ReqLLM.Context.user("How are you?")
        ])

      mock_request = %Req.Request{
        options: [
          context: follow_up_context,
          model: model.model
        ]
      }

      body = Deepseek.build_body(mock_request)

      assistant_msg =
        Enum.find(body.messages, fn msg ->
          Map.get(msg, :role) == "assistant" or Map.get(msg, "role") == "assistant"
        end)

      refute is_nil(assistant_msg)
      assert Map.get(assistant_msg, :reasoning_content) == ""
    end

    test "preserves existing reasoning_content in assistant messages" do
      model = deepseek_model()

      messages_with_reasoning = [
        %{role: "system", content: "You are helpful."},
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Previous response", reasoning_content: "kept reasoning"},
        %{role: "user", content: "Follow up"}
      ]

      mock_request = %Req.Request{
        options: [
          messages: messages_with_reasoning,
          model: model.model
        ]
      }

      body = Deepseek.build_body(mock_request)

      assistant_msg =
        Enum.find(body.messages, fn msg ->
          Map.get(msg, "role") == "assistant" or Map.get(msg, :role) == "assistant"
        end)

      refute is_nil(assistant_msg)
      assert Map.get(assistant_msg, :reasoning_content) == "kept reasoning"
    end

    test "preserves existing string-keyed reasoning_content in assistant messages" do
      model = deepseek_model()

      messages_with_reasoning = [
        %{"role" => "user", "content" => "Hello"},
        %{
          "role" => "assistant",
          "content" => "Previous response",
          "reasoning_content" => "kept reasoning"
        },
        %{"role" => "user", "content" => "Follow up"}
      ]

      mock_request = %Req.Request{
        options: [
          messages: messages_with_reasoning,
          model: model.model
        ]
      }

      body = Deepseek.build_body(mock_request)

      assistant_msg =
        Enum.find(body.messages, fn msg ->
          Map.get(msg, "role") == "assistant" or Map.get(msg, :role) == "assistant"
        end)

      refute is_nil(assistant_msg)
      assert Map.get(assistant_msg, "reasoning_content") == "kept reasoning"
      refute Map.has_key?(assistant_msg, :reasoning_content)
    end
  end
end

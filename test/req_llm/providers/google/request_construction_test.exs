defmodule ReqLLM.Providers.Google.RequestConstructionTest do
  @moduledoc """
  Google provider contract, request preparation, and basic body construction.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Google, async: true

  alias ReqLLM.Providers.Google

  describe "provider contract" do
    test "provider_extended_generation_schema includes both base and provider options" do
      extended_schema = Google.provider_extended_generation_schema()
      extended_keys = extended_schema.schema |> Keyword.keys()

      # Should include all core generation keys
      core_keys = ReqLLM.Provider.Options.all_generation_keys()
      core_without_meta = Enum.reject(core_keys, &(&1 == :provider_options))

      for core_key <- core_without_meta do
        assert core_key in extended_keys,
               "Extended schema missing core key: #{core_key}"
      end

      # Should include provider-specific keys
      provider_keys = Google.provider_schema().schema |> Keyword.keys()

      for provider_key <- provider_keys do
        assert provider_key in extended_keys,
               "Extended schema missing provider key: #{provider_key}"
      end
    end
  end

  describe "request preparation & pipeline wiring" do
    test "prepare_request creates configured request" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()
      opts = [temperature: 0.7, max_tokens: 100]

      {:ok, request} = Google.prepare_request(:chat, model, context, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/models/#{model.model}:generateContent"
      assert request.method == :post
    end

    test "prepare_request for streaming creates streaming endpoint" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()
      opts = [api_key: "test-key-12345", temperature: 0.7, max_tokens: 100, stream: true]

      {:ok, request} = Google.prepare_request(:chat, model, context, opts)

      assert %Req.Request{} = request
      assert request.url.path == "/models/#{model.model}:streamGenerateContent"
      assert request.method == :post
      assert request.options[:params] == [alt: "sse"]
      assert Req.Request.get_header(request, "x-goog-api-key") == ["test-key-12345"]
    end

    test "attach configures authentication and pipeline" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      opts = [api_key: "test-key-12345", temperature: 0.5, max_tokens: 50]

      request = Req.new() |> Google.attach(model, opts)

      # Verify core options
      assert request.options[:model] == model.model
      assert request.options[:temperature] == 0.5
      assert request.options[:max_tokens] == 50

      assert Req.Request.get_header(request, "x-goog-api-key") == ["test-key-12345"]
      refute Keyword.has_key?(request.options[:params] || [], :key)

      # Verify pipeline steps
      request_steps = Keyword.keys(request.request_steps)
      response_steps = Keyword.keys(request.response_steps)

      assert :llm_encode_body in request_steps
      assert :llm_decode_response in response_steps
    end

    test "error handling for invalid configurations" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()

      # Unsupported operation
      {:error, error} = Google.prepare_request(:unsupported, model, context, [])
      assert %ReqLLM.Error.Invalid.Parameter{} = error

      # Provider mismatch
      {:ok, wrong_model} = ReqLLM.model(%{provider: :openai, id: "gpt-4"})

      assert_raise ReqLLM.Error.Invalid.Provider, fn ->
        Req.new() |> Google.attach(wrong_model, [])
      end
    end
  end

  describe "body encoding & context translation" do
    test "encode_body without tools" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()

      # Create a mock request with the expected structure
      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      # Test the encode_body function directly
      updated_request = Google.encode_body(mock_request)

      assert is_binary(IO.iodata_to_binary(ReqLLM.Test.Helpers.json_iodata(updated_request)))
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      # Should have Google's structure
      assert is_list(decoded["contents"])
      # Only user message, system is separate
      assert length(decoded["contents"]) == 1
      refute Map.has_key?(decoded, "tools")

      # Check generationConfig
      assert Map.has_key?(decoded, "generationConfig")
      assert decoded["generationConfig"]["candidateCount"] == 1

      # Check system instruction is separate
      assert Map.has_key?(decoded, "systemInstruction")
      assert decoded["systemInstruction"]["parts"]

      # Only user message in contents now
      [user_msg] = decoded["contents"]
      assert user_msg["role"] == "user"
      assert is_list(user_msg["parts"])
    end

    test "encode_body with Google-specific options" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()

      safety_settings = [
        %{
          "category" => "HARM_CATEGORY_HARASSMENT",
          "threshold" => "BLOCK_MEDIUM_AND_ABOVE"
        }
      ]

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          google_safety_settings: safety_settings,
          google_candidate_count: 2,
          temperature: 0.8,
          max_tokens: 500
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      # Check safety settings
      assert decoded["safetySettings"] == safety_settings

      # Check generation config with Google parameter names
      gen_config = decoded["generationConfig"]
      assert gen_config["temperature"] == 0.8
      assert gen_config["maxOutputTokens"] == 500
      assert gen_config["candidateCount"] == 2
    end

    test "encode_body includes thinkingLevel in generationConfig" do
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: "gemini-3-flash",
          stream: false,
          google_thinking_level: :medium
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      thinking_config = decoded["generationConfig"]["thinkingConfig"]
      assert thinking_config["thinkingLevel"] == "medium"
      assert thinking_config["includeThoughts"] == true
      refute Map.has_key?(thinking_config, "thinkingBudget")
    end

    test "encode_body includes thinkingBudget in generationConfig" do
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: "gemini-2.5-flash",
          stream: false,
          google_thinking_budget: 8_192
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      thinking_config = decoded["generationConfig"]["thinkingConfig"]
      assert thinking_config["thinkingBudget"] == 8_192
      assert thinking_config["includeThoughts"] == true
      refute Map.has_key?(thinking_config, "thinkingLevel")
    end

    test "encode_body raises when both google_thinking_level and google_thinking_budget are set" do
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: "gemini-3-flash",
          stream: false,
          google_thinking_level: :high,
          google_thinking_budget: 8_192
        ]
      }

      assert_raise ArgumentError,
                   ~r/google_thinking_budget and google_thinking_level cannot be combined/,
                   fn -> Google.encode_body(mock_request) end
    end

    test "encode_body for embedding operation" do
      mock_request = %Req.Request{
        options: [
          operation: :embedding,
          id: "gemini-embedding-001",
          text: "Hello, world!",
          dimensions: 768
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      # Check embedding-specific structure
      assert decoded["model"] == "models/gemini-embedding-001"
      assert decoded["content"]["parts"] == [%{"text" => "Hello, world!"}]
      assert decoded["outputDimensionality"] == 768
    end
  end

  describe "object generation with native JSON mode" do
    test "prepare_request creates configured embedding request" do
      {:ok, model} = ReqLLM.model("google:gemini-embedding-001")
      text = "Hello, world!"
      opts = [dimensions: 768]

      {:ok, request} = Google.prepare_request(:embedding, model, text, opts)

      assert request.method == :post
      assert request.url.path == "/models/gemini-embedding-001:embedContent"

      # Check request options contain embedding-specific data
      assert request.options[:text] == text
      assert request.options[:operation] == :embedding
      assert request.options[:dimensions] == 768
    end
  end
end

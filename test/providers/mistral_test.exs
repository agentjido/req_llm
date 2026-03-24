defmodule ReqLLM.Providers.MistralTest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Mistral

  alias ReqLLM.Providers.Mistral

  defp mistral_model(model_id \\ "mistral-small-latest") do
    ReqLLM.model!("mistral:#{model_id}")
  end

  describe "provider contract" do
    test "provider identity and configuration" do
      assert Mistral.provider_id() == :mistral
      assert Mistral.base_url() == "https://api.mistral.ai/v1"
      assert Mistral.default_env_key() == "MISTRAL_API_KEY"
    end

    test "provider schema exposes Mistral-specific request fields" do
      schema_keys = Mistral.provider_schema().schema |> Keyword.keys()

      for key <- [
            :random_seed,
            :metadata,
            :prediction,
            :response_format,
            :parallel_tool_calls,
            :prompt_mode,
            :safe_prompt,
            :output_dimension,
            :output_dtype
          ] do
        assert key in schema_keys
      end
    end
  end

  describe "request preparation" do
    test "prepare_request for :chat creates /chat/completions request" do
      {:ok, request} =
        Mistral.prepare_request(:chat, mistral_model(), "Hello world", temperature: 0.7)

      assert %Req.Request{} = request
      assert request.url.path == "/chat/completions"
      assert request.method == :post
    end

    test "prepare_request for :embedding creates /embeddings request" do
      {:ok, request} =
        Mistral.prepare_request(
          :embedding,
          mistral_model("mistral-embed"),
          "Hello world",
          dimensions: 512
        )

      assert %Req.Request{} = request
      assert request.url.path == "/embeddings"
      assert request.method == :post
    end

    test "prepare_request rejects unsupported operations" do
      {:error, error} =
        Mistral.prepare_request(:unsupported, mistral_model(), context_fixture(), [])

      assert %ReqLLM.Error.Invalid.Parameter{} = error
    end
  end

  describe "authentication wiring" do
    test "attach adds Bearer authorization header" do
      attached = Mistral.attach(Req.new(), mistral_model(), [])

      auth_header = attached.headers["authorization"]
      assert auth_header != nil
      assert String.starts_with?(List.first(auth_header), "Bearer ")
    end

    test "attach adds pipeline steps" do
      attached = Mistral.attach(Req.new(), mistral_model(), [])

      assert :llm_encode_body in Keyword.keys(attached.request_steps)
      assert :llm_decode_response in Keyword.keys(attached.response_steps)
    end
  end

  describe "body encoding" do
    test "encode_body maps Mistral chat-specific fields" do
      context = context_fixture()

      mock_request = %Req.Request{
        options: [
          context: context,
          model: "mistral-small-latest",
          stream: false,
          seed: 7,
          parallel_tool_calls: false,
          prompt_mode: :reasoning,
          safe_prompt: true,
          reasoning_effort: :high,
          metadata: [trace_id: "abc123"],
          prediction: [type: "content", content: "Hello"],
          response_format: [type: "json_object"]
        ]
      }

      updated_request = Mistral.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["random_seed"] == 7
      assert decoded["parallel_tool_calls"] == false
      assert decoded["prompt_mode"] == "reasoning"
      assert decoded["safe_prompt"] == true
      assert decoded["reasoning_effort"] == "high"
      assert decoded["metadata"] == %{"trace_id" => "abc123"}
      assert decoded["prediction"] == %{"type" => "content", "content" => "Hello"}
      assert decoded["response_format"] == %{"type" => "json_object"}
      refute Map.has_key?(decoded, "seed")
    end

    test "encode_body maps embedding-specific fields" do
      mock_request = %Req.Request{
        options: [
          operation: :embedding,
          model: "mistral-embed",
          text: ["hello world"],
          dimensions: 512,
          encoding_format: "base64",
          output_dtype: "int8",
          metadata: %{scope: "test"}
        ]
      }

      updated_request = Mistral.encode_body(mock_request)
      decoded = Jason.decode!(updated_request.body)

      assert decoded["model"] == "mistral-embed"
      assert decoded["input"] == ["hello world"]
      assert decoded["output_dimension"] == 512
      assert decoded["output_dtype"] == "int8"
      assert decoded["encoding_format"] == "base64"
      assert decoded["metadata"] == %{"scope" => "test"}
    end
  end

  describe "response decoding" do
    test "decode_response parses OpenAI-format response" do
      mock_resp = %Req.Response{
        status: 200,
        body:
          openai_format_json_fixture(
            model: "mistral-small-latest",
            content: "Hello from Mistral!"
          )
      }

      mock_req = %Req.Request{
        options: [
          context: context_fixture(),
          model: "mistral-small-latest",
          operation: :chat
        ]
      }

      {_req, decoded_resp} = Mistral.decode_response({mock_req, mock_resp})

      assert %ReqLLM.Response{} = decoded_resp.body
      assert ReqLLM.Response.text(decoded_resp.body) == "Hello from Mistral!"
    end
  end

  describe "streaming support" do
    test "attach_stream applies translated options to the request body" do
      {:ok, finch_request} =
        Mistral.attach_stream(
          mistral_model(),
          context_fixture(),
          [seed: 99, parallel_tool_calls: false, prompt_mode: :reasoning],
          MyApp.Finch
        )

      assert %Finch.Request{} = finch_request
      assert finch_request.method == "POST"
      assert String.contains?(finch_request.path, "/chat/completions")

      headers_map = Map.new(finch_request.headers)
      assert headers_map["Authorization"] == "Bearer test-key-12345"

      decoded = Jason.decode!(finch_request.body)
      assert decoded["random_seed"] == 99
      assert decoded["parallel_tool_calls"] == false
      assert decoded["prompt_mode"] == "reasoning"
      assert decoded["stream"] == true
    end
  end

  describe "option translation" do
    test "drops unsupported reasoning_effort values with a warning" do
      {translated_opts, warnings} =
        Mistral.translate_options(:chat, mistral_model(), reasoning_effort: :medium)

      refute Keyword.has_key?(translated_opts, :reasoning_effort)
      assert length(warnings) == 1
      assert hd(warnings) =~ "Mistral supports reasoning_effort values :high and :none"
    end
  end
end

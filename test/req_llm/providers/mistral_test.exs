defmodule ReqLLM.Providers.MistralTest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Mistral, async: true

  alias ReqLLM.Providers.Mistral

  defp mistral_model(model_id \\ "mistral-small-latest") do
    ReqLLM.model!("mistral:#{model_id}")
  end

  describe "provider contract" do
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
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

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
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert decoded["model"] == "mistral-embed"
      assert decoded["input"] == ["hello world"]
      assert decoded["output_dimension"] == 512
      assert decoded["output_dtype"] == "int8"
      assert decoded["encoding_format"] == "base64"
      assert decoded["metadata"] == %{"scope" => "test"}
    end
  end

  describe "streaming support" do
    test "attach_stream applies translated options to the request body" do
      {:ok, finch_request} =
        Mistral.attach_stream(
          mistral_model(),
          context_fixture(),
          [
            api_key: "test-key-12345",
            seed: 99,
            parallel_tool_calls: false,
            prompt_mode: :reasoning
          ],
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
    test "preserves supported reasoning_effort values" do
      for {effort, expected} <- [
            {:none, "none"},
            {:low, "low"},
            {:medium, "medium"},
            {:high, "high"},
            {"none", "none"},
            {"low", "low"},
            {"medium", "medium"},
            {"high", "high"}
          ] do
        {translated_opts, warnings} =
          Mistral.translate_options(:chat, mistral_model(), reasoning_effort: effort)

        assert translated_opts[:reasoning_effort] == expected
        assert warnings == []
      end
    end

    test "drops unsupported reasoning_effort values with a warning" do
      {translated_opts, warnings} =
        Mistral.translate_options(:chat, mistral_model(), reasoning_effort: :minimal)

      refute Keyword.has_key?(translated_opts, :reasoning_effort)
      assert length(warnings) == 1

      assert hd(warnings) =~
               "Mistral supports reasoning_effort values :none, :low, :medium, and :high"
    end
  end
end

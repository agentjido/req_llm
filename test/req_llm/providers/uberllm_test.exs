defmodule ReqLLM.Providers.UberLLMTest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.UberLLM, async: true

  alias ReqLLM.Providers.UberLLM

  defp uberllm_model do
    %LLMDB.Model{
      id: "deepseek/deepseek-v4.1-flash",
      model: "deepseek/deepseek-v4.1-flash",
      provider_model_id: "deepseek/deepseek-v4.1-flash",
      provider: :uberllm,
      capabilities: %{chat: true, tools: %{enabled: true}}
    }
  end

  test "resolves model strings before LLMDB catalog support" do
    warning =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, model} = ReqLLM.model("uberllm:openai/gpt-5-nano")
        assert model.provider == :uberllm
        assert model.id == "openai/gpt-5-nano"
        assert model.model == "openai/gpt-5-nano"
      end)

    assert warning =~ "Using unverified model: uberllm:openai/gpt-5-nano"
  end

  test "prepares object requests with a structured-output tool" do
    assert {:ok, schema} = ReqLLM.Schema.compile(answer: [type: :string, required: true])

    assert {:ok, request} =
             UberLLM.prepare_request(
               :object,
               uberllm_model(),
               "Return an answer",
               compiled_schema: schema
             )

    assert request.url.path == "/chat/completions"
    assert request.options[:operation] == :object
    assert [%ReqLLM.Tool{name: "structured_output"}] = request.options[:tools]
  end

  test "rejects every unsupported operation with an accurate error" do
    for operation <- [
          :embedding,
          :image,
          :speech,
          :transcription,
          :rerank,
          :ocr,
          :video,
          :compact,
          :evaluate,
          :unsupported
        ] do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = error} =
               UberLLM.prepare_request(
                 operation,
                 uberllm_model(),
                 context_fixture(),
                 []
               )

      assert error.parameter =~ "operation: #{inspect(operation)} not supported"
      assert error.parameter =~ "Supported operations: [:chat, :object]"
    end
  end
end

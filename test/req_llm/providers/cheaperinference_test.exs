defmodule ReqLLM.Providers.CheaperInferenceTest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.CheaperInference, async: true

  alias ReqLLM.Providers.CheaperInference

  defp cheaperinference_model do
    %LLMDB.Model{
      id: "gpt-5.4-mini",
      model: "gpt-5.4-mini",
      provider_model_id: "gpt-5.4-mini",
      provider: :cheaperinference,
      capabilities: %{chat: true, tools: %{enabled: true}}
    }
  end

  test "resolves model strings before LLMDB catalog support" do
    warning =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, model} = ReqLLM.model("cheaperinference:gpt-5.4-mini")
        assert model.provider == :cheaperinference
        assert model.id == "gpt-5.4-mini"
        assert model.model == "gpt-5.4-mini"
      end)

    assert warning =~ "Using unverified model: cheaperinference:gpt-5.4-mini"
  end

  test "prepares object requests with a structured-output tool" do
    assert {:ok, schema} = ReqLLM.Schema.compile(answer: [type: :string, required: true])

    assert {:ok, request} =
             CheaperInference.prepare_request(
               :object,
               cheaperinference_model(),
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
               CheaperInference.prepare_request(
                 operation,
                 cheaperinference_model(),
                 context_fixture(),
                 []
               )

      assert error.parameter =~ "operation: #{inspect(operation)} not supported"
      assert error.parameter =~ "Supported operations: [:chat, :object]"
    end
  end
end

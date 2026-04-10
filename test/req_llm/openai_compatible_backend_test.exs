defmodule ReqLLM.OpenAICompatibleBackendTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Context
  alias ReqLLM.Generation
  alias ReqLLM.Provider.Options
  alias ReqLLM.Response
  alias ReqLLM.Transcription

  setup do
    env_key = System.get_env("OPENAI_API_KEY")
    app_key = Application.get_env(:req_llm, :openai_api_key)

    System.delete_env("OPENAI_API_KEY")
    Application.delete_env(:req_llm, :openai_api_key)

    on_exit(fn ->
      restore_system_env("OPENAI_API_KEY", env_key)
      restore_application_env(:openai_api_key, app_key)
    end)

    :ok
  end

  test "generate_text allows explicit Ollama models without OPENAI_API_KEY" do
    Req.Test.stub(ReqLLM.OpenAICompatibleBackendGenerateTextTest, fn conn ->
      assert conn.request_path == "/v1/chat/completions"
      assert Plug.Conn.get_req_header(conn, "authorization") == []

      Req.Test.json(conn, %{
        "id" => "chatcmpl_test_123",
        "model" => "llama3",
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => "Ollama says hi"}
          }
        ],
        "usage" => %{"prompt_tokens" => 4, "completion_tokens" => 4, "total_tokens" => 8}
      })
    end)

    assert {:ok, response} =
             Generation.generate_text(
               ollama_model(extra: %{openai_compatible_backend: :ollama}),
               "Hello",
               req_http_options: [
                 plug: {Req.Test, ReqLLM.OpenAICompatibleBackendGenerateTextTest}
               ]
             )

    assert Response.text(response) == "Ollama says hi"
  end

  test "streaming request builders omit auth for explicit Ollama provider options" do
    model = ReqLLM.model!(ollama_model())
    context = Context.new([Context.user("Hello")])

    opts =
      Options.process!(
        ReqLLM.Providers.OpenAI,
        :chat,
        model,
        provider_options: [openai_compatible_backend: :ollama]
      )

    assert {:ok, finch_request} =
             ReqLLM.Providers.OpenAI.ChatAPI.attach_stream(model, context, opts, nil)

    refute Enum.any?(finch_request.headers, fn {name, _value} ->
             String.downcase(name) == "authorization"
           end)

    assert finch_request.path == "/v1/chat/completions"
  end

  test "transcribe allows explicit Ollama provider options without OPENAI_API_KEY" do
    Req.Test.stub(ReqLLM.OpenAICompatibleBackendTranscriptionTest, fn conn ->
      assert conn.request_path == "/v1/audio/transcriptions"
      assert Plug.Conn.get_req_header(conn, "authorization") == []

      Req.Test.json(conn, %{
        "text" => "Hello from Ollama",
        "language" => "en"
      })
    end)

    assert {:ok, result} =
             Transcription.transcribe(
               ollama_model(id: "whisper-1"),
               {:binary, "fake audio", "audio/mpeg"},
               provider_options: [openai_compatible_backend: :ollama],
               req_http_options: [
                 plug: {Req.Test, ReqLLM.OpenAICompatibleBackendTranscriptionTest}
               ]
             )

    assert result.text == "Hello from Ollama"
    assert result.language == "en"
  end

  test "unmarked OpenAI-compatible models still require authentication" do
    assert_raise ReqLLM.Error.Invalid.Parameter, ~r/OPENAI_API_KEY/, fn ->
      Generation.generate_text(ollama_model(), "Hello")
    end
  end

  defp ollama_model(attrs \\ []) do
    attrs = Enum.into(attrs, %{})

    Map.merge(
      %{
        provider: :openai,
        id: "llama3",
        base_url: "http://localhost:11434/v1"
      },
      attrs
    )
  end

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp restore_application_env(key, nil), do: Application.delete_env(:req_llm, key)
  defp restore_application_env(key, value), do: Application.put_env(:req_llm, key, value)
end

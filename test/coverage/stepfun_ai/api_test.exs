defmodule ReqLLM.Coverage.StepFunAI.APITest do
  use ExUnit.Case, async: false

  import ReqLLM.Test.Helpers

  @moduletag :coverage
  @moduletag provider: :stepfun_ai
  @moduletag timeout: 120_000

  @chat_model %{provider: :stepfun_ai, id: "step-3.5-flash"}
  @audio_chat_model %{provider: :stepfun_ai, id: "stepaudio-3-chat-preview"}
  @speech_model %{provider: :stepfun_ai, id: "stepaudio-3-tts"}
  @asr_model %{provider: :stepfun_ai, id: "stepaudio-3-asr-max"}
  @sample_audio Path.expand("../../support/audio/stepfun_hello.wav", __DIR__)

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:basic)
  @tag model: "step-3.5-flash"
  test "generates text" do
    assert {:ok, response} =
             ReqLLM.generate_text(
               @chat_model,
               "Reply with only the word OK.",
               chat_options("basic")
             )

    assert ReqLLM.Response.text(response) != ""
    assert response.usage.input_tokens > 0
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:streaming)
  @tag model: "step-3.5-flash"
  test "streams text" do
    assert {:ok, stream} =
             ReqLLM.stream_text(
               @chat_model,
               "Reply with only the word OK.",
               chat_options("streaming")
             )

    assert {:ok, response} = ReqLLM.StreamResponse.to_response(stream)
    assert ReqLLM.Response.text(response) != ""
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:object_basic)
  @tag model: "step-3.5-flash"
  test "generates an object through tool calling" do
    assert {:ok, response} =
             ReqLLM.generate_object(
               @chat_model,
               "Return an object with greeting set to hello.",
               [greeting: [type: :string, required: true]],
               chat_options("object_basic")
             )

    assert ReqLLM.Response.object(response)["greeting"] == "hello"
  end

  @tag model: "stepaudio-3-chat-preview"
  test "accepts WAV input in chat" do
    context =
      ReqLLM.Context.new([
        ReqLLM.Context.user([
          ReqLLM.Message.ContentPart.text("Transcribe this short recording in English."),
          ReqLLM.Message.ContentPart.file(
            ReqLLM.ProviderTest.Transcription.sample_audio(),
            "hello_world.wav",
            "audio/wav"
          )
        ])
      ])

    assert {:ok, response} =
             ReqLLM.generate_text(
               @audio_chat_model,
               context,
               fixture_opts("audio_chat",
                 max_tokens: 1024,
                 reasoning_effort: :low,
                 max_retries: 0
               )
             )

    assert ReqLLM.Response.text(response) != ""
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:speech_basic)
  @tag model: "stepaudio-3-tts"
  test "generates WAV speech" do
    assert {:ok, detailed} =
             ReqLLM.speak_detailed(
               @speech_model,
               "Hello.",
               fixture_opts("speech_basic", output_format: :wav, max_retries: 0)
             )

    assert <<"RIFF", _::binary>> = detailed.result.audio
    assert detailed.result.media_type == "audio/wav"
    assert detailed.call_metadata.provider == :stepfun_ai
  end

  @tag ReqLLM.Test.CompatibilityScenario.tag!(:transcription_basic)
  @tag model: "stepaudio-3-asr-max"
  test "transcribes WAV input" do
    assert {:ok, detailed} =
             ReqLLM.transcribe_detailed(
               @asr_model,
               {:binary, File.read!(@sample_audio), "audio/wav"},
               fixture_opts("transcription_basic", language: "en", max_retries: 0)
             )

    assert detailed.result.text != ""
    assert detailed.call_metadata.provider == :stepfun_ai
  end

  defp chat_options(fixture) do
    fixture_opts(fixture, max_tokens: 512, reasoning_effort: :low, max_retries: 0)
  end
end

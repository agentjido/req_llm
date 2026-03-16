defmodule ReqLLM.Integration.TranscriptionTest do
  @moduledoc """
  Integration tests for speech-to-text transcription.

  Uses a "generate-then-transcribe" pattern: OpenAI TTS produces audio,
  then Groq transcribes it. This avoids committing binary fixtures.

  ## Running

      GROQ_API_KEY=... OPENAI_API_KEY=... mix test --include integration test/req_llm/integration/transcription_test.exs
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  describe "Groq STT (via OpenAI TTS)" do
    @describetag provider: :groq

    setup do
      groq_key = System.get_env("GROQ_API_KEY")
      openai_key = System.get_env("OPENAI_API_KEY")

      if groq_key && openai_key do
        :ok
      else
        missing =
          [
            if(!groq_key, do: "GROQ_API_KEY"),
            if(!openai_key, do: "OPENAI_API_KEY")
          ]
          |> Enum.reject(&is_nil/1)

        {:ok, skip: true, missing: missing}
      end
    end

    defp generate_audio!(text, opts \\ []) do
      voice = Keyword.get(opts, :voice, "alloy")

      {:ok, result} =
        ReqLLM.speak("openai:tts-1", text, voice: voice, output_format: :mp3)

      result.audio
    end

    @tag timeout: 60_000
    test "transcribes generated audio", context do
      if context[:skip],
        do: flunk("Missing API keys: #{Enum.join(context[:missing], ", ")}")

      audio = generate_audio!("The quick brown fox jumps over the lazy dog.")

      assert {:ok, result} =
               ReqLLM.transcribe(
                 "groq:whisper-large-v3-turbo",
                 {:binary, audio, "audio/mpeg"}
               )

      assert is_binary(result.text)
      text_lower = String.downcase(result.text)
      assert text_lower =~ "quick" or text_lower =~ "brown" or text_lower =~ "fox"
    end

    @tag timeout: 60_000
    test "transcribes with language hint", context do
      if context[:skip],
        do: flunk("Missing API keys: #{Enum.join(context[:missing], ", ")}")

      audio = generate_audio!("Hello, this is a test of speech recognition.")

      assert {:ok, result} =
               ReqLLM.transcribe(
                 "groq:whisper-large-v3-turbo",
                 {:binary, audio, "audio/mpeg"},
                 language: "en"
               )

      assert is_binary(result.text)
      text_lower = String.downcase(result.text)
      assert text_lower =~ "hello" or text_lower =~ "test" or text_lower =~ "speech"
    end

    @tag timeout: 60_000
    test "returns segments with timing data", context do
      if context[:skip],
        do: flunk("Missing API keys: #{Enum.join(context[:missing], ", ")}")

      audio = generate_audio!("First sentence. Second sentence. Third sentence.")

      # Default transcription uses verbose_json, which returns segments
      assert {:ok, result} =
               ReqLLM.transcribe(
                 "groq:whisper-large-v3-turbo",
                 {:binary, audio, "audio/mpeg"}
               )

      assert is_binary(result.text)
      assert is_list(result.segments)

      if length(result.segments) > 0 do
        segment = hd(result.segments)
        assert is_binary(segment.text) or is_binary(segment[:text])
        assert is_number(segment.start_second) or is_number(segment[:start_second])
        assert is_number(segment.end_second) or is_number(segment[:end_second])
      end
    end
  end

  describe "ElevenLabs STT (via ElevenLabs TTS)" do
    @describetag provider: :elevenlabs

    setup do
      case System.get_env("ELEVENLABS_API_KEY") do
        nil -> {:ok, skip: true}
        _key -> :ok
      end
    end

    defp generate_elevenlabs_audio!(text, opts \\ []) do
      {:ok, result} =
        ReqLLM.speak(
          "elevenlabs:eleven_multilingual_v2",
          text,
          Keyword.merge([voice: "21m00Tcm4TlvDq8ikWAM"], opts)
        )

      result.audio
    end

    @tag timeout: 60_000
    test "transcribes generated audio", context do
      if context[:skip], do: flunk("ELEVENLABS_API_KEY not set")

      audio = generate_elevenlabs_audio!("The quick brown fox jumps over the lazy dog.")

      assert {:ok, result} =
               ReqLLM.transcribe(
                 %{id: "scribe_v2", provider: :elevenlabs},
                 {:binary, audio, "audio/mpeg"}
               )

      assert is_binary(result.text)
      text_lower = String.downcase(result.text)
      assert text_lower =~ "quick" or text_lower =~ "brown" or text_lower =~ "fox"
    end

    @tag timeout: 60_000
    test "transcribes with language hint", context do
      if context[:skip], do: flunk("ELEVENLABS_API_KEY not set")

      audio =
        generate_elevenlabs_audio!("Hello, this is a test of ElevenLabs speech recognition.")

      assert {:ok, result} =
               ReqLLM.transcribe(
                 %{id: "scribe_v2", provider: :elevenlabs},
                 {:binary, audio, "audio/mpeg"},
                 language: "en"
               )

      assert is_binary(result.text)
      text_lower = String.downcase(result.text)
      assert text_lower =~ "hello" or text_lower =~ "test" or text_lower =~ "speech"
    end
  end
end

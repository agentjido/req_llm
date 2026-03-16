defmodule ReqLLM.Integration.SpeechTest do
  @moduledoc """
  Integration tests for text-to-speech generation.

  Tests real API calls to ElevenLabs and OpenAI TTS endpoints.

  ## Running

      # ElevenLabs TTS
      ELEVENLABS_API_KEY=... mix test --include integration test/req_llm/integration/speech_test.exs

      # OpenAI TTS
      OPENAI_API_KEY=... mix test --include integration test/req_llm/integration/speech_test.exs

      # Both
      ELEVENLABS_API_KEY=... OPENAI_API_KEY=... mix test --include integration test/req_llm/integration/speech_test.exs
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  describe "ElevenLabs TTS" do
    @describetag provider: :elevenlabs

    setup do
      case System.get_env("ELEVENLABS_API_KEY") do
        nil -> {:ok, skip: true}
        _key -> :ok
      end
    end

    @tag timeout: 30_000
    test "generates speech with default voice", context do
      if context[:skip], do: flunk("ELEVENLABS_API_KEY not set")

      model = %{id: "eleven_multilingual_v2", provider: :elevenlabs}

      assert {:ok, result} =
               ReqLLM.speak(model, "Hello, this is a test of the ElevenLabs text to speech API.")

      assert is_binary(result.audio)
      assert byte_size(result.audio) > 1000
      assert result.format == "mp3"
      assert result.media_type == "audio/mpeg"
    end

    @tag timeout: 30_000
    test "generates speech with voice_settings", context do
      if context[:skip], do: flunk("ELEVENLABS_API_KEY not set")

      model = %{id: "eleven_multilingual_v2", provider: :elevenlabs}

      assert {:ok, result} =
               ReqLLM.speak(model, "Testing voice settings with stability and similarity.",
                 provider_options: [stability: 0.3, similarity_boost: 0.9]
               )

      assert is_binary(result.audio)
      assert byte_size(result.audio) > 1000
    end

    @tag timeout: 30_000
    test "generates speech with language code", context do
      if context[:skip], do: flunk("ELEVENLABS_API_KEY not set")

      model = %{id: "eleven_multilingual_v2", provider: :elevenlabs}

      assert {:ok, result} =
               ReqLLM.speak(model, "Hola, esta es una prueba.", language: "es")

      assert is_binary(result.audio)
      assert byte_size(result.audio) > 1000
    end
  end

  describe "OpenAI TTS" do
    @describetag provider: :openai

    setup do
      case System.get_env("OPENAI_API_KEY") do
        nil -> {:ok, skip: true}
        _key -> :ok
      end
    end

    @tag timeout: 30_000
    test "generates speech with tts-1", context do
      if context[:skip], do: flunk("OPENAI_API_KEY not set")

      assert {:ok, result} =
               ReqLLM.speak("openai:tts-1", "Hello, this is a test of OpenAI text to speech.",
                 voice: "alloy"
               )

      assert is_binary(result.audio)
      assert byte_size(result.audio) > 1000
      assert result.format == "mp3"
    end

    @tag timeout: 30_000
    test "generates speech with different output format", context do
      if context[:skip], do: flunk("OPENAI_API_KEY not set")

      assert {:ok, result} =
               ReqLLM.speak("openai:tts-1", "Testing wav format output.",
                 voice: "nova",
                 output_format: :wav
               )

      assert is_binary(result.audio)
      assert byte_size(result.audio) > 1000
      assert result.format == "wav"
      assert result.media_type == "audio/wav"
    end
  end
end

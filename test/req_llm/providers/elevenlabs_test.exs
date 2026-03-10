defmodule ReqLLM.Providers.ElevenLabsTest do
  @moduledoc """
  Unit tests for ElevenLabs provider.

  Tests provider configuration, request preparation, and unsupported operations.
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Providers.ElevenLabs

  describe "provider configuration" do
    test "has correct provider id" do
      assert ElevenLabs.provider_id() == :elevenlabs
    end

    test "has correct default base URL" do
      assert ElevenLabs.default_base_url() == "https://api.elevenlabs.io"
    end

    test "has correct default env key" do
      assert ElevenLabs.default_env_key() == "ELEVENLABS_API_KEY"
    end
  end

  describe "provider discovery" do
    test "is discoverable in the provider registry" do
      assert {:ok, ElevenLabs} = ReqLLM.provider(:elevenlabs)
    end
  end

  describe "unsupported operations" do
    test "rejects :chat operation" do
      assert {:error, error} =
               ElevenLabs.prepare_request(:chat, "elevenlabs:model", "hello", [])

      assert Exception.message(error) =~ "not supported by ElevenLabs"
      assert Exception.message(error) =~ ":chat"
    end

    test "rejects :embedding operation" do
      assert {:error, error} =
               ElevenLabs.prepare_request(:embedding, "elevenlabs:model", "hello", [])

      assert Exception.message(error) =~ "not supported by ElevenLabs"
    end
  end

  describe "prepare_request(:speech, ...)" do
    setup do
      # Set a fake API key for testing
      System.put_env("ELEVENLABS_API_KEY", "test-key-123")
      on_exit(fn -> System.delete_env("ELEVENLABS_API_KEY") end)
    end

    test "builds request with correct URL structure" do
      model = %LLMDB.Model{id: "eleven_multilingual_v2", provider: :elevenlabs}

      assert {:ok, request} =
               ElevenLabs.prepare_request(:speech, model, "Hello world", [])

      url = URI.to_string(request.url)
      assert url =~ "/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM"
    end

    test "uses xi-api-key header (not Bearer)" do
      model = %LLMDB.Model{id: "eleven_multilingual_v2", provider: :elevenlabs}

      assert {:ok, request} =
               ElevenLabs.prepare_request(:speech, model, "Hello world", [])

      assert Req.Request.get_header(request, "xi-api-key") == ["test-key-123"]
      assert Req.Request.get_header(request, "authorization") == []
    end

    test "uses custom voice in URL when specified" do
      model = %LLMDB.Model{id: "eleven_multilingual_v2", provider: :elevenlabs}

      assert {:ok, request} =
               ElevenLabs.prepare_request(:speech, model, "Hello", voice: "custom-voice-id")

      url = URI.to_string(request.url)
      assert url =~ "/v1/text-to-speech/custom-voice-id"
    end

    test "maps :mp3 format to ElevenLabs format string" do
      model = %LLMDB.Model{id: "eleven_multilingual_v2", provider: :elevenlabs}

      assert {:ok, request} =
               ElevenLabs.prepare_request(:speech, model, "Hello", output_format: :mp3)

      assert request.options.params == [output_format: "mp3_44100_128"]
    end

    test "maps :pcm format to ElevenLabs format string" do
      model = %LLMDB.Model{id: "eleven_multilingual_v2", provider: :elevenlabs}

      assert {:ok, request} =
               ElevenLabs.prepare_request(:speech, model, "Hello", output_format: :pcm)

      assert request.options.params == [output_format: "pcm_44100"]
    end

    test "maps :opus format to ElevenLabs format string" do
      model = %LLMDB.Model{id: "eleven_multilingual_v2", provider: :elevenlabs}

      assert {:ok, request} =
               ElevenLabs.prepare_request(:speech, model, "Hello", output_format: :opus)

      assert request.options.params == [output_format: "opus_48000_64"]
    end

    test "includes model_id and text in body" do
      model = %LLMDB.Model{id: "eleven_multilingual_v2", provider: :elevenlabs}

      assert {:ok, request} =
               ElevenLabs.prepare_request(:speech, model, "Hello world", [])

      body = Jason.decode!(request.body)
      assert body["text"] == "Hello world"
      assert body["model_id"] == "eleven_multilingual_v2"
    end

    test "includes language_code when language specified" do
      model = %LLMDB.Model{id: "eleven_multilingual_v2", provider: :elevenlabs}

      assert {:ok, request} =
               ElevenLabs.prepare_request(:speech, model, "Hola", language: "es")

      body = Jason.decode!(request.body)
      assert body["language_code"] == "es"
    end

    test "includes voice_settings from provider_options" do
      model = %LLMDB.Model{id: "eleven_multilingual_v2", provider: :elevenlabs}

      assert {:ok, request} =
               ElevenLabs.prepare_request(:speech, model, "Hello",
                 provider_options: [stability: 0.5, similarity_boost: 0.8]
               )

      body = Jason.decode!(request.body)
      assert body["voice_settings"]["stability"] == 0.5
      assert body["voice_settings"]["similarity_boost"] == 0.8
    end

    test "omits voice_settings when no relevant provider_options" do
      model = %LLMDB.Model{id: "eleven_multilingual_v2", provider: :elevenlabs}

      assert {:ok, request} =
               ElevenLabs.prepare_request(:speech, model, "Hello", [])

      body = Jason.decode!(request.body)
      refute Map.has_key?(body, "voice_settings")
    end

    test "uses custom base_url when specified" do
      model = %LLMDB.Model{id: "eleven_multilingual_v2", provider: :elevenlabs}

      assert {:ok, request} =
               ElevenLabs.prepare_request(:speech, model, "Hello",
                 base_url: "https://custom.api.com"
               )

      assert request.options.base_url == "https://custom.api.com"
    end
  end

  describe "prepare_request(:transcription, ...)" do
    setup do
      System.put_env("ELEVENLABS_API_KEY", "test-key-123")
      on_exit(fn -> System.delete_env("ELEVENLABS_API_KEY") end)
    end

    test "builds request with correct transcription endpoint" do
      model = %LLMDB.Model{id: "scribe_v2", provider: :elevenlabs}

      assert {:ok, request} =
               ElevenLabs.prepare_request(:transcription, model, "audio-bytes", [])

      url = URI.to_string(request.url)
      assert url =~ "/v1/speech-to-text"
    end

    test "uses xi-api-key header for transcription" do
      model = %LLMDB.Model{id: "scribe_v2", provider: :elevenlabs}

      assert {:ok, request} =
               ElevenLabs.prepare_request(:transcription, model, "audio-bytes", [])

      assert Req.Request.get_header(request, "xi-api-key") == ["test-key-123"]
      assert Req.Request.get_header(request, "authorization") == []
    end

    test "includes model_id and language_code in multipart body" do
      model = %LLMDB.Model{id: "scribe_v2", provider: :elevenlabs}

      assert {:ok, request} =
               ElevenLabs.prepare_request(:transcription, model, "audio-bytes", language: "en")

      assert request.options.form_multipart[:model_id] == "scribe_v2"
      assert request.options.form_multipart[:language_code] == "en"
    end

    test "passes transcription provider_options through multipart and query params" do
      model = %LLMDB.Model{id: "scribe_v2", provider: :elevenlabs}

      assert {:ok, request} =
               ElevenLabs.prepare_request(:transcription, model, "audio-bytes",
                 provider_options: [
                   enable_logging: false,
                   diarize: true,
                   timestamps_granularity: "word",
                   keyterms: ["ReqLLM", "ElevenLabs"]
                 ]
               )

      form_parts = request.options.form_multipart

      assert request.options.params == [enable_logging: false]
      assert form_parts[:diarize] == "true"
      assert form_parts[:timestamps_granularity] == "word"
      assert Keyword.get_values(form_parts, :keyterms) == ["ReqLLM", "ElevenLabs"]
    end
  end
end

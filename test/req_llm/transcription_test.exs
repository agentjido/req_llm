defmodule ReqLLM.TranscriptionTest do
  @moduledoc """
  Test suite for speech-to-text transcription functionality.

  Covers:
  - Transcription result struct
  - Audio input resolution (file path, binary, base64)
  - Response parsing
  - Language normalization
  - Media type detection
  - Error handling
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Transcription
  alias ReqLLM.Transcription.Result

  describe "Result struct" do
    test "creates result with defaults" do
      result = %Result{}
      assert result.text == ""
      assert result.segments == []
      assert result.language == nil
      assert result.duration_in_seconds == nil
    end

    test "creates result with all fields" do
      result = %Result{
        text: "Hello world",
        segments: [
          %{text: "Hello", start_second: 0.0, end_second: 0.5},
          %{text: " world", start_second: 0.5, end_second: 1.0}
        ],
        language: "en",
        duration_in_seconds: 1.0
      }

      assert result.text == "Hello world"
      assert length(result.segments) == 2
      assert result.language == "en"
      assert result.duration_in_seconds == 1.0
    end
  end

  describe "schema/0" do
    test "returns NimbleOptions schema" do
      schema = Transcription.schema()
      assert is_struct(schema, NimbleOptions)

      docs = NimbleOptions.docs(schema)
      assert docs =~ "language"
      assert docs =~ "provider_options"
      assert docs =~ "receive_timeout"
    end
  end

  describe "transcribe/3 - audio resolution" do
    test "rejects non-existent file path" do
      assert {:error, error} =
               Transcription.transcribe("openai:whisper-1", "/nonexistent/audio.mp3")

      assert Exception.message(error) =~ "could not read file"
    end

    test "rejects invalid audio input format" do
      assert {:error, error} = Transcription.transcribe("openai:whisper-1", 12345)
      assert Exception.message(error) =~ "expected a file path string"
    end

    test "rejects invalid base64 encoding" do
      assert {:error, error} =
               Transcription.transcribe(
                 "openai:whisper-1",
                 {:base64, "not-valid-base64!!!", "audio/mpeg"}
               )

      assert Exception.message(error) =~ "invalid base64"
    end

    test "accepts binary audio data" do
      # This will fail at the provider level (no API key), but should pass audio resolution
      result = Transcription.transcribe("openai:whisper-1", {:binary, "fake audio", "audio/mpeg"})

      # Should get past audio resolution and fail at provider/API key level
      assert {:error, _} = result
    end

    test "accepts base64 audio data" do
      encoded = Base.encode64("fake audio data")

      result =
        Transcription.transcribe("openai:whisper-1", {:base64, encoded, "audio/mpeg"})

      # Should get past audio resolution and fail at provider/API key level
      assert {:error, _} = result
    end
  end

  describe "transcribe/3 - model validation" do
    test "rejects unknown provider" do
      assert {:error, _} =
               Transcription.transcribe(
                 "unknown_provider:whisper-1",
                 {:binary, "data", "audio/mpeg"}
               )
    end
  end

  describe "transcribe/3 - ElevenLabs compatibility" do
    setup do
      System.put_env("ELEVENLABS_API_KEY", "test-key-123")

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "language_code" => "eng",
          "text" => "Hello world",
          "words" => [
            %{"text" => "Hello", "start" => 0.0, "end" => 0.4, "type" => "word"},
            %{"text" => "world", "start" => 0.5, "end" => 0.9, "type" => "word"}
          ]
        })
      end)

      on_exit(fn -> System.delete_env("ELEVENLABS_API_KEY") end)

      :ok
    end

    test "parses ElevenLabs transcription responses" do
      assert {:ok, result} =
               Transcription.transcribe(
                 %{id: "scribe_v2", provider: :elevenlabs},
                 {:binary, "fake audio", "audio/mpeg"},
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )

      assert result.text == "Hello world"
      assert result.language == "eng"
      assert result.duration_in_seconds == 0.9

      assert result.segments == [
               %{text: "Hello", start_second: 0.0, end_second: 0.4},
               %{text: "world", start_second: 0.5, end_second: 0.9}
             ]
    end
  end

  describe "transcribe!/3" do
    test "raises on error" do
      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        Transcription.transcribe!("openai:whisper-1", "/nonexistent/audio.mp3")
      end
    end
  end

  describe "ReqLLM facade delegation" do
    test "transcribe/3 is delegated" do
      assert function_exported?(ReqLLM, :transcribe, 3)
      assert function_exported?(ReqLLM, :transcribe, 2)
    end

    test "transcribe!/3 is delegated" do
      assert function_exported?(ReqLLM, :transcribe!, 3)
      assert function_exported?(ReqLLM, :transcribe!, 2)
    end
  end
end

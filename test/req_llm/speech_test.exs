defmodule ReqLLM.SpeechTest do
  @moduledoc """
  Test suite for text-to-speech functionality.

  Covers:
  - Speech result struct
  - Schema validation
  - Error handling
  - ReqLLM facade delegation
  """

  use ExUnit.Case, async: true

  alias ReqLLM.Speech
  alias ReqLLM.Speech.Result

  setup do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        400,
        Jason.encode!(%{"error" => %{"message" => "bad request"}})
      )
    end)

    :ok
  end

  describe "Result struct" do
    test "creates result with defaults" do
      result = %Result{}
      assert result.audio == <<>>
      assert result.media_type == "audio/mpeg"
      assert result.format == "mp3"
      assert result.duration_in_seconds == nil
    end

    test "creates result with all fields" do
      audio_data = <<1, 2, 3, 4, 5>>

      result = %Result{
        audio: audio_data,
        media_type: "audio/wav",
        format: "wav",
        duration_in_seconds: 2.5
      }

      assert result.audio == audio_data
      assert result.media_type == "audio/wav"
      assert result.format == "wav"
      assert result.duration_in_seconds == 2.5
    end
  end

  describe "schema/0" do
    test "returns NimbleOptions schema" do
      schema = Speech.schema()
      assert is_struct(schema, NimbleOptions)

      docs = NimbleOptions.docs(schema)
      assert docs =~ "voice"
      assert docs =~ "speed"
      assert docs =~ "output_format"
      assert docs =~ "provider_options"
      assert docs =~ "receive_timeout"
    end
  end

  describe "speak/3 - error handling" do
    test "rejects unknown provider" do
      assert {:error, _} =
               Speech.speak("unknown_provider:tts-1", "Hello")
    end

    test "passes text through to provider" do
      assert {:error, error} =
               Speech.speak("openai:tts-1", "Hello world",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )

      assert Exception.message(error) =~ "Speech generation failed"
    end
  end

  describe "speak!/3" do
    test "raises on error" do
      assert_raise UndefinedFunctionError, fn ->
        Speech.speak!("unknown_provider:tts-1", "Hello")
      end
    end
  end

  describe "ReqLLM facade delegation" do
    test "speak/3 is delegated" do
      assert function_exported?(ReqLLM, :speak, 3)
      assert function_exported?(ReqLLM, :speak, 2)
    end

    test "speak!/3 is delegated" do
      assert function_exported?(ReqLLM, :speak!, 3)
      assert function_exported?(ReqLLM, :speak!, 2)
    end
  end
end

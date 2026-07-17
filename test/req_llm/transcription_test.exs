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

  @moduletag contract: :public_api

  import ReqLLM.Test.Helpers, only: [pricing_from_cost: 1]

  alias ReqLLM.Transcription
  alias ReqLLM.Transcription.DetailedResult
  alias ReqLLM.Transcription.Result

  defmodule DetailedHTTP do
  end

  defmodule SparseDetailedHTTP do
  end

  describe "Result struct" do
    test "creates result with defaults" do
      result = %Result{}
      assert result.text == ""
      assert result.segments == []
      assert result.language == nil
      assert result.duration_in_seconds == nil

      assert Map.from_struct(result) == %{
               text: "",
               segments: [],
               language: nil,
               duration_in_seconds: nil
             }
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
      assert {:error, error} = Transcription.transcribe("openai:whisper-1", 12_345)
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

  describe "transcribe_detailed/3" do
    test "wraps the unchanged result with redacted metadata from one request" do
      test_pid = self()
      handler_id = "transcription-detailed-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [[:req_llm, :token_usage], [:req_llm, :request, :stop]],
        fn event, _measurements, metadata, _config ->
          if metadata.model.id == "transcription-metadata-test" do
            send(test_pid, {event, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(DetailedHTTP, fn conn ->
        send(test_pid, :detailed_request)

        conn
        |> Plug.Conn.put_resp_header("x-request-id", "provider_req_123")
        |> Plug.Conn.put_resp_header("openai-processing-ms", "8")
        |> Req.Test.json(%{
          "id" => "transcription_123",
          "text" => "Hello world",
          "segments" => [%{"text" => "Hello world", "start" => 0.0, "end" => 1.0}],
          "language" => "english",
          "duration" => 1.0,
          "usage" => %{"input_tokens" => 10, "output_tokens" => 4, "total_tokens" => 14},
          "warnings" => ["credential sk-secret was ignored"],
          "provider_metadata" => %{
            "api_key" => "sk-secret",
            "url" => "https://example.com/transcription?token=sk-secret"
          }
        })
      end)

      model = %LLMDB.Model{
        id: "transcription-metadata-test",
        provider: :openai,
        pricing: pricing_from_cost(%{input: 1.0, output: 2.0})
      }

      assert {:ok, %DetailedResult{} = detailed} =
               ReqLLM.transcribe_detailed(
                 model,
                 {:binary, "audio", "audio/mpeg"},
                 api_key: "sk-secret",
                 req_http_options: [plug: {Req.Test, DetailedHTTP}]
               )

      assert_receive :detailed_request
      refute_receive :detailed_request, 20

      assert_receive {[:req_llm, :request, :stop], request_stop}
      assert request_stop.operation == :transcription
      assert request_stop.usage.tokens.input_tokens == 10

      assert_receive {[:req_llm, :token_usage], %{operation: :transcription}}

      assert detailed.result == %Result{
               text: "Hello world",
               segments: [%{text: "Hello world", start_second: 0.0, end_second: 1.0}],
               language: "en",
               duration_in_seconds: 1.0
             }

      assert Map.from_struct(detailed.result) == %{
               text: "Hello world",
               segments: [%{text: "Hello world", start_second: 0.0, end_second: 1.0}],
               language: "en",
               duration_in_seconds: 1.0
             }

      metadata = detailed.call_metadata
      assert metadata.model == "transcription-metadata-test"
      assert metadata.provider == :openai
      assert is_binary(metadata.request_id)
      assert metadata.request_id != "provider_req_123"
      assert metadata.response_id == "transcription_123"
      assert metadata.usage.input_tokens == 10
      assert metadata.usage.output_tokens == 4
      assert metadata.usage.total_tokens == 14
      assert metadata.usage.total_cost > 0
      assert metadata.warnings == ["credential [REDACTED] was ignored"]
      assert metadata.timings.request_ms > 0
      assert metadata.timings.provider_ms == 8.0
      assert metadata.provider_metadata.request_id == "provider_req_123"
      assert metadata.provider_metadata["api_key"] == "[REDACTED]"

      assert metadata.provider_metadata["url"] ==
               "https://example.com/transcription?token=[REDACTED]"

      refute inspect(detailed) =~ "sk-secret"
    end

    test "omits metadata that the provider and request pipeline do not supply" do
      Req.Test.stub(SparseDetailedHTTP, fn conn ->
        Req.Test.json(conn, %{"text" => "Hello"})
      end)

      assert {:ok, %DetailedResult{result: %Result{text: "Hello"}} = detailed} =
               ReqLLM.transcribe_detailed(
                 %LLMDB.Model{id: "whisper-1", provider: :openai},
                 {:binary, "audio", "audio/mpeg"},
                 api_key: "test-key",
                 req_http_options: [plug: {Req.Test, SparseDetailedHTTP}]
               )

      assert detailed.call_metadata.model == "whisper-1"
      assert detailed.call_metadata.provider == :openai
      assert is_binary(detailed.call_metadata.request_id)
      assert detailed.call_metadata.timings.request_ms > 0
      refute Map.has_key?(detailed.call_metadata, :response_id)
      refute Map.has_key?(detailed.call_metadata, :usage)
      refute Map.has_key?(detailed.call_metadata, :warnings)
      refute Map.has_key?(detailed.call_metadata, :provider_metadata)
    end

    test "bang variant raises the same error as the legacy facade" do
      legacy_error =
        assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
          Transcription.transcribe!("openai:whisper-1", "/nonexistent/audio.mp3")
        end

      detailed_error =
        assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
          Transcription.transcribe_detailed!("openai:whisper-1", "/nonexistent/audio.mp3")
        end

      assert Exception.message(detailed_error) == Exception.message(legacy_error)
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

    test "detailed transcription functions are delegated" do
      assert function_exported?(ReqLLM, :transcribe_detailed, 3)
      assert function_exported?(ReqLLM, :transcribe_detailed, 2)
      assert function_exported?(ReqLLM, :transcribe_detailed!, 3)
      assert function_exported?(ReqLLM, :transcribe_detailed!, 2)
    end
  end
end

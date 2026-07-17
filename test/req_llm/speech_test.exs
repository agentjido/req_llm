defmodule ReqLLM.SpeechTest do
  @moduledoc """
  Test suite for text-to-speech functionality.

  Covers:
  - Speech result struct
  - Schema validation
  - Error handling
  - ReqLLM facade delegation
  """

  use ExUnit.Case, async: false

  @moduletag contract: :public_api

  import ReqLLM.Test.Helpers, only: [pricing_from_cost: 1]

  alias ReqLLM.Speech
  alias ReqLLM.Speech.DetailedResult
  alias ReqLLM.Speech.Result

  defmodule DetailedHTTP do
  end

  defmodule SparseDetailedHTTP do
  end

  defmodule DetailedProvider do
    use ReqLLM.Provider,
      id: :speech_detailed_test,
      default_base_url: "https://speech.example/v1"

    @impl ReqLLM.Provider
    def prepare_request(:speech, model, text, opts) do
      http_opts = Keyword.get(opts, :req_http_options, [])

      request =
        Req.new(
          [
            url: "/audio/speech",
            method: :post,
            base_url: default_base_url(),
            body: text,
            decode_body: false
          ] ++ http_opts
        )
        |> Req.Request.append_response_steps(
          speech_test_metadata: &__MODULE__.put_test_metadata/1
        )
        |> ReqLLM.Step.Telemetry.attach(model, Keyword.put(opts, :operation, :speech))

      {:ok, request}
    end

    @impl ReqLLM.Provider
    def extract_usage(_body, _model) do
      {:ok, %{input: 10, output: 4, total_tokens: 14}}
    end

    @doc false
    def put_test_metadata({request, response}) do
      private =
        Map.put(response.private, :req_llm_request_plan, %{
          warnings: ["input speech-secret was ignored"]
        })

      {request, %{response | private: private}}
    end
  end

  setup_all do
    assert {:ok, :speech_detailed_test} = ReqLLM.Providers.register(DetailedProvider)
    on_exit(fn -> ReqLLM.Providers.unregister(:speech_detailed_test) end)
    :ok
  end

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

      assert Map.from_struct(result) == %{
               audio: <<>>,
               media_type: "audio/mpeg",
               format: "mp3",
               duration_in_seconds: nil
             }
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
                 api_key: "test-key",
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

  describe "speak_detailed/3" do
    test "wraps the unchanged raw result with redacted metadata from one request" do
      test_pid = self()
      audio = <<0, 255, 1, 254, 2, 253>>
      handler_id = "speech-detailed-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [[:req_llm, :token_usage], [:req_llm, :request, :stop]],
        fn event, _measurements, metadata, _config ->
          if metadata.model.id == "speech-metadata-test" do
            send(test_pid, {event, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(DetailedHTTP, fn conn ->
        send(test_pid, :detailed_request)

        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.put_resp_header("x-request-id", "provider_req_123")
        |> Plug.Conn.put_resp_header("openai-processing-ms", "8")
        |> Plug.Conn.send_resp(200, audio)
      end)

      model = %LLMDB.Model{
        id: "speech-metadata-test",
        provider: :speech_detailed_test,
        pricing: pricing_from_cost(%{input: 1.0, output: 2.0})
      }

      assert {:ok, %DetailedResult{} = detailed} =
               ReqLLM.speak_detailed(
                 model,
                 "speech-secret",
                 output_format: :mp3,
                 req_http_options: [plug: {Req.Test, DetailedHTTP}]
               )

      assert_receive :detailed_request
      refute_receive :detailed_request, 20

      assert_receive {[:req_llm, :request, :stop], request_stop}
      assert request_stop.operation == :speech
      assert request_stop.usage.tokens.input_tokens == 10
      assert_receive {[:req_llm, :token_usage], %{operation: :speech}}

      assert detailed.result == %Result{
               audio: audio,
               media_type: "audio/mpeg",
               format: "mp3",
               duration_in_seconds: nil
             }

      assert Map.from_struct(detailed.result) == %{
               audio: audio,
               media_type: "audio/mpeg",
               format: "mp3",
               duration_in_seconds: nil
             }

      metadata = detailed.call_metadata
      assert metadata.model == "speech-metadata-test"
      assert metadata.provider == :speech_detailed_test
      assert metadata.status == 200
      assert is_binary(metadata.request_id)
      assert metadata.request_id != "provider_req_123"
      assert metadata.usage.input_tokens == 10
      assert metadata.usage.output_tokens == 4
      assert metadata.usage.total_tokens == 14
      assert metadata.usage.total_cost > 0
      assert metadata.warnings == ["input [REDACTED] was ignored"]
      assert metadata.timings.request_ms > 0
      assert metadata.timings.provider_ms == 8.0
      assert metadata.provider_metadata.request_id == "provider_req_123"
      refute Map.has_key?(metadata, :response_id)
      refute inspect(detailed) =~ "speech-secret"
    end

    test "omits metadata that the provider and request pipeline do not supply" do
      audio = <<1, 2, 3, 4>>

      Req.Test.stub(SparseDetailedHTTP, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("audio/mpeg")
        |> Plug.Conn.send_resp(200, audio)
      end)

      assert {:ok, %DetailedResult{result: %Result{audio: ^audio}} = detailed} =
               ReqLLM.speak_detailed(
                 %LLMDB.Model{id: "tts-1", provider: :openai},
                 "Hello",
                 api_key: "test-key",
                 req_http_options: [plug: {Req.Test, SparseDetailedHTTP}]
               )

      assert detailed.call_metadata.model == "tts-1"
      assert detailed.call_metadata.provider == :openai
      assert detailed.call_metadata.status == 200
      assert is_binary(detailed.call_metadata.request_id)
      assert detailed.call_metadata.timings.request_ms > 0
      refute Map.has_key?(detailed.call_metadata, :response_id)
      refute Map.has_key?(detailed.call_metadata, :usage)
      refute Map.has_key?(detailed.call_metadata, :warnings)
      refute Map.has_key?(detailed.call_metadata, :provider_metadata)
    end

    test "bang variant raises the same HTTP error as the legacy facade" do
      opts = [api_key: "test-key", req_http_options: [plug: {Req.Test, __MODULE__}]]

      legacy_error =
        assert_raise ReqLLM.Error.API.Request, fn ->
          Speech.speak!("openai:tts-1", "Hello", opts)
        end

      detailed_error =
        assert_raise ReqLLM.Error.API.Request, fn ->
          Speech.speak_detailed!("openai:tts-1", "Hello", opts)
        end

      assert Exception.message(detailed_error) == Exception.message(legacy_error)
      assert detailed_error.status == legacy_error.status
      assert detailed_error.response_body == legacy_error.response_body
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

    test "detailed speech functions are delegated" do
      assert function_exported?(ReqLLM, :speak_detailed, 3)
      assert function_exported?(ReqLLM, :speak_detailed, 2)
      assert function_exported?(ReqLLM, :speak_detailed!, 3)
      assert function_exported?(ReqLLM, :speak_detailed!, 2)
    end
  end
end

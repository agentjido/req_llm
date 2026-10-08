defmodule ReqLLM.Providers.StepFunTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.StepFun
  alias ReqLLM.Providers.StepFunAI

  defmodule HTTP do
  end

  test "registers separate China and Global providers" do
    assert {:ok, StepFun} = ReqLLM.provider(:stepfun)
    assert {:ok, StepFunAI} = ReqLLM.provider(:stepfun_ai)
    assert StepFun.base_url() == "https://api.stepfun.com/v1"
    assert StepFunAI.base_url() == "https://api.stepfun.ai/v1"
    assert StepFun.default_env_key() == "STEPFUN_API_KEY"
    assert StepFunAI.default_env_key() == "STEPFUN_API_KEY"
  end

  test "resolves released audio models from the catalog" do
    for provider <- [:stepfun, :stepfun_ai],
        {id, operation} <- [
          {"stepaudio-3-tts", :speech},
          {"stepaudio-3-asr-max", :transcription},
          {"stepaudio-3-chat-preview", :text}
        ] do
      assert {:ok, catalog_model} = LLMDB.model(provider, id)
      assert ReqLLM.model!("#{provider}:#{id}") == catalog_model
      assert ReqLLM.ModelOperation.supported?(catalog_model, operation)
    end
  end

  test "generates text with bearer authentication and reasoning options" do
    Req.Test.stub(HTTP, fn conn ->
      assert conn.request_path == "/v1/chat/completions"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      assert body["model"] == "step-3.5-flash"
      assert body["reasoning_format"] == "deepseek-style"
      assert body["reasoning_effort"] == "low"
      assert body["max_tokens"] == 32
      Req.Test.json(conn, chat_response())
    end)

    assert {:ok, response} =
             ReqLLM.generate_text(model("step-3.5-flash"), "Hello",
               api_key: "test-key",
               reasoning_effort: :low,
               max_tokens: 32,
               req_http_options: [plug: {Req.Test, HTTP}]
             )

    assert ReqLLM.Response.text(response) == "Hello."
  end

  test "encodes audio and video content without image fields or empty text" do
    Req.Test.stub(HTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      [message] = body["messages"]

      assert message["content"] == [
               %{"type" => "text", "text" => "Describe this."},
               %{
                 "type" => "input_audio",
                 "input_audio" => %{"data" => "data:audio/wav;base64," <> Base.encode64("audio")}
               },
               %{"type" => "video_url", "video_url" => %{"url" => "https://example.com/a.mp4"}}
             ]

      Req.Test.json(conn, chat_response())
    end)

    context =
      Context.new([
        Context.user([
          ContentPart.text("Describe this."),
          ContentPart.file("audio", "sample.wav", "audio/wav"),
          ContentPart.video_url("https://example.com/a.mp4")
        ])
      ])

    assert {:ok, _} =
             ReqLLM.generate_text(model("stepaudio-3-chat-preview"), context, http_options())
  end

  test "builds streaming chat requests with the StepFun body" do
    assert {:ok, request} =
             StepFunAI.attach_stream(
               model("step-3.5-flash"),
               Context.new([Context.user("Hello")]),
               [api_key: "test-key", max_tokens: 16],
               ReqLLM.Finch
             )

    assert request.host == "api.stepfun.ai"
    assert request.path == "/v1/chat/completions"
    body = Jason.decode!(request.body)
    assert body["stream"]
    assert body["reasoning_format"] == "deepseek-style"
  end

  test "preserves image content and thinking when audio is also present" do
    context =
      Context.new([
        %ReqLLM.Message{
          role: :assistant,
          content: [
            ContentPart.thinking("Earlier reasoning."),
            ContentPart.image_url("https://example.com/image.png", %{detail: "low"}),
            ContentPart.file("audio", "sample.mp3", "audio/mp3")
          ]
        }
      ])

    assert {:ok, request} =
             StepFunAI.attach_stream(
               model("stepaudio-3-chat-preview"),
               context,
               [api_key: "test-key"],
               ReqLLM.Finch
             )

    [message] = Jason.decode!(request.body)["messages"]
    assert message["reasoning_content"] == "Earlier reasoning."
    assert [image, audio] = message["content"]
    assert image["image_url"] == %{"url" => "https://example.com/image.png", "detail" => "low"}
    assert audio["input_audio"]["data"] == "data:audio/mpeg;base64," <> Base.encode64("audio")
  end

  test "rejects unsupported audio chat input" do
    context =
      Context.new([
        Context.user([ContentPart.file("audio", "sample.flac", "audio/flac")])
      ])

    assert {:error, %ReqLLM.Error.API.Request{reason: reason}} =
             StepFunAI.attach_stream(
               model("stepaudio-3-chat-preview"),
               context,
               [api_key: "test-key"],
               ReqLLM.Finch
             )

    assert reason =~ "MP3 or WAV"
  end

  test "returns binary speech and forwards StepFun delivery options" do
    Req.Test.stub(HTTP, fn conn ->
      assert conn.request_path == "/v1/audio/speech"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      assert body["model"] == "stepaudio-3-tts"
      assert body["voice"] == "soft-spoken-gentleman"
      assert body["language"] == "en"
      assert body["instruction"] == "Speak slowly."
      assert body["sample_rate"] == 24_000
      assert body["response_format"] == "wav"

      conn
      |> Plug.Conn.put_resp_content_type("audio/wav")
      |> Plug.Conn.send_resp(200, "RIFF-audio")
    end)

    assert {:ok, result} =
             ReqLLM.speak(
               model("stepaudio-3-tts"),
               "Hello",
               http_options() ++
                 [
                   language: "en",
                   output_format: :wav,
                   provider_options: [instruction: "Speak slowly.", sample_rate: 24_000]
                 ]
             )

    assert result.audio == "RIFF-audio"
    assert result.format == "wav"
    assert result.media_type == "audio/wav"
  end

  test "uses the China URL and a model base URL override for speech" do
    assert {:ok, request} =
             StepFun.prepare_request(
               :speech,
               model("stepaudio-2.5-tts", :stepfun),
               "Hello",
               api_key: "test-key"
             )

    assert request.options[:base_url] == "https://api.stepfun.com/v1"

    model = %{model("stepaudio-3-tts") | base_url: "https://proxy.example/v1"}

    assert {:ok, request} =
             StepFunAI.prepare_request(:speech, model, "Hello", api_key: "test-key")

    assert request.options[:base_url] == "https://proxy.example/v1"
  end

  test "rejects speech responses that the public result cannot represent" do
    for options <- [
          [provider_options: [return_url: true]],
          [provider_options: %{"stream_format" => "sse"}],
          [output_format: :aac]
        ] do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               StepFunAI.prepare_request(:speech, model("stepaudio-3-tts"), "Hello", options)
    end
  end

  test "transcribes a JSON audio request and uses the final SSE text" do
    Req.Test.stub(HTTP, fn conn ->
      assert conn.request_path == "/v1/audio/asr/sse"
      assert Plug.Conn.get_req_header(conn, "accept") == ["text/event-stream"]
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      assert body["audio"]["data"] == Base.encode64("audio")
      assert body["audio"]["input"]["format"] == %{"type" => "wav"}

      assert body["audio"]["input"]["transcription"] == %{
               "model" => "stepaudio-3-asr-max",
               "language" => "en",
               "enable_itn" => false
             }

      sse(conn, [
        %{"type" => "transcript.text.delta", "delta" => "partial"},
        %{
          "type" => "transcript.text.done",
          "text" => "Final transcript.",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
        }
      ])
    end)

    assert {:ok, detailed} =
             ReqLLM.transcribe_detailed(
               model("stepaudio-3-asr-max"),
               {:binary, "audio", "audio/wav"},
               http_options() ++ [language: "en", provider_options: [enable_itn: false]]
             )

    assert detailed.result.text == "Final transcript."
    assert detailed.result.segments == []
    assert detailed.call_metadata.provider == :stepfun_ai
    assert detailed.call_metadata.usage.input_tokens == 10
    assert detailed.call_metadata.usage.output_tokens == 2
  end

  test "accepts configured PCM and rejects unsupported input formats" do
    pcm = %{type: "pcm", codec: "pcm_s16le", rate: 16_000, bits: 16, channel: 1}

    assert {:ok, request} =
             StepFunAI.prepare_request(
               :transcription,
               model("stepaudio-2.5-asr"),
               "audio",
               api_key: "test-key",
               media_type: "audio/pcm",
               provider_options: [audio_format: pcm]
             )

    assert request.options[:json].audio.input.format == pcm

    for type <- ["audio/pcm", "audio/flac", "audio/webm"] do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               StepFunAI.prepare_request(
                 :transcription,
                 model("stepaudio-3-asr-max"),
                 "audio",
                 media_type: type
               )
    end
  end

  test "does not return a partial transcript when the SSE stream fails or ends early" do
    for events <- [
          [%{"type" => "transcript.text.delta", "delta" => "partial"}],
          [
            %{"type" => "transcript.text.done", "text" => "partial"},
            %{"type" => "error", "message" => "Recognition failed"}
          ]
        ] do
      Req.Test.stub(HTTP, &sse(&1, events))

      assert {:error, _} =
               ReqLLM.transcribe(
                 model("stepaudio-3-asr-max"),
                 {:binary, "audio", "audio/wav"},
                 http_options()
               )
    end
  end

  test "rejects malformed SSE events and preserves HTTP errors" do
    Req.Test.stub(HTTP, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, "data: invalid-json\n\n")
    end)

    assert {:error, _} =
             ReqLLM.transcribe(
               model("stepaudio-3-asr-max"),
               {:binary, "audio", "audio/wav"},
               http_options()
             )

    Req.Test.stub(HTTP, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => %{"message" => "Invalid key"}}))
    end)

    assert {:error, %ReqLLM.Error.API.Request{status: 401}} =
             ReqLLM.transcribe(
               model("stepaudio-3-asr-max"),
               {:binary, "audio", "audio/wav"},
               http_options()
             )
  end

  test "rejects other audio operations before sending a request" do
    for id <- [
          "stepaudio-3-music-preview",
          "stepaudio-3-gen-preview",
          "stepaudio-3-realtime-preview"
        ] do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               StepFunAI.prepare_request(:chat, model(id), "Hello", [])

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               StepFunAI.prepare_request(:speech, model(id), "Hello", [])
    end

    assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
             StepFunAI.prepare_request(:embedding, model("step-3.5-flash"), "Hello", [])

    assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
             StepFunAI.prepare_request(
               :transcription,
               model("stepaudio-2.5-asr-stream"),
               "audio",
               []
             )
  end

  defp model(id, provider \\ :stepfun_ai), do: ReqLLM.model!(%{id: id, provider: provider})

  defp http_options do
    [api_key: "test-key", max_retries: 0, req_http_options: [plug: {Req.Test, HTTP}]]
  end

  defp chat_response do
    %{
      "id" => "stepfun-test",
      "model" => "step-3.5-flash",
      "choices" => [
        %{"message" => %{"role" => "assistant", "content" => "Hello."}, "finish_reason" => "stop"}
      ],
      "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
    }
  end

  defp sse(conn, events) do
    body =
      Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n")) <> "data: [DONE]\n\n"

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(200, body)
  end
end

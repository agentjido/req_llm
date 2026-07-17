defmodule ReqLLM.TupleModelOptionsTest do
  use ExUnit.Case, async: false

  @moduletag contract: :public_api

  import ExUnit.CaptureIO

  defmodule ChatHTTP do
  end

  defmodule ObjectHTTP do
  end

  defmodule EmbeddingHTTP do
  end

  defmodule ImageHTTP do
  end

  defmodule TranscriptionHTTP do
  end

  defmodule SpeechHTTP do
  end

  defmodule RerankHTTP do
  end

  defmodule OCRHTTP do
  end

  defmodule CaptureStreamRequest do
    @behaviour ReqLLM.FinchRequestAdapter

    @impl true
    def call(request) do
      test_pid = Application.fetch_env!(:req_llm, :tuple_model_stream_test_pid)
      body = request.body |> IO.iodata_to_binary() |> Jason.decode!()
      send(test_pid, {:stream_request_body, body})
      request
    end
  end

  test "model/1 returns the same model for equivalent tuple identities" do
    assert {:ok, two_element} = ReqLLM.model({:openai, id: "gpt-4-0125-preview"})

    assert {:ok, three_element} =
             ReqLLM.model({:openai, "gpt-4-0125-preview", temperature: 0.2})

    assert two_element == three_element
  end

  test "two-element keyword tuples do not become operation defaults" do
    call_opts = [temperature: 0.8]

    assert ReqLLM.ModelInput.merge_tuple_defaults(
             {:openai, id: "gpt-4-turbo", max_tokens: 64},
             :chat,
             call_opts
           ) == call_opts
  end

  test "explicit call options override tuple defaults including provider options" do
    tuple =
      {:openai, "gpt-4-0125-preview",
       temperature: 0.2, max_tokens: 64, provider_options: [service_tier: "auto", logprobs: false]}

    call_opts = [temperature: 0.8, provider_options: [logprobs: true]]

    assert ReqLLM.ModelInput.merge_tuple_defaults(tuple, :chat, call_opts) ==
             [
               max_tokens: 64,
               temperature: 0.8,
               provider_options: [logprobs: true]
             ]

    assert ReqLLM.ModelInput.merge_tuple_defaults(tuple, :chat, provider_options: []) ==
             [temperature: 0.2, max_tokens: 64, provider_options: []]
  end

  test "provider-keyed maps remain valid tuple defaults" do
    tuple =
      {:openai, "gpt-4-0125-preview", provider_options: %{openai: %{reasoning_summary: "auto"}}}

    assert ReqLLM.ModelInput.merge_tuple_defaults(tuple, :chat, []) ==
             [provider_options: %{openai: %{reasoning_summary: "auto"}}]
  end

  test "wrong-operation, invalid, duplicate, and ambiguous tuple defaults stay non-fatal" do
    tuple =
      {:cohere, "rerank-v3.5",
       query: "hidden query",
       top_n: 2,
       top_n: 1,
       max_tokens_per_doc: 0,
       api_secret: "must-not-appear"}

    warning =
      capture_io(:stderr, fn ->
        merged =
          ReqLLM.ModelInput.merge_tuple_defaults(
            tuple,
            :rerank,
            query: "visible query",
            documents: ["document"]
          )

        send(self(), {:merged_options, merged})
      end)

    assert_receive {:merged_options, [top_n: 2, query: "visible query", documents: ["document"]]}

    assert warning =~ ":query is controlled by the operation boundary"
    assert warning =~ ":top_n is duplicated"
    assert warning =~ ":max_tokens_per_doc has an invalid value"
    assert warning =~ ":api_secret is not accepted"
    refute warning =~ "hidden query"
    refute warning =~ "must-not-appear"
  end

  test "operation-control options do not become tuple defaults" do
    warning =
      capture_io(:stderr, fn ->
        merged =
          ReqLLM.ModelInput.merge_tuple_defaults(
            {:openai, "gpt-4-0125-preview", stream: true, temperature: 0.2},
            :chat,
            []
          )

        send(self(), {:operation_options, merged})
      end)

    assert_receive {:operation_options, [temperature: 0.2]}
    assert warning =~ ":stream is controlled by the operation boundary"
  end

  test "on_unsupported ignore suppresses tuple-default warnings" do
    assert capture_io(:stderr, fn ->
             assert ReqLLM.ModelInput.merge_tuple_defaults(
                      {:openai, "text-embedding-3-small", temperature: 0.2},
                      :embedding,
                      on_unsupported: :ignore
                    ) == [on_unsupported: :ignore]
           end) == ""
  end

  test "chat tuple defaults change only the corresponding request key" do
    stub_json(ChatHTTP, chat_response())
    opts = openai_opts(ChatHTTP)

    assert {:ok, _response} =
             ReqLLM.generate_text({:openai, id: "gpt-4-0125-preview"}, "Hello", opts)

    baseline = receive_body(ChatHTTP)

    assert {:ok, _response} =
             ReqLLM.generate_text(
               {:openai, "gpt-4-0125-preview", temperature: 0.2},
               "Hello",
               opts
             )

    with_default = receive_body(ChatHTTP)
    assert_body_delta(baseline, with_default, "temperature", 0.2)

    assert {:ok, _response} =
             ReqLLM.generate_text(
               {:openai, "gpt-4-0125-preview", temperature: 0.2},
               "Hello",
               Keyword.put(opts, :temperature, 0.8)
             )

    explicit = receive_body(ChatHTTP)
    assert_body_delta(baseline, explicit, "temperature", 0.8)
  end

  test "object tuple defaults change only the corresponding request key" do
    stub_json(ObjectHTTP, object_response())
    opts = openai_opts(ObjectHTTP)
    schema = [name: [type: :string, required: true]]

    assert {:ok, _response} =
             ReqLLM.generate_object(
               {:openai, id: "gpt-4-0125-preview"},
               "Return a person",
               schema,
               opts
             )

    baseline = receive_body(ObjectHTTP)

    assert {:ok, _response} =
             ReqLLM.generate_object(
               {:openai, "gpt-4-0125-preview", temperature: 0.2},
               "Return a person",
               schema,
               opts
             )

    assert_body_delta(baseline, receive_body(ObjectHTTP), "temperature", 0.2)
  end

  test "streaming object tuple defaults change only the corresponding request key" do
    previous_adapter = Application.get_env(:req_llm, :finch_request_adapter)
    previous_test_pid = Application.get_env(:req_llm, :tuple_model_stream_test_pid)

    on_exit(fn ->
      Application.put_env(:req_llm, :finch_request_adapter, previous_adapter)
      Application.put_env(:req_llm, :tuple_model_stream_test_pid, previous_test_pid)
    end)

    Application.put_env(:req_llm, :finch_request_adapter, CaptureStreamRequest)
    Application.put_env(:req_llm, :tuple_model_stream_test_pid, self())

    opts = [
      api_key: "test-key",
      base_url: "http://127.0.0.1:1/v1",
      max_retries: 0
    ]

    schema = [name: [type: :string, required: true]]

    assert {:ok, baseline_response} =
             ReqLLM.stream_object(
               {:openai, id: "gpt-4-0125-preview"},
               "Return a person",
               schema,
               opts
             )

    assert_receive {:stream_request_body, baseline}
    baseline_response.cancel.()

    assert {:ok, tuple_response} =
             ReqLLM.stream_object(
               {:openai, "gpt-4-0125-preview", temperature: 0.2},
               "Return a person",
               schema,
               opts
             )

    assert_receive {:stream_request_body, with_default}
    assert_body_delta(baseline, with_default, "temperature", 0.2)
    tuple_response.cancel.()
  end

  test "embedding tuple defaults change only the corresponding request key" do
    stub_json(EmbeddingHTTP, embedding_response())
    opts = openai_opts(EmbeddingHTTP)

    assert {:ok, _embedding} =
             ReqLLM.embed({:openai, id: "text-embedding-3-small"}, "Hello", opts)

    baseline = receive_body(EmbeddingHTTP)

    assert {:ok, _embedding} =
             ReqLLM.embed(
               {:openai, "text-embedding-3-small", dimensions: 8},
               "Hello",
               opts
             )

    assert_body_delta(baseline, receive_body(EmbeddingHTTP), "dimensions", 8)
  end

  test "image tuple defaults change only the corresponding request key" do
    stub_json(ImageHTTP, image_response())
    opts = openai_opts(ImageHTTP)

    assert {:ok, _response} =
             ReqLLM.generate_image({:openai, id: "gpt-image-1.5"}, "A square", opts)

    baseline = receive_body(ImageHTTP)

    assert {:ok, _response} =
             ReqLLM.generate_image(
               {:openai, "gpt-image-1.5", size: "512x512"},
               "A square",
               opts
             )

    assert_body_delta(baseline, receive_body(ImageHTTP), "size", "512x512")
  end

  test "transcription tuple defaults change only the corresponding multipart field" do
    stub_json(TranscriptionHTTP, transcription_response())
    opts = openai_opts(TranscriptionHTTP)
    audio = {:binary, "audio-bytes", "audio/mpeg"}

    assert {:ok, _result} =
             ReqLLM.transcribe({:openai, id: "whisper-1"}, audio, opts)

    baseline = receive_body(TranscriptionHTTP)

    assert {:ok, _result} =
             ReqLLM.transcribe(
               {:openai, "whisper-1", language: "en"},
               audio,
               opts
             )

    assert_body_delta(baseline, receive_body(TranscriptionHTTP), "language", "en")
  end

  test "speech tuple defaults change only the corresponding request key" do
    stub_audio(SpeechHTTP)
    opts = openai_opts(SpeechHTTP)

    assert {:ok, _result} =
             ReqLLM.speak({:openai, id: "tts-1"}, "Hello", opts)

    baseline = receive_body(SpeechHTTP)

    assert {:ok, _result} =
             ReqLLM.speak(
               {:openai, "tts-1", voice: "coral"},
               "Hello",
               opts
             )

    assert_body_delta(baseline, receive_body(SpeechHTTP), "voice", "coral")
  end

  test "rerank tuple defaults change only the corresponding request key" do
    stub_json(RerankHTTP, rerank_response())

    opts = [
      query: "best document",
      documents: ["one", "two"],
      api_key: "test-key",
      req_http_options: [plug: {Req.Test, RerankHTTP}]
    ]

    assert {:ok, _response} =
             ReqLLM.rerank({:cohere, id: "rerank-v3.5"}, opts)

    baseline = receive_body(RerankHTTP)

    assert {:ok, _response} =
             ReqLLM.rerank({:cohere, "rerank-v3.5", top_n: 1}, opts)

    assert_body_delta(baseline, receive_body(RerankHTTP), "top_n", 1)
  end

  test "OCR tuple defaults change only the corresponding request key" do
    stub_json(OCRHTTP, ocr_response())

    opts = [
      provider_options: [
        access_token: "test-token",
        project_id: "test-project",
        region: "global"
      ],
      req_http_options: [plug: {Req.Test, OCRHTTP}]
    ]

    capture_io(:stderr, fn ->
      assert {:ok, _result} =
               ReqLLM.ocr(
                 {:google_vertex, id: "mistral-ocr-2505"},
                 "document",
                 opts
               )
    end)

    baseline = receive_body(OCRHTTP)

    capture_io(:stderr, fn ->
      assert {:ok, _result} =
               ReqLLM.ocr(
                 {:google_vertex, "mistral-ocr-2505", include_images: false},
                 "document",
                 opts
               )
    end)

    assert_body_delta(baseline, receive_body(OCRHTTP), "include_image_base64", false)
  end

  test "unsupported tuple defaults do not alter an applicable operation request" do
    stub_json(EmbeddingHTTP, embedding_response())
    opts = openai_opts(EmbeddingHTTP)

    assert {:ok, _embedding} =
             ReqLLM.embed({:openai, id: "text-embedding-3-small"}, "Hello", opts)

    baseline = receive_body(EmbeddingHTTP)

    warning =
      capture_io(:stderr, fn ->
        assert {:ok, _embedding} =
                 ReqLLM.embed(
                   {:openai, "text-embedding-3-small", temperature: 0.2},
                   "Hello",
                   opts
                 )
      end)

    assert warning =~ ":temperature is not accepted by this operation"
    assert receive_body(EmbeddingHTTP) == baseline
  end

  defp openai_opts(owner) do
    [api_key: "test-key", req_http_options: [plug: {Req.Test, owner}]]
  end

  defp stub_json(owner, response) do
    test_pid = self()

    Req.Test.stub(owner, fn conn ->
      send(test_pid, {:request_body, owner, conn.body_params})
      Req.Test.json(conn, response)
    end)
  end

  defp stub_audio(owner) do
    test_pid = self()

    Req.Test.stub(owner, fn conn ->
      send(test_pid, {:request_body, owner, conn.body_params})
      Plug.Conn.send_resp(conn, 200, "audio-bytes")
    end)
  end

  defp receive_body(owner) do
    assert_receive {:request_body, ^owner, body}
    body
  end

  defp assert_body_delta(baseline, with_default, key, value) do
    baseline = normalize_body(baseline)
    with_default = normalize_body(with_default)
    assert with_default == Map.put(baseline, key, value)
  end

  defp normalize_body(%{"file" => %Plug.Upload{} = upload} = body) do
    normalized_upload = upload |> Map.from_struct() |> Map.delete(:path)
    Map.put(body, "file", normalized_upload)
  end

  defp normalize_body(body), do: body

  defp chat_response do
    %{
      "id" => "chat-1",
      "model" => "gpt-4-0125-preview",
      "choices" => [
        %{"message" => %{"role" => "assistant", "content" => "Hello"}, "finish_reason" => "stop"}
      ],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
    }
  end

  defp object_response do
    %{
      "id" => "object-1",
      "model" => "gpt-4-0125-preview",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "tool_calls" => [
              %{
                "id" => "call-1",
                "type" => "function",
                "function" => %{
                  "name" => "structured_output",
                  "arguments" => "{\"name\":\"Ada\"}"
                }
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
    }
  end

  defp embedding_response do
    %{
      "data" => [%{"embedding" => [0.1, 0.2], "index" => 0, "object" => "embedding"}],
      "model" => "text-embedding-3-small",
      "object" => "list",
      "usage" => %{"prompt_tokens" => 1, "total_tokens" => 1}
    }
  end

  defp image_response do
    %{"created" => 1, "data" => [%{"b64_json" => Base.encode64("image-bytes")}]}
  end

  defp transcription_response do
    %{"text" => "Hello", "segments" => [], "language" => "en", "duration" => 1.0}
  end

  defp rerank_response do
    %{
      "id" => "rerank-1",
      "results" => [%{"index" => 0, "relevance_score" => 0.9}],
      "meta" => %{"billed_units" => %{"search_units" => 1}}
    }
  end

  defp ocr_response do
    %{"pages" => [%{"index" => 0, "markdown" => "Hello", "images" => []}]}
  end
end

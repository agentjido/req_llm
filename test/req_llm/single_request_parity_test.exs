defmodule ReqLLM.SingleRequestParityTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Response

  @moduletag contract: :public_api

  @kinds [:single_embedding, :batch_embedding, :image, :speech, :transcription, :evaluation]
  @audio <<0, 255, 1, 254>>
  @usage %{input_tokens: 7, output_tokens: 0, total_tokens: 7}

  defmodule Provider do
    use ReqLLM.Provider,
      id: :typesafe,
      default_base_url: "https://single-request.example"

    @provider_schema [
      owner: [type: :any],
      preparation_error: [type: :any],
      preparation_delay: [type: :non_neg_integer],
      dimensions: [type: :pos_integer],
      prepared_dimensions: [type: :pos_integer]
    ]

    @impl ReqLLM.Provider
    def prepare_request(operation, model, input, opts) do
      controls = Keyword.get(opts, :provider_options, [])
      send(controls[:owner], {:prepared, operation, model, input, opts})
      Process.sleep(Keyword.get(controls, :preparation_delay, 0))

      case Keyword.fetch(controls, :preparation_error) do
        {:ok, error} ->
          {:error, error}

        :error ->
          request =
            Req.new(
              [url: "https://single-request.example/#{operation}", retry: false] ++
                Keyword.get(opts, :req_http_options, [])
            )
            |> Req.Request.register_options([:operation, :dimensions, :provider_options])
            |> Req.Request.merge_options(
              operation: operation,
              dimensions: opts[:dimensions],
              provider_options: [
                dimensions: Keyword.get(controls, :prepared_dimensions, controls[:dimensions])
              ]
            )
            |> attach_embedding_usage(model, operation)
            |> ReqLLM.Step.Telemetry.attach(model, Keyword.put(opts, :operation, operation))

          send(controls[:owner], {:preparation_finished_at, System.monotonic_time()})
          {:ok, request}
      end
    end

    @impl ReqLLM.Provider
    def extract_usage(_body, _model), do: {:ok, %{input: 7, output: 0, total_tokens: 7}}

    defp attach_embedding_usage(request, model, :embedding),
      do: ReqLLM.Step.Usage.attach(request, model)

    defp attach_embedding_usage(request, _model, _operation), do: request
  end

  setup_all do
    assert {:ok, original_provider} = ReqLLM.provider(:typesafe)
    assert {:ok, :typesafe} = ReqLLM.Providers.register(Provider)
    on_exit(fn -> ReqLLM.Providers.register(original_provider) end)
    :ok
  end

  setup do
    owner = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      handler_id,
      Enum.map([:start, :stop, :exception], &[:req_llm, :request, &1]),
      fn event, measurements, metadata, _ ->
        if metadata.model.id == "single-request-parity" do
          send(owner, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  for kind <- @kinds do
    @kind kind

    test "#{kind} preserves its result and correlated Req telemetry" do
      response = success_response(@kind)
      assert call(@kind, request_options(response)) == {:ok, expected_result(@kind)}
      assert_receive {:prepared, operation, %LLMDB.Model{id: "single-request-parity"}, _, _}
      assert operation == operation(@kind)
      assert_receive :sent
      refute_received :sent
      refute_received {:prepared, _, _, _, _}

      assert_receive {:telemetry, [:req_llm, :request, :start], start_measurements, start_meta}
      assert_receive {:telemetry, [:req_llm, :request, :stop], stop_measurements, stop_meta}
      assert start_measurements.system_time > 0
      assert stop_measurements.duration >= 0
      assert start_meta.operation == operation
      assert start_meta.provider == :typesafe
      assert start_meta.transport == :req
      assert start_meta.server.path == "/#{operation}"
      assert stop_meta.request_id == start_meta.request_id
      assert stop_meta.operation == operation
      assert stop_meta.http_status == 200
      refute Map.has_key?(start_meta, :request_payload)
      refute Map.has_key?(stop_meta, :response_payload)
      refute_received {:telemetry, [:req_llm, :request, :exception], _, _}
    end

    test "#{kind} returns the provider preparation error without sending" do
      error = ReqLLM.Error.Invalid.Parameter.exception(parameter: "preparation rejected")

      opts =
        request_options(success_response(@kind), preparation_error: error)
        |> Keyword.put(:req_http_options, adapter: fn _ -> flunk("unexpected send") end)

      assert call(@kind, opts) == {:error, error}
      assert_receive {:prepared, _, _, _, _}
      refute_received {:telemetry, _, _, _}
    end

    test "#{kind} retains its HTTP error type, status, body and text" do
      body = %{"error" => %{"message" => "invalid input"}}
      wire_body = if @kind == :speech, do: Jason.encode!(body), else: body
      response = Req.Response.new(status: 422, body: wire_body)

      assert {:error, %ReqLLM.Error.API.Request{} = error} =
               call(@kind, request_options(response))

      assert error.reason == http_error_reason(@kind)
      assert error.status == 422
      assert error.response_body == body
      assert error.request_body == nil

      assert Exception.message(error) ==
               "API request failed (422): #{http_error_reason(@kind)}"

      assert_receive {:telemetry, [:req_llm, :request, :stop], _, %{http_status: 422}}
      refute_received {:telemetry, [:req_llm, :request, :exception], _, _}
    end

    test "#{kind} passes transport errors through unchanged" do
      owner = self()
      error = %Req.TransportError{reason: :closed}

      opts =
        request_options(success_response(@kind))
        |> Keyword.put(:req_http_options,
          adapter: fn request ->
            send(owner, :sent)
            {request, error}
          end
        )

      assert call(@kind, opts) == {:error, error}
      assert_receive :sent
      refute_received :sent
      assert_receive {:telemetry, [:req_llm, :request, :exception], _, _}
    end

    test "#{kind} enforces the total timeout during transport" do
      opts =
        request_options(success_response(@kind))
        |> Keyword.put(:total_timeout, 20)
        |> Keyword.put(:req_http_options,
          adapter: fn request ->
            Process.sleep(200)
            {request, success_response(@kind)}
          end
        )

      assert {:error, %ReqLLM.Error.API.Timeout{kind: :total, timeout: 20}} = call(@kind, opts)
      assert_receive {:telemetry, [:req_llm, :request, :exception], _, metadata}
      assert metadata.operation == operation(@kind)
      assert metadata.transport == :req
      refute_received {:telemetry, [:req_llm, :request, :stop], _, _}
    end

    test "#{kind} preserves when its deadline starts relative to preparation" do
      opts =
        request_options(success_response(@kind), preparation_delay: 50)
        |> Keyword.put(:total_timeout, 15)

      if @kind == :evaluation do
        assert call(@kind, opts) == {:ok, expected_result(@kind)}
        assert_receive :sent
      else
        assert {:error, %ReqLLM.Error.API.Timeout{kind: :total, timeout: 15}} = call(@kind, opts)
        refute_received :sent
      end
    end
  end

  for kind <- [:single_embedding, :batch_embedding] do
    @kind kind

    test "#{kind} retains return_usage and takes dimensions from the prepared request" do
      opts =
        request_options(success_response(@kind), dimensions: 3, prepared_dimensions: 2)
        |> Keyword.merge(return_usage: true, dimensions: 4)

      assert {:ok,
              %{
                embedding: embedding,
                usage: %{input_tokens: 7, output_tokens: 0, total_tokens: 7}
              }} = call(@kind, opts)

      assert embedding == expected_result(@kind)
      assert_receive {:prepared, :embedding, _, _, provider_opts}
      refute Keyword.has_key?(provider_opts, :return_usage)
      assert provider_opts[:dimensions] == 4
      assert provider_opts[:provider_options][:dimensions] == 3
    end

    test "#{kind} rejects dimensions using the prepared request rather than input options" do
      opts =
        request_options(success_response(@kind), dimensions: 2, prepared_dimensions: 3)
        |> Keyword.put(:dimensions, 4)

      assert {:error,
              %ReqLLM.Error.API.Response{
                reason: "Embedding dimension mismatch: expected 3, got 2",
                response_body: %{actual_dimensions: 2, expected_dimensions: 3}
              }} = call(@kind, opts)
    end
  end

  for kind <- [:speech, :transcription] do
    @kind kind

    test "detailed #{kind} preserves its result, post-preparation usage step and timing" do
      opts = request_options(success_response(@kind), preparation_delay: 25)

      result =
        case @kind do
          :speech ->
            ReqLLM.speak_detailed(model(), "private text", opts)

          :transcription ->
            ReqLLM.transcribe_detailed(model(), {:binary, @audio, "audio/wav"}, opts)
        end

      finished_at = System.monotonic_time()
      assert_receive {:preparation_finished_at, preparation_finished_at}

      post_preparation_ms =
        System.convert_time_unit(finished_at - preparation_finished_at, :native, :microsecond) /
          1_000

      assert {:ok, detailed} = result
      assert detailed.result == expected_result(@kind)
      assert detailed.call_metadata.model == "single-request-parity"
      assert detailed.call_metadata.provider == :typesafe
      assert detailed.call_metadata.usage.input_tokens == 7
      assert detailed.call_metadata.usage.total_tokens == 7
      assert detailed.call_metadata.timings.request_ms > 0
      assert detailed.call_metadata.timings.request_ms <= post_preparation_ms
      assert_receive :sent
      refute_received :sent
      assert_receive {:telemetry, [:req_llm, :request, :stop], _, metadata}
      assert metadata.usage.tokens.input_tokens == 7
    end
  end

  test "transcription resolves audio and prepends its media type before provider preparation" do
    opts =
      request_options(success_response(:transcription))
      |> Keyword.put(:media_type, "ignored/type")

    assert {:ok, %ReqLLM.Transcription.Result{text: "transcribed"}} =
             ReqLLM.transcribe(model(), {:base64, Base.encode64(@audio), "audio/wav"}, opts)

    assert_receive {:prepared, :transcription, _, @audio, provider_opts}
    assert Keyword.get_values(provider_opts, :media_type) == ["audio/wav", "ignored/type"]

    assert {:error, %ReqLLM.Error.Invalid.Parameter{parameter: "audio: invalid base64 encoding"}} =
             ReqLLM.transcribe(model(), {:base64, "!!!", "audio/wav"}, opts)

    refute_received {:prepared, _, _, _, _}
  end

  test "transcription preserves response parsing errors" do
    assert {:error,
            %ReqLLM.Error.API.Response{
              reason: "Unexpected transcription response format",
              response_body: [:invalid]
            }} =
             call(
               :transcription,
               request_options(Req.Response.new(status: 200, body: [:invalid]))
             )
  end

  test "image stream validation happens before provider preparation" do
    assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
             call(:image, Keyword.put(request_options(success_response(:image)), :stream, true))

    refute_received {:prepared, _, _, _, _}
  end

  defp model do
    %{
      provider: :typesafe,
      id: "single-request-parity",
      capabilities: %{embeddings: true, evaluate: true},
      execution: %{
        evaluate: %{
          supported: true,
          family: "typesafe_systemone",
          wire_protocol: "typesafe_systemone",
          path: "/v1/systemone",
          provider_model_id: "single-request-parity"
        }
      }
    }
  end

  defp call(:single_embedding, opts), do: ReqLLM.embed(model(), "private text", opts)
  defp call(:batch_embedding, opts), do: ReqLLM.embed(model(), ["first", "second"], opts)
  defp call(:image, opts), do: ReqLLM.generate_image(model(), "private prompt", opts)
  defp call(:speech, opts), do: ReqLLM.speak(model(), "private text", opts)

  defp call(:transcription, opts),
    do: ReqLLM.transcribe(model(), {:binary, @audio, "audio/wav"}, opts)

  defp call(:evaluation, opts),
    do: ReqLLM.evaluate(model(), "private state", %{accepted: %{type: :boolean}}, opts)

  defp operation(kind) when kind in [:single_embedding, :batch_embedding], do: :embedding
  defp operation(:evaluation), do: :evaluate
  defp operation(kind), do: kind

  defp request_options(response, controls \\ []) do
    owner = self()

    [
      provider_options: Keyword.put(controls, :owner, owner),
      req_http_options: [
        adapter: fn request ->
          send(owner, :sent)
          {request, response}
        end
      ]
    ]
  end

  defp success_response(:single_embedding) do
    Req.Response.new(
      status: 200,
      body: %{"data" => [%{"index" => 0, "embedding" => [0.1, 0.2]}]},
      private: %{req_llm: %{usage: @usage}}
    )
  end

  defp success_response(:batch_embedding) do
    Req.Response.new(
      status: 200,
      body: %{
        "data" => [
          %{"index" => 1, "embedding" => [0.3, 0.4]},
          %{"index" => 0, "embedding" => [0.1, 0.2]}
        ]
      },
      private: %{req_llm: %{usage: @usage}}
    )
  end

  defp success_response(:speech), do: Req.Response.new(status: 200, body: @audio)

  defp success_response(:transcription) do
    Req.Response.new(status: 200, body: %{"text" => "transcribed", "language" => "english"})
  end

  defp success_response(kind), do: Req.Response.new(status: 200, body: expected_result(kind))

  defp expected_result(:single_embedding), do: [0.1, 0.2]
  defp expected_result(:batch_embedding), do: [[0.1, 0.2], [0.3, 0.4]]

  defp expected_result(:image),
    do: %Response{
      id: "image-result",
      context: ReqLLM.Context.new(),
      model: "image-model",
      provider_meta: %{images: ["kept"]}
    }

  defp expected_result(:speech), do: %ReqLLM.Speech.Result{audio: @audio}

  defp expected_result(:transcription),
    do: %ReqLLM.Transcription.Result{text: "transcribed", language: "en"}

  defp expected_result(:evaluation),
    do: %Response{
      id: "evaluation-result",
      model: "evaluation-model",
      context: ReqLLM.Context.new(),
      object: %{"accepted" => %{"probability" => 0.9}}
    }

  defp http_error_reason(kind) when kind in [:single_embedding, :batch_embedding, :image],
    do: "HTTP 422: Request failed"

  defp http_error_reason(:speech), do: "HTTP 422: Speech generation failed"
  defp http_error_reason(:transcription), do: "HTTP 422: Transcription request failed"
  defp http_error_reason(:evaluation), do: "Evaluation request failed"
end

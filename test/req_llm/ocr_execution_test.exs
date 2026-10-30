defmodule ReqLLM.OCRExecutionTest do
  use ExUnit.Case, async: false

  @moduletag contract: :public_api

  defmodule PreparationProvider do
    use ReqLLM.Provider,
      id: :google_vertex,
      default_base_url: "https://ocr.example"

    @impl true
    def prepare_request(:ocr, _model, "rejected", _opts) do
      {:error, {:ocr_provider_rejected, :invalid_document}}
    end

    def prepare_request(:ocr, _model, "expired", opts) do
      test_pid = self()

      receive do
        :finish_preparation -> :ok
      after
        opts[:total_timeout] + 20 -> :ok
      end

      {:ok,
       Req.new(
         url: "https://ocr.example",
         plug: fn conn ->
           send(test_pid, :unexpected_ocr_request)
           Plug.Conn.send_resp(conn, 200, ~s({"pages":[]}))
         end
       )}
    end
  end

  setup do
    model = %{provider: :google_vertex, id: "mistral-ocr-2505"}

    opts = [
      provider_options: [
        access_token: "test-token",
        project_id: "test-project",
        region: "us-central1"
      ],
      req_http_options: [plug: {Req.Test, __MODULE__}],
      max_retries: 0
    ]

    %{model: model, opts: opts}
  end

  for timeout <- [:infinity, 5_000] do
    @timeout timeout

    test "preserves success and lifecycle measurements with a #{@timeout} budget", %{
      model: model,
      opts: opts
    } do
      attach_telemetry()
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:ocr_request, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          201,
          ~s({"pages":[{"index":1,"markdown":"Second"},{"index":0,"markdown":"First"}]})
        )
      end)

      assert {:ok,
              %{
                markdown: "First\n\n---\n\nSecond",
                pages: [
                  %{index: 1, markdown: "Second", images: []},
                  %{index: 0, markdown: "First", images: []}
                ]
              }} = ReqLLM.ocr(model, "document", Keyword.put(opts, :total_timeout, @timeout))

      assert_receive {:ocr_request,
                      %{
                        "document" => %{
                          "type" => "document_url",
                          "document_url" => "data:application/pdf;base64,ZG9jdW1lbnQ="
                        },
                        "include_image_base64" => true,
                        "model" => "mistral-ocr-2505"
                      }}

      assert_receive {:ocr_event, [:req_llm, :request, :start], start_measurements, start_meta}
      assert_receive {:ocr_event, [:req_llm, :request, :stop], stop_measurements, stop_meta}
      assert %{system_time: system_time} = start_measurements
      assert is_integer(system_time)
      assert Enum.sort(Map.keys(start_measurements)) == [:system_time]
      assert %{duration: duration, system_time: stop_time} = stop_measurements
      assert is_integer(duration) and duration >= 0
      assert is_integer(stop_time)
      assert Enum.sort(Map.keys(stop_measurements)) == [:duration, :system_time]
      assert start_meta.operation == :ocr
      assert start_meta.mode == :sync
      assert start_meta.provider == :google_vertex
      assert start_meta.transport == :req
      assert start_meta.model.id == "mistral-ocr-2505"
      assert start_meta.request_summary.document_bytes == 8
      assert stop_meta.request_id == start_meta.request_id
      assert stop_meta.http_status == 201
      assert stop_meta.response_summary == %{image_count: 0, page_count: 2, text_bytes: 11}
      refute_received {:ocr_event, [:req_llm, :request, :exception], _, _}
      refute_received {:ocr_request, _}
    end
  end

  test "preserves timeout errors and correlated exception telemetry", %{model: model, opts: opts} do
    attach_telemetry()
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :ocr_request_started)

      receive do
        :finish_request -> Plug.Conn.send_resp(conn, 200, ~s({"pages":[]}))
      end
    end)

    assert {:error, %ReqLLM.Error.API.Timeout{kind: :total, timeout: 20} = error} =
             ReqLLM.ocr(model, "document", Keyword.put(opts, :total_timeout, 20))

    assert Exception.message(error) == "Model call exceeded the total timeout of 20ms"
    assert_receive :ocr_request_started
    assert_receive {:ocr_event, [:req_llm, :request, :start], _, start_meta}
    assert_receive {:ocr_event, [:req_llm, :request, :exception], measurements, exception_meta}
    assert %{duration: duration, system_time: system_time} = measurements
    assert is_integer(duration) and duration >= 0
    assert is_integer(system_time)
    assert exception_meta.request_id == start_meta.request_id
    assert exception_meta.operation == :ocr
    assert exception_meta.provider == :google_vertex
    assert exception_meta.transport == :req
    refute_received {:ocr_event, [:req_llm, :request, :stop], _, _}
  end

  test "keeps exact unsupported-model errors before request preparation" do
    assert {:error, %ReqLLM.Error.Invalid.Parameter{} = error} =
             ReqLLM.ocr("google_vertex:gemini-2.5-flash", "document")

    assert error.parameter ==
             "model: google_vertex:gemini-2.5-flash does not support OCR operations"
  end

  test "validates the timeout before resolving an invalid model" do
    error =
      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        ReqLLM.ocr("invalid:model", "document", total_timeout: 0)
      end

    assert error.parameter == "total_timeout must be a positive integer or :infinity, got: 0"
  end

  describe "provider preparation" do
    setup do
      {:ok, original_provider} = ReqLLM.provider(:google_vertex)
      on_exit(fn -> ReqLLM.Providers.register!(original_provider) end)
      ReqLLM.Providers.register!(PreparationProvider)
      :ok
    end

    test "passes provider preparation errors through unchanged", %{model: model} do
      assert {:error, {:ocr_provider_rejected, :invalid_document}} =
               ReqLLM.ocr(model, "rejected", total_timeout: :infinity)
    end

    test "keeps preparation inside the original total timeout budget", %{model: model} do
      assert {:error, %ReqLLM.Error.API.Timeout{kind: :total, timeout: 10}} =
               ReqLLM.ocr(model, "expired", total_timeout: 10)

      refute_received :unexpected_ocr_request
    end
  end

  defp attach_telemetry do
    test_pid = self()
    handler_id = "ocr-execution-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:req_llm, :request, :start],
          [:req_llm, :request, :stop],
          [:req_llm, :request, :exception]
        ],
        fn event, measurements, metadata, _config ->
          if metadata.operation == :ocr do
            send(test_pid, {:ocr_event, event, measurements, metadata})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end

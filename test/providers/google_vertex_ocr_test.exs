defmodule ReqLLM.Providers.GoogleVertex.OCRTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.GoogleVertex

  @model_spec %{provider: :google_vertex, id: "mistral-ocr-2505"}

  @base_opts [
    access_token: "test-token",
    project_id: "test-project",
    region: "us-central1"
  ]

  describe "prepare_request(:ocr, ...)" do
    test "builds correct rawPredict endpoint URL" do
      {:ok, request} = GoogleVertex.prepare_request(:ocr, @model_spec, "Hello world", @base_opts)

      url = URI.to_string(request.url)

      assert url =~
               "us-central1-aiplatform.googleapis.com/v1/projects/test-project/locations/us-central1/publishers/mistralai/models/mistral-ocr-2505:rawPredict"
    end

    test "formats OCR body for Mistral OCR" do
      {:ok, request} = GoogleVertex.prepare_request(:ocr, @model_spec, "Hello world", @base_opts)

      body = request.options[:json]

      assert body.model == "mistral-ocr-2505"
      assert body.document.type == "document_url"
      assert body.document.document_url =~ "data:application/pdf;base64,"
      assert body.include_image_base64 == true
    end

    test "attaches fixture step when fixture is provided" do
      {:ok, request} =
        GoogleVertex.prepare_request(
          :ocr,
          @model_spec,
          "Hello world",
          @base_opts ++ [fixture: "ocr-basic"]
        )

      assert :llm_fixture in Keyword.keys(request.request_steps)
    end

    test "attaches correlated OCR telemetry and usage steps without retaining document content" do
      document = "private-document-content"
      transport_secret = "private-transport-secret"

      {:ok, request} =
        GoogleVertex.prepare_request(
          :ocr,
          @model_spec,
          document,
          @base_opts ++
            [
              pages: [2, 4],
              document_type: "image/png",
              telemetry: [payloads: :raw],
              req_http_options: [headers: [{"x-api-key", transport_secret}]]
            ]
        )

      assert Req.Request.get_header(request, "x-api-key") == [transport_secret]
      assert :llm_telemetry_start in Keyword.keys(request.request_steps)
      assert :ocr_classify_failure in Keyword.keys(request.response_steps)
      assert :llm_usage in Keyword.keys(request.response_steps)
      assert :llm_telemetry_stop in Keyword.keys(request.response_steps)
      assert :llm_telemetry_exception in Keyword.keys(request.error_steps)

      context = ReqLLM.Telemetry.request_context(request)

      assert context.operation == :ocr

      assert context.request_summary == %{
               document_bytes: byte_size(document),
               document_type: "image/png",
               include_images: true,
               page_count: 2
             }

      assert context.request_payload == context.request_summary
      refute Keyword.has_key?(context.original_opts, :req_http_options)

      refute inspect(context) =~ document
      refute inspect(context) =~ transport_secret
      refute inspect(context) =~ "test-token"
      refute inspect(context) =~ "test-project"
    end

    test "rejects non-OCR models" do
      assert {:error, error} =
               GoogleVertex.prepare_request(
                 :ocr,
                 "google_vertex:gemini-2.5-flash",
                 "Hello world",
                 @base_opts
               )

      assert Exception.message(error) =~ "does not support OCR operations"
    end
  end
end

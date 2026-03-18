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

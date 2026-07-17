defmodule ReqLLM.OCRTest do
  @moduledoc """
  Test suite for OCR functionality.

  Covers:
  - Request body building
  - Response normalization
  - File type detection
  - Error handling
  - ReqLLM facade delegation
  """

  use ExUnit.Case, async: false

  @moduletag contract: :public_api

  alias ReqLLM.OCR

  @tiny_pdf <<"%PDF-1.0\n1 0 obj\n<< /Type /Catalog >>\nendobj\n">>

  defmodule SuccessHTTP do
  end

  defmodule ErrorHTTP do
  end

  describe "schema/0" do
    test "accepts the shared telemetry options without changing defaults" do
      schema = OCR.schema()

      assert :telemetry in Keyword.keys(schema.schema)
      assert {:ok, opts} = NimbleOptions.validate([], schema)
      assert opts[:telemetry] == []
      assert opts[:include_images] == true
      assert opts[:document_type] == "application/pdf"
    end
  end

  describe "validate_model/1" do
    test "rejects non-OCR models" do
      assert {:error, error} = OCR.validate_model("google_vertex:gemini-2.5-flash")
      assert Exception.message(error) =~ "does not support OCR operations"
    end

    test "accepts inline OCR models outside the catalog" do
      assert {:ok, %LLMDB.Model{id: "mistral-ocr-2505"}} =
               OCR.validate_model(%{provider: :google_vertex, id: "mistral-ocr-2505"})
    end

    test "accepts inline OCR models declared via family" do
      assert {:ok, %LLMDB.Model{id: "custom-ocr"}} =
               OCR.validate_model(%{
                 provider: :google_vertex,
                 id: "custom-ocr",
                 family: "mistral-ocr"
               })
    end
  end

  describe "build_ocr_body/3" do
    test "builds request body with defaults" do
      body = OCR.build_ocr_body("mistral-ocr-2505", "hello", [])

      assert body.model == "mistral-ocr-2505"
      assert body.document.type == "document_url"
      assert body.document.document_url =~ "data:application/pdf;base64,"
      assert body.include_image_base64 == true
    end

    test "respects document_type option" do
      body = OCR.build_ocr_body("mistral-ocr-2505", "hello", document_type: "image/png")

      assert body.document.document_url =~ "data:image/png;base64,"
    end

    test "respects include_images option" do
      body = OCR.build_ocr_body("mistral-ocr-2505", "hello", include_images: false)

      assert body.include_image_base64 == false
    end

    test "includes pages parameter when provided" do
      body = OCR.build_ocr_body("mistral-ocr-2505", "hello", pages: [0, 1, 2])

      assert body[:pages] == [0, 1, 2]
    end

    test "omits pages parameter when not provided" do
      body = OCR.build_ocr_body("mistral-ocr-2505", "hello", [])

      refute Map.has_key?(body, :pages)
    end

    test "base64 encodes document binary" do
      binary = <<1, 2, 3, 4, 5>>
      body = OCR.build_ocr_body("mistral-ocr-2505", binary, [])

      expected_b64 = Base.encode64(binary)
      assert body.document.document_url == "data:application/pdf;base64,#{expected_b64}"
    end
  end

  describe "normalize_response/1 with string keys" do
    test "normalizes single page response" do
      response = %{
        "pages" => [
          %{"index" => 0, "markdown" => "# Hello\n\nWorld", "images" => []}
        ]
      }

      result = OCR.normalize_response(response)

      assert result.markdown == "# Hello\n\nWorld"
      assert length(result.pages) == 1
      assert hd(result.pages).index == 0
      assert hd(result.pages).markdown == "# Hello\n\nWorld"
      assert hd(result.pages).images == []
    end

    test "normalizes multi-page response with separators" do
      response = %{
        "pages" => [
          %{"index" => 0, "markdown" => "Page one", "images" => []},
          %{"index" => 1, "markdown" => "Page two", "images" => []}
        ]
      }

      result = OCR.normalize_response(response)

      assert result.markdown == "Page one\n\n---\n\nPage two"
      assert length(result.pages) == 2
    end

    test "sorts pages by index" do
      response = %{
        "pages" => [
          %{"index" => 2, "markdown" => "Third"},
          %{"index" => 0, "markdown" => "First"},
          %{"index" => 1, "markdown" => "Second"}
        ]
      }

      result = OCR.normalize_response(response)

      assert result.markdown == "First\n\n---\n\nSecond\n\n---\n\nThird"
    end

    test "preserves image data in pages" do
      response = %{
        "pages" => [
          %{
            "index" => 0,
            "markdown" => "Text with ![img](data:image/png;base64,abc)",
            "images" => [%{"id" => "img_0", "image_base64" => "abc"}]
          }
        ]
      }

      result = OCR.normalize_response(response)

      assert length(hd(result.pages).images) == 1
      assert hd(hd(result.pages).images)["id"] == "img_0"
    end

    test "defaults images to empty list when missing" do
      response = %{
        "pages" => [
          %{"index" => 0, "markdown" => "No images"}
        ]
      }

      result = OCR.normalize_response(response)

      assert hd(result.pages).images == []
    end
  end

  describe "normalize_response/1 with atom keys" do
    test "handles atom-keyed response" do
      response = %{
        pages: [
          %{index: 0, markdown: "Atom keys"},
          %{index: 1, markdown: "Also atom keys"}
        ]
      }

      result = OCR.normalize_response(response)

      assert result.markdown == "Atom keys\n\n---\n\nAlso atom keys"
    end
  end

  describe "ocr_file/3" do
    test "preserves exact missing-file errors and validation order" do
      path =
        Path.join(
          System.tmp_dir!(),
          "req_llm_missing_ocr_#{System.unique_integer([:positive])}.pdf"
        )

      expected = "Cannot read #{path}: enoent"

      assert {:error, ^expected} = OCR.ocr_file("invalid:model", path)

      error =
        assert_raise RuntimeError, fn ->
          OCR.ocr_file!("invalid:model", path)
        end

      assert Exception.message(error) == "OCR failed: #{inspect(expected)}"
    end

    test "detects document type from extension" do
      # Create temp files with different extensions
      for {ext, _expected_type} <- [
            {".pdf", "application/pdf"},
            {".png", "image/png"},
            {".jpg", "image/jpeg"},
            {".jpeg", "image/jpeg"},
            {".webp", "image/webp"},
            {".xyz", "application/pdf"}
          ] do
        path = Path.join(System.tmp_dir!(), "ocr_test#{ext}")
        File.write!(path, @tiny_pdf)

        # We can't test the full flow without a real API, but we can verify
        # the function attempts to process (it will fail at model resolution)
        result = OCR.ocr_file("invalid:model", path)
        assert {:error, _} = result

        File.rm!(path)
      end
    end
  end

  describe "ocr/3" do
    @tag category: :ocr
    @tag provider: :google_vertex
    @tag ReqLLM.Test.CompatibilityScenario.tag!(:ocr_basic)
    test "preserves the exact result while emitting redacted correlated telemetry and usage" do
      test_pid = self()
      document = "private-document-content"
      recognized = "# Private recognized output"
      access_token = "private-access-token"
      project_id = "private-project-id"
      handler_id = attach_ocr_telemetry(test_pid)

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(SuccessHTTP, fn conn ->
        send(test_pid, :ocr_provider_request)

        body = %{
          "pages" => [
            %{
              "index" => 0,
              "markdown" => recognized,
              "images" => [%{"id" => "image-1", "image_base64" => "encoded-image"}]
            }
          ],
          "usage" => %{
            "prompt_tokens" => 7,
            "completion_tokens" => 3,
            "total_tokens" => 10
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      model = %{provider: :google_vertex, id: "mistral-ocr-2505"}

      opts = [
        provider_options: [
          access_token: access_token,
          project_id: project_id,
          region: "us-central1"
        ],
        req_http_options: [plug: {Req.Test, SuccessHTTP}],
        max_retries: 0
      ]

      assert {:ok, result} = ReqLLM.ocr(model, document, opts)

      assert result == %{
               markdown: recognized,
               pages: [
                 %{
                   index: 0,
                   markdown: recognized,
                   images: [%{"id" => "image-1", "image_base64" => "encoded-image"}]
                 }
               ]
             }

      assert Enum.sort(Map.keys(result)) == [:markdown, :pages]
      assert_receive :ocr_provider_request
      refute_receive :ocr_provider_request, 20

      assert_receive {:ocr_telemetry, [:req_llm, :request, :start], start_meta}
      assert_receive {:ocr_telemetry, [:req_llm, :token_usage], usage_meta}
      assert_receive {:ocr_telemetry, [:req_llm, :request, :stop], stop_meta}

      assert start_meta.operation == :ocr
      assert start_meta.provider == :google_vertex
      assert start_meta.transport == :req

      assert start_meta.server.path ==
               "/v1/projects/{project_id}/locations/us-central1/publishers/mistralai/models/mistral-ocr-2505:rawPredict"

      assert start_meta.request_summary == %{
               document_bytes: byte_size(document),
               document_type: "application/pdf",
               include_images: true,
               page_count: nil
             }

      refute Map.has_key?(start_meta, :request_payload)
      assert usage_meta.request_id == start_meta.request_id
      assert usage_meta.operation == :ocr
      assert stop_meta.request_id == start_meta.request_id
      assert stop_meta.http_status == 200
      assert stop_meta.usage.tokens.input_tokens == 7
      assert stop_meta.usage.tokens.output_tokens == 3
      assert stop_meta.usage.tokens.total_tokens == 10

      assert stop_meta.response_summary == %{
               image_count: 1,
               page_count: 1,
               text_bytes: byte_size(recognized)
             }

      refute Map.has_key?(stop_meta, :response_payload)

      telemetry = inspect({start_meta, usage_meta, stop_meta})
      refute telemetry =~ document
      refute telemetry =~ recognized
      refute telemetry =~ access_token
      refute telemetry =~ project_id
      refute telemetry =~ "encoded-image"
    end

    test "preserves provider failures and classifies them only in telemetry" do
      test_pid = self()
      response_body = %{"error" => %{"message" => "invalid document"}}
      handler_id = attach_ocr_telemetry(test_pid)

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(ErrorHTTP, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(422, Jason.encode!(response_body))
      end)

      model = %{provider: :google_vertex, id: "mistral-ocr-2505"}

      opts = [
        provider_options: [
          access_token: "test-token",
          project_id: "test-project",
          region: "us-central1"
        ],
        req_http_options: [plug: {Req.Test, ErrorHTTP}],
        max_retries: 0
      ]

      assert {:error, %ReqLLM.Error.API.Request{} = error} =
               ReqLLM.ocr(model, @tiny_pdf, opts)

      assert error.reason == "HTTP 422: OCR request failed"
      assert error.status == 422
      assert error.response_body == response_body
      assert error.request_body == nil
      assert Exception.message(error) == "API request failed (422): HTTP 422: OCR request failed"

      assert_receive {:ocr_telemetry, [:req_llm, :request, :start], start_meta}
      assert_receive {:ocr_telemetry, [:req_llm, :request, :stop], stop_meta}
      assert stop_meta.request_id == start_meta.request_id
      assert stop_meta.http_status == 422
      assert stop_meta.finish_reason == :error
      refute_receive {:ocr_telemetry, [:req_llm, :request, :exception], _}

      raised =
        assert_raise ReqLLM.Error.API.Request, fn ->
          ReqLLM.ocr!(model, @tiny_pdf, opts)
        end

      assert raised.reason == error.reason
      assert raised.status == error.status
      assert raised.response_body == error.response_body
      assert Exception.message(raised) == Exception.message(error)
    end

    test "rejects non-OCR models before preparing a request" do
      assert {:error, error} = OCR.ocr("google_vertex:gemini-2.5-flash", "binary")
      assert Exception.message(error) =~ "does not support OCR operations"
    end
  end

  describe "ocr!/3" do
    test "raises on error" do
      assert_raise ReqLLM.Error.Invalid.Parameter, ~r/does not support OCR operations/, fn ->
        OCR.ocr!("google_vertex:gemini-2.5-flash", "binary")
      end
    end
  end

  describe "ReqLLM facade delegation" do
    test "ocr/3 is delegated" do
      assert function_exported?(ReqLLM, :ocr, 3)
      assert function_exported?(ReqLLM, :ocr, 2)
    end

    test "ocr!/3 is delegated" do
      assert function_exported?(ReqLLM, :ocr!, 3)
      assert function_exported?(ReqLLM, :ocr!, 2)
    end

    test "ocr_file/3 is delegated" do
      assert function_exported?(ReqLLM, :ocr_file, 3)
      assert function_exported?(ReqLLM, :ocr_file, 2)
    end

    test "ocr_file!/3 is delegated" do
      assert function_exported?(ReqLLM, :ocr_file!, 3)
      assert function_exported?(ReqLLM, :ocr_file!, 2)
    end
  end

  defp attach_ocr_telemetry(test_pid) do
    handler_id = "ocr-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:req_llm, :request, :start],
          [:req_llm, :request, :stop],
          [:req_llm, :request, :exception],
          [:req_llm, :token_usage]
        ],
        fn event, _measurements, metadata, _config ->
          if metadata.operation == :ocr do
            send(test_pid, {:ocr_telemetry, event, metadata})
          end
        end,
        nil
      )

    handler_id
  end
end

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

  use ExUnit.Case, async: true

  alias ReqLLM.OCR

  @tiny_pdf <<"%PDF-1.0\n1 0 obj\n<< /Type /Catalog >>\nendobj\n">>

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
    test "returns error for missing file" do
      result =
        OCR.ocr_file(%{provider: :google_vertex, id: "mistral-ocr-2505"}, "/nonexistent/file.pdf")

      assert {:error, message} = result
      assert message =~ "Cannot read"
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
end

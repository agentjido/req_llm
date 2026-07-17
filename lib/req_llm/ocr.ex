defmodule ReqLLM.OCR do
  @moduledoc """
  Optical Character Recognition for ReqLLM.

  Extracts rich markdown from documents (PDF, images) using OCR models.
  Currently supports Mistral OCR on Google Vertex AI.

  ## Examples

      model = ReqLLM.model!(%{provider: :google_vertex, id: "mistral-ocr-2505"})

      # Process a PDF binary
      {:ok, result} = ReqLLM.ocr(model, pdf_binary,
        provider_options: [region: "europe-west4"]
      )
      result.markdown  #=> "# Title\\n\\nExtracted text with ![images](data:...)..."
      result.pages     #=> [%{index: 0, markdown: "...", images: [...]}]

      # Process a file
      {:ok, result} = ReqLLM.ocr_file(model, "doc.pdf",
        provider_options: [region: "europe-west4"]
      )

  ## Response

  Returns `{:ok, %{markdown: String.t(), pages: [map()]}}` where:
  - `markdown` — concatenated page markdowns with `---` separators
  - `pages` — list of `%{index: integer, markdown: String.t(), images: [map()]}`
  """

  alias LLMDB.Model

  @type ocr_result :: %{markdown: String.t(), pages: [map()]}

  @base_schema NimbleOptions.new!(
                 include_images: [
                   type: :boolean,
                   default: true,
                   doc: "Extract images as base64 data in the returned markdown"
                 ],
                 document_type: [
                   type: :string,
                   default: "application/pdf",
                   doc: "MIME type for the document binary"
                 ],
                 pages: [
                   type: {:list, :non_neg_integer},
                   doc: "Zero-based page indexes to process"
                 ],
                 provider_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "Provider-specific options (keyword list or map)",
                   default: []
                 ],
                 req_http_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "Req-specific options (keyword list or map)",
                   default: []
                 ],
                 telemetry: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "ReqLLM telemetry options (for example, [payloads: :raw])",
                   default: []
                 ],
                 total_timeout: [
                   type: {:or, [:pos_integer, {:in, [:infinity]}]},
                   doc: "Optional total model-call timeout in milliseconds, including retries"
                 ],
                 max_retries: [
                   type: :non_neg_integer,
                   default: 3,
                   doc:
                     "Maximum number of retry attempts for transient network errors. Set to 0 to disable retries."
                 ],
                 fixture: [
                   type: {:or, [:string, {:tuple, [:atom, :string]}]},
                   doc: "HTTP fixture for testing (provider inferred from model if string)"
                 ]
               )

  @doc """
  Returns the base OCR options schema.
  """
  @spec schema :: NimbleOptions.t()
  def schema, do: @base_schema

  @doc """
  Validates that a model supports OCR operations.
  """
  @spec validate_model(ReqLLM.model_input()) ::
          {:ok, Model.t()} | {:error, term()}
  def validate_model(model_spec) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, _provider_module} <- ReqLLM.provider(model.provider) do
      model_string = LLMDB.Model.spec(model)

      if ocr_capable_model?(model) do
        {:ok, model}
      else
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter: "model: #{model_string} does not support OCR operations"
         )}
      end
    end
  end

  @doc """
  Process a document binary through an OCR model.

  ## Parameters

    * `model_spec` — Model specification (e.g., `%{provider: :google_vertex, id: "mistral-ocr-2505"}`)
    * `document_binary` — Raw document bytes (PDF, PNG, JPEG, etc.)
    * `opts` — Options:
      - `:include_images` — extract images as base64 in markdown (default `true`)
      - `:document_type` — MIME type hint (default `"application/pdf"`)
      - `:pages` — zero-based page indexes to process
      - `:provider_options` — provider-specific options (e.g., `region`, `access_token`)
      - `:telemetry` — ReqLLM telemetry options (for example, `[payloads: :raw]`)
      - `:total_timeout` — optional whole-call deadline in milliseconds, including retries

  ## Examples

      pdf_bytes = File.read!("document.pdf")
      model = ReqLLM.model!(%{provider: :google_vertex, id: "mistral-ocr-2505"})
      {:ok, result} = ReqLLM.ocr(model, pdf_bytes)

  """
  @spec ocr(String.t() | struct(), binary(), keyword()) ::
          {:ok, ocr_result()} | {:error, term()}
  def ocr(model_spec, document_binary, opts \\ []) do
    opts = ReqLLM.ModelInput.merge_tuple_defaults(model_spec, :ocr, opts)
    deadline = ReqLLM.TimeoutBudget.deadline(opts)

    with {:ok, model} <- validate_model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, opts} <-
           ReqLLM.Provider.Options.normalize_namespaced_provider_options(
             provider_module,
             :ocr,
             model,
             opts
           ),
         {:ok, request} <-
           provider_module.prepare_request(:ocr, model, document_binary, opts),
         {:ok, %Req.Response{status: status, body: response}} when status in 200..299 <-
           ReqLLM.TimeoutBudget.request(request, deadline) do
      {:ok, normalize_response(response)}
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: OCR request failed",
           status: status,
           response_body: body
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Process a document binary through an OCR model. Raises on error.
  """
  @spec ocr!(String.t() | struct(), binary(), keyword()) :: ocr_result()
  def ocr!(model_spec, document_binary, opts \\ []) do
    case ocr(model_spec, document_binary, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Process a file at the given path through an OCR model.

  Reads the file, detects document type from extension, and delegates to `ocr/3`.

  ## Examples

      model = ReqLLM.model!(%{provider: :google_vertex, id: "mistral-ocr-2505"})
      {:ok, result} = ReqLLM.ocr_file(model, "report.pdf")

  """
  @spec ocr_file(String.t() | struct(), String.t(), keyword()) ::
          {:ok, ocr_result()} | {:error, term()}
  def ocr_file(model_spec, path, opts \\ []) do
    case File.read(path) do
      {:ok, binary} ->
        doc_type =
          case Path.extname(path) |> String.downcase() do
            ".pdf" -> "application/pdf"
            ".png" -> "image/png"
            ".jpg" -> "image/jpeg"
            ".jpeg" -> "image/jpeg"
            ".webp" -> "image/webp"
            _ -> "application/pdf"
          end

        ocr(model_spec, binary, Keyword.put_new(opts, :document_type, doc_type))

      {:error, reason} ->
        {:error, "Cannot read #{path}: #{reason}"}
    end
  end

  @doc """
  Process a file through an OCR model. Raises on error.
  """
  @spec ocr_file!(String.t() | struct(), String.t(), keyword()) :: ocr_result()
  def ocr_file!(model_spec, path, opts \\ []) do
    case ocr_file(model_spec, path, opts) do
      {:ok, result} -> result
      {:error, error} when is_exception(error) -> raise error
      {:error, reason} -> raise "OCR failed: #{inspect(reason)}"
    end
  end

  @doc false
  def build_ocr_body(model_id, document_binary, opts) do
    doc_type = Keyword.get(opts, :document_type, "application/pdf")
    include_images = Keyword.get(opts, :include_images, true)

    encoded = Base.encode64(document_binary)
    data_url = "data:#{doc_type};base64,#{encoded}"

    body = %{
      model: model_id,
      document: %{
        type: "document_url",
        document_url: data_url
      },
      include_image_base64: include_images
    }

    case Keyword.get(opts, :pages) do
      nil -> body
      pages when is_list(pages) -> Map.put(body, :pages, pages)
    end
  end

  @doc false
  def normalize_response(%{"pages" => pages}) do
    page_maps =
      Enum.map(pages, fn page ->
        %{
          index: page["index"],
          markdown: page["markdown"],
          images: Map.get(page, "images", [])
        }
      end)

    markdown =
      page_maps
      |> Enum.sort_by(& &1.index)
      |> Enum.map_join("\n\n---\n\n", & &1.markdown)

    %{markdown: markdown, pages: page_maps}
  end

  def normalize_response(%{} = response) do
    pages = Map.get(response, :pages, [])

    markdown =
      pages
      |> Enum.sort_by(&Map.get(&1, :index, 0))
      |> Enum.map_join("\n\n---\n\n", &Map.get(&1, :markdown, ""))

    %{markdown: markdown, pages: pages}
  end

  @doc false
  def ocr_capable_model?(%Model{provider: :google_vertex} = model) do
    model_id = to_string(model.provider_model_id || model.id || "")
    family = model.family || get_extra_family(model.extra)

    String.starts_with?(model_id, "mistral-ocr-") or
      ocr_enabled?(model.capabilities) or
      family == "mistral-ocr"
  end

  def ocr_capable_model?(_), do: false

  defp ocr_enabled?(capabilities) when is_map(capabilities) do
    case capabilities[:ocr] do
      true -> true
      %{enabled: true} -> true
      _ -> false
    end
  end

  defp ocr_enabled?(_), do: false

  defp get_extra_family(extra) when is_map(extra), do: extra[:family]
  defp get_extra_family(_), do: nil
end

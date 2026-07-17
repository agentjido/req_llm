defmodule ReqLLM.Providers.OpenAI.Files do
  @moduledoc """
  OpenAI-scoped lifecycle operations for reusable provider files.

  Uploaded and retrieved files are returned as explicitly owned
  `ReqLLM.Message.ContentPart` values. They can be passed directly to an
  OpenAI Responses request without changing ReqLLM's common provider
  behaviour or legacy `ContentPart.file_id/1` contract.

  ## Upload and reuse

      alias ReqLLM.Message.ContentPart
      alias ReqLLM.Providers.OpenAI.Files

      {:ok, file} =
        Files.upload(
          ContentPart.file(pdf_bytes, "report.pdf", "application/pdf"),
          purpose: :user_data
        )

      context =
        ReqLLM.Context.new([
          ReqLLM.Context.user([
            ContentPart.text("Summarize this report."),
            file
          ])
        ])

      {:ok, response} = ReqLLM.generate_text("openai:gpt-5", context)
      {:ok, true} = Files.delete(file)

  `upload/2` also accepts a local path or an explicit
  `{:binary, data, filename, media_type}` tuple. The default purpose is
  `:user_data`.

  OpenAI retains most files until they are deleted. Pass `:expires_after` as
  a number of seconds from creation when automatic expiry is appropriate, or
  call `delete/2` when the file is no longer needed.
  """

  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ProviderFileReference
  alias ReqLLM.Providers.OpenAI

  @files_model %LLMDB.Model{id: "files", provider: :openai}
  @default_media_type "application/octet-stream"
  @default_receive_timeout 120_000
  @minimum_expiry 3_600
  @maximum_expiry 2_592_000
  @request_private_key :req_llm_openai_files
  @known_response_key_atoms %{
    "bytes" => :bytes,
    "created_at" => :created_at,
    "data" => :data,
    "deleted" => :deleted,
    "error" => :error,
    "expires_at" => :expires_at,
    "filename" => :filename,
    "has_more" => :has_more,
    "id" => :id,
    "message" => :message,
    "mime_type" => :mime_type,
    "object" => :object,
    "purpose" => :purpose,
    "status" => :status,
    "status_details" => :status_details
  }
  @sensitive_error_keys ~w(
    access_token api_key api_token authorization credential credentials data file file_id id
    password reference_id secret token url
  )

  @type source ::
          String.t()
          | ContentPart.t()
          | {:binary, binary(), String.t()}
          | {:binary, binary(), String.t(), String.t()}

  defmodule Page do
    @moduledoc "A page returned by `ReqLLM.Providers.OpenAI.Files.list/1`."

    @type t :: %__MODULE__{
            files: [ReqLLM.Message.ContentPart.t()],
            has_more: boolean()
          }

    defstruct files: [], has_more: false
  end

  @doc """
  Uploads a file to OpenAI and returns its owned provider reference.

  Sources may be a local path, an inline file `ContentPart`,
  `{:binary, data, filename}`, or `{:binary, data, filename, media_type}`.

  ## Options

    * `:purpose` - OpenAI file purpose; defaults to `:user_data`
    * `:expires_after` - seconds after creation, from 3,600 through 2,592,000
    * `:media_type` - override the inferred media type
    * `:base_url` - override the OpenAI API base URL
    * `:api_key`, `:auth_mode`, `:access_token`, `:provider_options` - normal
      OpenAI authentication options
    * `:receive_timeout`, `:total_timeout`, `:max_retries` - request controls
    * `:req_http_options` - options merged into the Req request
    * `:telemetry` - ReqLLM telemetry options
    * `:fixture` - ReqLLM fixture name for tests
  """
  @spec upload(source(), keyword()) :: {:ok, ContentPart.t()} | {:error, Exception.t()}
  def upload(source, opts \\ [])

  def upload(source, opts) when is_list(opts) do
    with :ok <- validate_keyword_options(opts),
         deadline = ReqLLM.TimeoutBudget.deadline(opts),
         {:ok, upload} <- resolve_upload(source, opts),
         {:ok, request} <- build_upload_request(upload, opts),
         {:ok, %Req.Response{body: %ContentPart{} = file}} <-
           ReqLLM.TimeoutBudget.request(request, deadline) do
      {:ok, file}
    else
      {:error, error} -> {:error, normalize_error(error)}
      other -> {:error, unexpected_result(:upload, other)}
    end
  end

  def upload(_source, _opts) do
    {:error, invalid_parameter("options must be a keyword list")}
  end

  @doc "Same as `upload/2`, but raises on error."
  @spec upload!(source(), keyword()) :: ContentPart.t() | no_return()
  def upload!(source, opts \\ []) do
    upload(source, opts) |> unwrap!()
  end

  @doc """
  Retrieves current metadata for an OpenAI file.

  Accepts either a file ID or a `ContentPart`. Explicitly owned references are
  checked for OpenAI ownership and known expiry before any HTTP request.
  """
  @spec retrieve(String.t() | ContentPart.t(), keyword()) ::
          {:ok, ContentPart.t()} | {:error, Exception.t()}
  def retrieve(file, opts \\ [])

  def retrieve(file, opts) when is_list(opts) do
    with :ok <- validate_keyword_options(opts),
         deadline = ReqLLM.TimeoutBudget.deadline(opts),
         {:ok, file_id} <- resolve_file_id(file),
         {:ok, request} <-
           build_request(:file_retrieve, :get, file_path(file_id), opts,
             fallback: %{media_type: opts[:media_type]}
           ),
         {:ok, %Req.Response{body: %ContentPart{} = reference}} <-
           ReqLLM.TimeoutBudget.request(request, deadline) do
      {:ok, reference}
    else
      {:error, error} -> {:error, normalize_error(error)}
      other -> {:error, unexpected_result(:retrieve, other)}
    end
  end

  def retrieve(_file, _opts) do
    {:error, invalid_parameter("options must be a keyword list")}
  end

  @doc "Same as `retrieve/2`, but raises on error."
  @spec retrieve!(String.t() | ContentPart.t(), keyword()) :: ContentPart.t() | no_return()
  def retrieve!(file, opts \\ []) do
    retrieve(file, opts) |> unwrap!()
  end

  @doc """
  Lists OpenAI files as canonical owned references.

  Supports the OpenAI query options `:after`, `:limit`, `:order`, and
  `:purpose`, alongside the shared request and authentication options accepted
  by `upload/2`. `:after` accepts either a file ID or a returned file reference.
  """
  @spec list(keyword()) :: {:ok, Page.t()} | {:error, Exception.t()}
  def list(opts \\ [])

  def list(opts) when is_list(opts) do
    with :ok <- validate_keyword_options(opts),
         deadline = ReqLLM.TimeoutBudget.deadline(opts),
         {:ok, params} <- list_params(opts),
         {:ok, request} <- build_request(:file_list, :get, "/files", opts, params: params),
         {:ok, %Req.Response{body: %Page{} = page}} <-
           ReqLLM.TimeoutBudget.request(request, deadline) do
      {:ok, page}
    else
      {:error, error} -> {:error, normalize_error(error)}
      other -> {:error, unexpected_result(:list, other)}
    end
  end

  def list(_opts), do: {:error, invalid_parameter("options must be a keyword list")}

  @doc "Same as `list/1`, but raises on error."
  @spec list!(keyword()) :: Page.t() | no_return()
  def list!(opts \\ []) do
    list(opts) |> unwrap!()
  end

  @doc """
  Deletes an OpenAI file.

  Returns `{:ok, true}` when OpenAI confirms deletion. Explicitly owned
  references are checked for OpenAI ownership before any HTTP request.
  """
  @spec delete(String.t() | ContentPart.t(), keyword()) ::
          {:ok, boolean()} | {:error, Exception.t()}
  def delete(file, opts \\ [])

  def delete(file, opts) when is_list(opts) do
    with :ok <- validate_keyword_options(opts),
         deadline = ReqLLM.TimeoutBudget.deadline(opts),
         {:ok, file_id} <- resolve_file_id(file, validate_expiry?: false),
         {:ok, request} <- build_request(:file_delete, :delete, file_path(file_id), opts),
         {:ok, %Req.Response{body: deleted}} when is_boolean(deleted) <-
           ReqLLM.TimeoutBudget.request(request, deadline) do
      {:ok, deleted}
    else
      {:error, error} -> {:error, normalize_error(error)}
      other -> {:error, unexpected_result(:delete, other)}
    end
  end

  def delete(_file, _opts) do
    {:error, invalid_parameter("options must be a keyword list")}
  end

  @doc "Same as `delete/2`, but raises on error."
  @spec delete!(String.t() | ContentPart.t(), keyword()) :: boolean() | no_return()
  def delete!(file, opts \\ []) do
    delete(file, opts) |> unwrap!()
  end

  @doc false
  @spec decode_response({Req.Request.t(), Req.Response.t()}) ::
          {Req.Request.t(), Req.Response.t() | Exception.t()}
  def decode_response({request, %Req.Response{status: status} = response})
      when status in 200..299 do
    case request.private[@request_private_key] do
      %{operation: :file_upload, fallback: fallback} ->
        decode_file_response(request, response, fallback)

      %{operation: :file_retrieve, fallback: fallback} ->
        decode_file_response(request, response, fallback)

      %{operation: :file_list} ->
        decode_list_response(request, response)

      %{operation: :file_delete} ->
        decode_delete_response(request, response)

      _other ->
        {request, malformed_response(response, "missing file operation metadata")}
    end
  end

  def decode_response({request, %Req.Response{} = response}) do
    {request,
     ReqLLM.Error.API.Request.exception(
       reason: api_error_reason(response.body),
       status: response.status,
       response_body: sanitize_error_body(response.body),
       request_body: nil,
       headers: response.headers
     )}
  end

  @doc false
  @spec handle_error({Req.Request.t(), Exception.t() | term()}) ::
          {Req.Request.t(), Exception.t()}
  def handle_error({request, %ReqLLM.Error.API.Request{} = error}), do: {request, error}

  def handle_error({request, %ReqLLM.Error.API.Response{} = error}) do
    {request,
     ReqLLM.Error.API.Request.exception(
       reason: Exception.message(error),
       status: error.status,
       response_body: error.response_body,
       request_body: nil,
       cause: error
     )}
  end

  def handle_error({request, error}) when is_exception(error) do
    {request,
     ReqLLM.Error.API.Request.exception(
       reason: Exception.message(error),
       request_body: nil,
       cause: error
     )}
  end

  def handle_error({request, error}) do
    {request,
     ReqLLM.Error.API.Request.exception(
       reason: "OpenAI file request failed",
       request_body: nil,
       cause: error
     )}
  end

  defp build_upload_request(upload, opts) do
    with {:ok, purpose} <- normalize_purpose(Keyword.get(opts, :purpose, :user_data)),
         {:ok, expires_after} <- normalize_expires_after(opts[:expires_after]) do
      form_multipart =
        [
          file:
            {upload.data,
             filename: upload.filename, content_type: upload.media_type, size: upload.size},
          purpose: purpose
        ] ++ expiry_parts(expires_after)

      fallback = %{
        filename: upload.filename,
        media_type: upload.media_type,
        metadata: upload.metadata,
        purpose: purpose,
        size: upload.size,
        sha256: upload.sha256
      }

      build_request(:file_upload, :post, "/files", opts,
        form_multipart: form_multipart,
        fallback: fallback
      )
    end
  end

  defp build_request(operation, method, path, opts, request_opts \\ []) do
    with {:ok, credential} <- resolve_credential(opts),
         {:ok, http_opts} <- req_http_options(opts) do
      receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)
      fallback = Keyword.get(request_opts, :fallback, %{})

      request_options =
        [
          method: method,
          url: path,
          base_url: Keyword.get(opts, :base_url, OpenAI.base_url()),
          receive_timeout: receive_timeout,
          pool_timeout: receive_timeout
        ] ++
          Keyword.take(request_opts, [:form_multipart, :params]) ++
          OpenAI.auth_req_options(credential) ++ http_opts

      request =
        Req.new(request_options)
        |> Req.Request.put_header("authorization", "Bearer #{credential.token}")
        |> Req.Request.put_private(@request_private_key, %{
          operation: operation,
          fallback: fallback
        })
        |> ReqLLM.Step.Retry.attach(opts)
        |> Req.Request.append_response_steps(openai_files_decode: &decode_response/1)
        |> Req.Request.append_error_steps(openai_files_error: &handle_error/1)
        |> ReqLLM.Step.Telemetry.attach(@files_model, Keyword.put(opts, :operation, operation))
        |> ReqLLM.Step.Fixture.maybe_attach(@files_model, opts)

      {:ok, request}
    end
  end

  defp resolve_upload(%ContentPart{type: :file, data: data} = part, opts)
       when is_binary(data) do
    filename = Keyword.get(opts, :filename, part.filename)
    media_type = Keyword.get(opts, :media_type, part.media_type || @default_media_type)

    with {:ok, filename} <- non_empty_string(filename, "filename"),
         {:ok, media_type} <- non_empty_string(media_type, "media_type") do
      {:ok,
       %{
         data: data,
         filename: filename,
         media_type: media_type,
         metadata: part.metadata || %{},
         size: byte_size(data),
         sha256: sha256(data)
       }}
    end
  end

  defp resolve_upload(%ContentPart{type: :file}, _opts) do
    {:error, invalid_parameter("source file ContentPart must contain inline data")}
  end

  defp resolve_upload({:binary, data, filename}, opts) when is_binary(data) do
    resolve_upload(
      {:binary, data, filename, Keyword.get(opts, :media_type, media_type_from_path(filename))},
      opts
    )
  end

  defp resolve_upload({:binary, data, filename, media_type}, opts) when is_binary(data) do
    resolve_upload(ContentPart.file(data, filename, media_type), opts)
  end

  defp resolve_upload(path, opts) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} ->
        filename = Keyword.get(opts, :filename, Path.basename(path))
        media_type = Keyword.get(opts, :media_type, media_type_from_path(path))

        with {:ok, filename} <- non_empty_string(filename, "filename"),
             {:ok, media_type} <- non_empty_string(media_type, "media_type") do
          {:ok,
           %{
             data: file_stream(path),
             filename: filename,
             media_type: media_type,
             metadata: %{},
             size: size,
             sha256: nil
           }}
        end

      {:error, reason} ->
        {:error, invalid_parameter("source file could not be read (#{reason})")}

      {:ok, _stat} ->
        {:error, invalid_parameter("source path must be a regular file")}
    end
  end

  defp resolve_upload(_source, _opts) do
    {:error,
     invalid_parameter("source must be a path, inline file ContentPart, or explicit binary tuple")}
  end

  defp resolve_file_id(file, opts \\ [])

  defp resolve_file_id(%ContentPart{type: :file} = part, opts) do
    validate_expiry? = Keyword.get(opts, :validate_expiry?, true)

    with :ok <- ProviderFileReference.validate(part, :openai, validate_expiry?: validate_expiry?) do
      content_part_file_id(part)
    end
  end

  defp resolve_file_id(file_id, _opts) when is_binary(file_id) do
    non_empty_string(file_id, "file ID")
  end

  defp resolve_file_id(_file, _opts) do
    {:error, invalid_parameter("file must be a file ID or file ContentPart")}
  end

  defp content_part_file_id(%ContentPart{} = part) do
    case ProviderFileReference.reference_id(part, :openai) do
      {:ok, file_id} -> {:ok, file_id}
      :error -> non_empty_string(part.file_id, "file ID")
    end
  end

  defp decode_file_response(request, response, fallback) do
    case file_reference(response.body, fallback) do
      {:ok, file} -> {request, %{response | body: file}}
      {:error, reason} -> {request, malformed_response(response, reason)}
    end
  end

  defp decode_list_response(request, response) do
    body = response.body

    with data when is_list(data) <- value(body, "data"),
         {:ok, files} <- map_file_references(data) do
      page = %Page{
        files: files,
        has_more: value(body, "has_more") == true
      }

      {request, %{response | body: page}}
    else
      _other -> {request, malformed_response(response, "invalid file list payload")}
    end
  end

  defp decode_delete_response(request, response) do
    case value(response.body, "deleted") do
      deleted when is_boolean(deleted) -> {request, %{response | body: deleted}}
      _other -> {request, malformed_response(response, "invalid file deletion payload")}
    end
  end

  defp map_file_references(data) do
    Enum.reduce_while(data, {:ok, []}, fn item, {:ok, files} ->
      case file_reference(item, %{}) do
        {:ok, file} -> {:cont, {:ok, [file | files]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end)
  end

  defp file_reference(body, fallback) when is_map(body) do
    with {:ok, file_id} <- non_empty_string(value(body, "id"), "response file ID"),
         {:ok, purpose} <- response_purpose(body, fallback),
         {:ok, media_type} <- response_media_type(body, fallback) do
      filename = value(body, "filename") || fallback[:filename]
      expires_at = normalize_response_expiry(value(body, "expires_at"))
      status = value(body, "status")
      size = value(body, "bytes") || fallback[:size]

      file =
        ContentPart.owned_file_id(file_id, :openai,
          media_type: media_type,
          metadata: fallback[:metadata] || %{},
          purpose: purpose,
          status: status,
          expires_at: expires_at,
          size: size,
          sha256: fallback[:sha256],
          provider_metadata: provider_metadata(body)
        )

      {:ok, %{file | filename: filename}}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp file_reference(_body, _fallback), do: {:error, "invalid file payload"}

  defp response_purpose(body, fallback) do
    normalize_purpose(value(body, "purpose") || fallback[:purpose] || :user_data)
  end

  defp response_media_type(body, fallback) do
    filename = value(body, "filename") || fallback[:filename]

    non_empty_string(
      value(body, "mime_type") || fallback[:media_type] || media_type_from_path(filename),
      "response media type"
    )
  end

  defp provider_metadata(body) do
    %{}
    |> put_present("object", value(body, "object"))
    |> put_present("created_at", value(body, "created_at"))
    |> put_present("status_details", value(body, "status_details"))
  end

  defp list_params(opts) do
    with {:ok, order} <- normalize_order(opts[:order]),
         {:ok, limit} <- normalize_limit(opts[:limit]),
         {:ok, purpose} <- normalize_optional_purpose(opts[:purpose]),
         {:ok, after_id} <- normalize_after(opts[:after]) do
      {:ok,
       []
       |> put_keyword(:after, after_id)
       |> put_keyword(:limit, limit)
       |> put_keyword(:order, order)
       |> put_keyword(:purpose, purpose)}
    end
  end

  defp normalize_purpose(value) when is_atom(value), do: normalize_purpose(Atom.to_string(value))

  defp normalize_purpose(value) when is_binary(value) do
    non_empty_string(String.trim(value), "purpose")
  end

  defp normalize_purpose(_value) do
    {:error, invalid_parameter("purpose must be an atom or non-empty string")}
  end

  defp normalize_optional_purpose(nil), do: {:ok, nil}
  defp normalize_optional_purpose(value), do: normalize_purpose(value)

  defp normalize_after(nil), do: {:ok, nil}
  defp normalize_after(%ContentPart{} = part), do: resolve_file_id(part, validate_expiry?: false)
  defp normalize_after(value), do: non_empty_string(value, "after")

  defp normalize_expires_after(nil), do: {:ok, nil}

  defp normalize_expires_after(seconds)
       when is_integer(seconds) and seconds >= @minimum_expiry and seconds <= @maximum_expiry,
       do: {:ok, seconds}

  defp normalize_expires_after(_seconds) do
    {:error,
     invalid_parameter(
       "expires_after must be an integer from #{@minimum_expiry} through #{@maximum_expiry} seconds"
     )}
  end

  defp normalize_response_expiry(nil), do: nil

  defp normalize_response_expiry(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, date_time} -> date_time
      {:error, _reason} -> nil
    end
  end

  defp normalize_response_expiry(value) when is_binary(value) do
    case Integer.parse(value) do
      {unix, ""} -> normalize_response_expiry(unix)
      _other -> value
    end
  end

  defp normalize_response_expiry(_value), do: nil

  defp normalize_order(nil), do: {:ok, nil}
  defp normalize_order(order) when order in [:asc, :desc], do: {:ok, Atom.to_string(order)}
  defp normalize_order(order) when order in ["asc", "desc"], do: {:ok, order}

  defp normalize_order(_order) do
    {:error, invalid_parameter("order must be :asc or :desc")}
  end

  defp normalize_limit(nil), do: {:ok, nil}
  defp normalize_limit(limit) when is_integer(limit) and limit in 1..10_000, do: {:ok, limit}

  defp normalize_limit(_limit) do
    {:error, invalid_parameter("limit must be an integer from 1 through 10000")}
  end

  defp non_empty_string(value, _name) when is_binary(value) and value != "", do: {:ok, value}

  defp non_empty_string(_value, name) do
    {:error, invalid_parameter("#{name} must be a non-empty string")}
  end

  defp req_http_options(opts) do
    case Keyword.get(opts, :req_http_options, []) do
      value when is_list(value) ->
        if Keyword.keyword?(value) do
          {:ok, value}
        else
          {:error, invalid_parameter("req_http_options must be a keyword list or map")}
        end

      value when is_map(value) ->
        {:ok, Map.to_list(value)}

      _value ->
        {:error, invalid_parameter("req_http_options must be a keyword list or map")}
    end
  end

  defp validate_keyword_options(opts) do
    if Keyword.keyword?(opts) do
      :ok
    else
      {:error, invalid_parameter("options must be a keyword list")}
    end
  end

  defp resolve_credential(opts) do
    case ReqLLM.Auth.resolve(@files_model, opts) do
      {:ok, credential} -> {:ok, credential}
      {:error, message} -> {:error, invalid_parameter(message)}
    end
  end

  defp normalize_error(error) when is_exception(error), do: error
  defp normalize_error(error), do: ReqLLM.Error.to_class(error)

  defp unexpected_result(operation, result) do
    ReqLLM.Error.API.Response.exception(
      reason: "unexpected OpenAI file #{operation} result",
      response_body: sanitize_unexpected_result(result)
    )
  end

  defp sanitize_unexpected_result({:ok, %Req.Response{} = response}) do
    %{status: response.status, body_type: response_body_type(response.body)}
  end

  defp response_body_type(value) when is_map(value), do: :map
  defp response_body_type(value) when is_list(value), do: :list
  defp response_body_type(value) when is_binary(value), do: :binary
  defp response_body_type(value) when is_boolean(value), do: :boolean
  defp response_body_type(_value), do: :other

  defp malformed_response(response, reason) do
    ReqLLM.Error.API.Response.exception(
      reason: "OpenAI Files API returned #{reason}",
      status: response.status,
      response_body: %{body_type: response_body_type(response.body)}
    )
  end

  defp api_error_reason(body) when is_map(body) do
    value(body, "error")
    |> then(fn
      error when is_map(error) -> value(error, "message")
      error when is_binary(error) -> error
      _other -> value(body, "message")
    end)
    |> case do
      message when is_binary(message) and message != "" -> message
      _other -> "OpenAI file request failed"
    end
  end

  defp api_error_reason(_body), do: "OpenAI file request failed"

  defp sanitize_error_body(value) when is_map(value) do
    Map.new(value, fn {key, entry} ->
      if sensitive_error_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, sanitize_error_body(entry)}
      end
    end)
  end

  defp sanitize_error_body(value) when is_list(value), do: Enum.map(value, &sanitize_error_body/1)

  defp sanitize_error_body(value) when is_binary(value) do
    if String.starts_with?(value, ["http://", "https://"]), do: "[REDACTED]", else: value
  end

  defp sanitize_error_body(value), do: value

  defp sensitive_error_key?(key) when is_atom(key) or is_binary(key) do
    name = key |> to_string() |> String.downcase()

    name in @sensitive_error_keys or String.contains?(name, "credential") or
      String.contains?(name, "secret") or String.ends_with?(name, "_token")
  end

  defp sensitive_error_key?(_key), do: false

  defp invalid_parameter(message) do
    ReqLLM.Error.Invalid.Parameter.exception(parameter: "OpenAI files: #{message}")
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: raise(error)

  defp expiry_parts(nil), do: []

  defp expiry_parts(seconds) do
    [
      {:"expires_after[anchor]", "created_at"},
      {:"expires_after[seconds]", Integer.to_string(seconds)}
    ]
  end

  defp file_path(file_id) do
    "/files/" <> URI.encode(file_id, &URI.char_unreserved?/1)
  end

  defp media_type_from_path(path) when is_binary(path) do
    case Path.extname(path) |> String.downcase() do
      ".pdf" -> "application/pdf"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".json" -> "application/json"
      ".jsonl" -> "application/jsonl"
      ".csv" -> "text/csv"
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      _other -> @default_media_type
    end
  end

  defp media_type_from_path(_path), do: @default_media_type

  defp file_stream(path) do
    arguments =
      if Version.compare(System.version(), "1.18.0") == :lt do
        [path, [], 64 * 1024]
      else
        [path, 64 * 1024, []]
      end

    apply(File, :stream!, arguments)
  end

  defp sha256(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Map.fetch!(@known_response_key_atoms, key))
    end
  end

  defp value(_map, _key), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_keyword(keyword, _key, nil), do: keyword
  defp put_keyword(keyword, key, value), do: Keyword.put(keyword, key, value)
end

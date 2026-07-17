defmodule ReqLLM.Providers.OpenAI.FilesTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Error.Invalid.ProviderFileReference
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.OpenAI.Files
  alias ReqLLM.Providers.OpenAI.ResponsesAPI

  @api_key "test-openai-file-key"
  @http_opts [plug: {Req.Test, __MODULE__}]

  test "uploads once, preserves lifecycle metadata, and reuses the reference" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/files"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{@api_key}"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert body =~ "private-pdf-bytes"
      assert body =~ "report.pdf"
      assert body =~ "application/pdf"
      assert body =~ "user_data"
      assert body =~ "expires_after[anchor]"
      assert body =~ "expires_after[seconds]"
      assert body =~ "3600"

      Req.Test.json(conn, %{
        "id" => "file-uploaded-secret",
        "object" => "file",
        "bytes" => 17,
        "created_at" => 1_783_000_000,
        "expires_at" => 1_783_003_600,
        "filename" => "report.pdf",
        "purpose" => "user_data",
        "status" => "processed"
      })
    end)

    source = ContentPart.file("private-pdf-bytes", "report.pdf", "application/pdf")

    assert {:ok, %ContentPart{} = file} =
             Files.upload(source,
               purpose: :user_data,
               expires_after: 3_600,
               api_key: @api_key,
               req_http_options: @http_opts
             )

    assert file.type == :file
    assert file.file_id == "file-uploaded-secret"
    assert file.data == nil
    assert file.filename == "report.pdf"
    assert file.media_type == "application/pdf"

    assert {:ok, reference} = ContentPart.provider_file_reference(file)
    assert reference["provider"] == "openai"
    assert reference["reference_id"] == "file-uploaded-secret"
    assert reference["purpose"] == "user_data"
    assert reference["status"] == "processed"
    assert reference["size"] == 17
    assert reference["expires_at"] == "2026-07-02T14:46:40Z"
    assert reference["sha256"] == sha256("private-pdf-bytes")
    assert reference["metadata"]["object"] == "file"
    assert reference["metadata"]["created_at"] == 1_783_000_000

    context = ReqLLM.Context.new([ReqLLM.Context.user([ContentPart.text("Summarize"), file])])

    request = %Req.Request{
      options: [context: context, model: "gpt-5", api_mod: ResponsesAPI]
    }

    body = request |> ResponsesAPI.encode_body() |> ReqLLM.Test.Helpers.json_body()

    assert [%{"content" => content}] = body["input"]

    assert Enum.any?(content, fn part ->
             part["type"] == "input_file" and part["file_id"] == "file-uploaded-secret"
           end)
  end

  test "supports fixture-backed upload responses" do
    assert {:ok, file} =
             Files.upload(
               {:binary, "fixture-bytes", "fixture.pdf", "application/pdf"},
               api_key: @api_key,
               fixture: "upload"
             )

    assert file.file_id == "file-fixture-upload"
    assert file.filename == "fixture.pdf"
    assert file.media_type == "application/pdf"
    assert ContentPart.owned_file?(file)
  end

  test "streams local paths into multipart uploads" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "req_llm_openai_files_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    path = Path.join(tmp_dir, "streamed.pdf")
    File.write!(path, "streamed-path-bytes")

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "streamed-path-bytes"
      assert body =~ "streamed.pdf"
      Req.Test.json(conn, file_payload("file-streamed-path", "streamed.pdf"))
    end)

    assert {:ok, file} =
             Files.upload(path, api_key: @api_key, req_http_options: @http_opts)

    assert file.file_id == "file-streamed-path"
    assert file.filename == "streamed.pdf"
    assert file.media_type == "application/pdf"
  end

  test "retrieves, lists, paginates, and deletes owned files" do
    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v1/files/file-retrieve"} ->
          Req.Test.json(conn, file_payload("file-retrieve", "retrieved.pdf"))

        {"GET", "/v1/files"} ->
          assert conn.query_params["after"] == "file-retrieve"
          assert conn.query_params["limit"] == "2"
          assert conn.query_params["order"] == "asc"
          assert conn.query_params["purpose"] == "user_data"

          Req.Test.json(conn, %{
            "object" => "list",
            "data" => [
              file_payload("file-list-1", "one.pdf"),
              file_payload("file-list-2", "two.png")
            ],
            "first_id" => "file-list-1",
            "last_id" => "file-list-2",
            "has_more" => true
          })

        {"DELETE", "/v1/files/file-retrieve"} ->
          Req.Test.json(conn, %{
            "id" => "file-retrieve",
            "object" => "file",
            "deleted" => true
          })
      end
    end)

    opts = [api_key: @api_key, req_http_options: @http_opts]

    assert {:ok, retrieved} = Files.retrieve("file-retrieve", opts)
    assert retrieved.filename == "retrieved.pdf"
    assert retrieved.media_type == "application/pdf"

    assert {:ok, %Files.Page{files: [first, second], has_more: true}} =
             Files.list(
               opts ++
                 [after: retrieved, limit: 2, order: :asc, purpose: :user_data]
             )

    assert first.file_id == "file-list-1"
    assert first.media_type == "application/pdf"
    assert second.file_id == "file-list-2"
    assert second.media_type == "image/png"

    assert {:ok, true} = Files.delete(retrieved, opts)
  end

  test "rejects foreign references before I/O and permits expired-file cleanup" do
    foreign = ContentPart.owned_file_id("file-foreign-secret", :anthropic)

    assert {:error, %ProviderFileReference{reason: :provider_mismatch} = mismatch} =
             Files.retrieve(foreign,
               api_key: @api_key,
               req_http_options: [plug: fn _conn -> flunk("unexpected request") end]
             )

    refute Exception.message(mismatch) =~ "file-foreign-secret"

    expired =
      ContentPart.owned_file_id("file-expired", :openai, expires_at: ~U[2020-01-01 00:00:00Z])

    assert {:error, %ProviderFileReference{reason: :expired}} = Files.retrieve(expired)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/v1/files/file-expired"
      Req.Test.json(conn, %{"id" => "file-expired", "deleted" => true})
    end)

    assert {:ok, true} =
             Files.delete(expired, api_key: @api_key, req_http_options: @http_opts)
  end

  test "returns typed, redacted upload errors" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "error" => %{
          "message" => "unsupported file",
          "file_id" => "file-provider-secret",
          "url" => "https://private.example/file"
        }
      })
    end)

    assert {:error, %ReqLLM.Error.API.Request{status: 400} = error} =
             Files.upload(
               {:binary, "private-upload-contents", "secret.pdf", "application/pdf"},
               api_key: @api_key,
               req_http_options: @http_opts
             )

    rendered = inspect(error)

    assert Exception.message(error) =~ "unsupported file"
    refute rendered =~ "private-upload-contents"
    refute rendered =~ @api_key
    refute rendered =~ "file-provider-secret"
    refute rendered =~ "private.example"
    assert error.request_body == nil
  end

  test "raw telemetry reports metadata without file bytes or provider IDs" do
    handler_id = "openai-files-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [[:req_llm, :request, :start], [:req_llm, :request, :stop]],
      fn event, measurements, metadata, pid ->
        send(pid, {event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, file_payload("file-telemetry-secret", "telemetry.pdf"))
    end)

    assert {:ok, _file} =
             Files.upload(
               {:binary, "telemetry-private-bytes", "telemetry.pdf", "application/pdf"},
               api_key: @api_key,
               telemetry: [payloads: :raw],
               req_http_options: @http_opts
             )

    assert_receive {[:req_llm, :request, :start], _measurements, start_metadata}
    assert start_metadata.operation == :file_upload
    refute inspect(start_metadata) =~ "telemetry-private-bytes"
    refute inspect(start_metadata) =~ @api_key

    assert_receive {[:req_llm, :request, :stop], _measurements, stop_metadata}
    assert stop_metadata.operation == :file_upload
    assert stop_metadata.response_payload.file_id == "[REDACTED]"
    refute inspect(stop_metadata) =~ "file-telemetry-secret"
    refute inspect(stop_metadata) =~ "telemetry-private-bytes"
  end

  test "validates upload and list controls without I/O" do
    assert {:error, %ReqLLM.Error.Invalid.Parameter{} = expiry_error} =
             Files.upload(
               {:binary, "data", "data.txt", "text/plain"},
               expires_after: 10
             )

    assert Exception.message(expiry_error) =~ "expires_after"

    assert {:error, %ReqLLM.Error.Invalid.Parameter{} = limit_error} = Files.list(limit: 0)
    assert Exception.message(limit_error) =~ "limit"
  end

  defp file_payload(id, filename) do
    %{
      "id" => id,
      "object" => "file",
      "bytes" => 12,
      "created_at" => 1_783_000_000,
      "expires_at" => 1_900_000_000,
      "filename" => filename,
      "purpose" => "user_data",
      "status" => "processed"
    }
  end

  defp sha256(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end
end

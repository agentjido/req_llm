defmodule ReqLLM.VideoTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Test.WorkflowHTTP
  alias ReqLLM.Video
  alias ReqLLM.Video.Task, as: VideoTask

  @moduletag contract: :public_api
  @model %{
    provider: :minimax,
    id: "MiniMax-H3-custom",
    capabilities: %{video: true}
  }
  @task %VideoTask{task_id: "task-1", status: :succeeded, url: "https://video.example/output.mp4"}
  @video_file %Video.File{file_id: 42, filename: "frame.png", bytes: 5}

  defmodule Provider do
    use ReqLLM.Provider,
      id: :minimax,
      default_base_url: "https://video.example"

    @impl true
    def prepare_request(operation, model, input, opts) do
      prepare = opts[:prepare] || opts[:req_http_options][:prepare]
      prepare.(operation, model, input, opts)
    end
  end

  setup_all do
    {:ok, original_provider} = ReqLLM.provider(:minimax)
    on_exit(fn -> ReqLLM.Providers.register!(original_provider) end)
    ReqLLM.Providers.register!(Provider)
    :ok
  end

  for {operation, input, body} <- [
        {:video, [prompt: "A cat"], @task},
        {:video_query, "task-1", @task},
        {:video_wait, "task-1", @task},
        {:video_upload, "bytes", @video_file},
        {:video_retrieve, 42, %{custom_download: "provider-defined"}}
      ] do
    @operation operation
    @input input
    @body body

    test "#{operation} preserves decoded results and provider callback inputs" do
      schema = NimbleOptions.new!(value: [type: :string])
      expected_operation = if @operation == :video_wait, do: :video_query, else: @operation
      expected_input = @input
      owner = self()

      prepare = fn operation, model, input, opts ->
        send(owner, {:prepared, operation, model, input, opts})
        {:ok, request(@body, 201)}
      end

      assert call(@operation,
               prepare: prepare,
               schema: schema,
               req_http_options: %{receive_timeout: 1234},
               duplicate: :first,
               duplicate: :second
             ) == {:ok, @body}

      assert_receive {:prepared, ^expected_operation, %LLMDB.Model{id: "MiniMax-H3-custom"},
                      ^expected_input, opts}

      assert opts[:schema] == schema
      assert opts[:req_http_options] == %{receive_timeout: 1234}
      assert Keyword.get_values(opts, :duplicate) == [:first, :second]
      refute Keyword.has_key?(opts, :poll_interval)
      refute Keyword.has_key?(opts, :timeout)
      refute Keyword.has_key?(opts, :max_transient_retries)
      refute_received {:prepared, _, _, _, _}
    end

    test "#{operation} retains HTTP error type, body and important text" do
      body = %{"error" => "rejected"}
      prepare = fn _operation, _model, _input, _opts -> {:ok, request(body, 422)} end

      assert {:error,
              %ReqLLM.Error.API.Request{
                status: 422,
                reason: "HTTP 422: Request failed",
                response_body: ^body
              } = error} = call(@operation, prepare: prepare)

      assert Exception.message(error) == "API request failed (422): HTTP 422: Request failed"
    end

    test "#{operation} passes preparation and transport errors through unchanged" do
      for error <- [{:provider_rejected, @operation}, %Req.TransportError{reason: :closed}] do
        prepare = fn _operation, _model, _input, _opts ->
          case error do
            %Req.TransportError{} ->
              {:ok, WorkflowHTTP.request(error)}

            _ ->
              {:error, error}
          end
        end

        assert call(@operation, prepare: prepare) == {:error, error}
      end
    end

    test "#{operation} enforces total_timeout during the request" do
      prepare = fn _operation, _model, _input, _opts ->
        {:ok,
         WorkflowHTTP.request(fn request ->
           receive do
             :finish_request -> {request, %Req.Response{status: 200, body: @body}}
           end
         end)}
      end

      assert {:error, %ReqLLM.Error.API.Timeout{kind: :total, timeout: 20}} =
               call(@operation, prepare: prepare, total_timeout: 20)
    end
  end

  for operation <- [:video, :video_query, :video_wait, :video_upload] do
    @operation operation

    test "#{operation} rejects a 2xx body with the wrong decoded type" do
      prepare = fn _operation, _model, _input, _opts -> {:ok, request(%{unexpected: true})} end

      assert {:error,
              %ReqLLM.Error.API.Request{
                status: 200,
                reason: "HTTP 200: Request failed",
                response_body: %{unexpected: true}
              }} = call(@operation, prepare: prepare)
    end
  end

  test "wait prepares once and reuses the signed request through polls and a transient retry" do
    owner = self()
    counter = :counters.new(1, [])

    prepare = fn :video_query, _model, "task-1", _opts ->
      signature = make_ref()
      send(owner, {:prepared_signature, signature})

      {:ok,
       WorkflowHTTP.request(fn request ->
         :counters.add(counter, 1, 1)
         attempt = :counters.get(counter, 1)
         send(owner, {:poll, attempt, request.private[:signature]})

         case attempt do
           1 -> {request, %Req.Response{status: 200, body: %VideoTask{task_id: "task-1"}}}
           2 -> {request, %Req.TransportError{reason: :closed}}
           3 -> {request, %Req.Response{status: 200, body: @task}}
         end
       end)
       |> Req.Request.put_private(:signature, signature)}
    end

    assert {:ok, @task} =
             call(:video_wait, prepare: prepare, poll_interval: 0, max_transient_retries: 1)

    assert_receive {:prepared_signature, signature}
    assert_receive {:poll, 1, ^signature}
    assert_receive {:poll, 2, ^signature}
    assert_receive {:poll, 3, ^signature}
    refute_received {:prepared_signature, _}
    refute_received {:poll, _, _}
  end

  test "wait does not replenish transient retries after a successful nonterminal poll" do
    counter = :counters.new(1, [])

    prepare = fn :video_query, _model, _input, _opts ->
      {:ok,
       WorkflowHTTP.request(fn request ->
         :counters.add(counter, 1, 1)

         case :counters.get(counter, 1) do
           2 -> {request, %Req.Response{status: 200, body: %VideoTask{task_id: "task-1"}}}
           _ -> {request, %Req.TransportError{reason: :closed}}
         end
       end)}
    end

    assert {:error, %Req.TransportError{reason: :closed}} =
             call(:video_wait, prepare: prepare, poll_interval: 0, max_transient_retries: 1)

    assert :counters.get(counter, 1) == 3
  end

  @tag timeout: 2_000
  test "wait caps the poll sleep at the remaining wait budget" do
    owner = self()

    prepare = fn :video_query, _model, _input, _opts ->
      {:ok,
       WorkflowHTTP.request(fn request ->
         send(owner, :poll)
         {request, %Req.Response{status: 200, body: %VideoTask{task_id: "task-1"}}}
       end)}
    end

    assert {:error, %ReqLLM.Error.API.Timeout{kind: :total, timeout: 30}} =
             call(:video_wait, prepare: prepare, poll_interval: 10_000, timeout: 30)

    assert_receive :poll
    refute_received :poll
  end

  test "wait starts a fresh per-request budget for each poll" do
    counter = :counters.new(1, [])

    prepare = fn :video_query, _model, _input, _opts ->
      {:ok,
       WorkflowHTTP.request(fn request ->
         :counters.add(counter, 1, 1)
         Process.sleep(25)
         status = if :counters.get(counter, 1) == 2, do: :succeeded, else: :running

         {request,
          %Req.Response{status: 200, body: %VideoTask{task_id: "task-1", status: status}}}
       end)}
    end

    assert {:ok, %VideoTask{status: :succeeded}} =
             call(:video_wait,
               prepare: prepare,
               poll_interval: 0,
               total_timeout: 40,
               timeout: 2_000
             )

    assert :counters.get(counter, 1) == 2
  end

  test "create uploads media first, preserving the upload options and resolved reference" do
    owner = self()

    prepare = fn operation, _model, input, opts ->
      send(owner, {:prepared, operation, input, opts})

      case operation do
        :video_upload -> {:ok, request(@video_file)}
        :video -> {:ok, request(@task)}
      end
    end

    assert {:ok, @task} =
             Video.generate_video(
               @model,
               [prompt: "A cat", first_frame_image: {:upload, "bytes", "image/png"}],
               prepare: prepare,
               req_http_options: [prepare: prepare],
               api_key: "key",
               filename: "frame.png"
             )

    assert_receive {:prepared, :video_upload, "bytes", upload_opts}
    assert upload_opts[:api_key] == "key"
    assert upload_opts[:media_type] == "image/png"
    assert upload_opts[:filename] == "frame.png"
    assert_receive {:prepared, :video, content, _opts}
    assert content == [first_frame_image: "mm_file://42", prompt: "A cat"]
    refute_received {:prepared, _, _, _}
  end

  test "create stops on upload failure without preparing the create request" do
    owner = self()

    prepare = fn operation, _model, _input, _opts ->
      send(owner, {:prepared, operation})
      {:error, {:upload_rejected, :media}}
    end

    assert {:error, {:upload_rejected, :media}} =
             Video.generate_video(
               @model,
               [prompt: "A cat", first_frame_image: {:upload, "bytes", "image/png"}],
               prepare: prepare,
               req_http_options: [prepare: prepare]
             )

    assert_receive {:prepared, :video_upload}
    refute_received {:prepared, _}
  end

  test "create shares one deadline with its uploads" do
    owner = self()

    prepare = fn operation, _model, _input, _opts ->
      send(owner, {:prepared, operation})

      case operation do
        :video_upload ->
          {:ok,
           WorkflowHTTP.request(fn request ->
             Process.sleep(15)
             {request, %Req.Response{status: 200, body: @video_file}}
           end)}

        :video ->
          Process.sleep(15)

          {:ok,
           WorkflowHTTP.request(fn request ->
             send(owner, :unexpected_create_request)
             {request, %Req.Response{status: 200, body: @task}}
           end)}
      end
    end

    assert {:error, %ReqLLM.Error.API.Timeout{kind: :total, timeout: 25}} =
             Video.generate_video(
               @model,
               [prompt: "A cat", first_frame_image: {:upload, "bytes", "image/png"}],
               prepare: prepare,
               req_http_options: [prepare: prepare],
               total_timeout: 25
             )

    assert_receive {:prepared, :video_upload}
    assert_receive {:prepared, :video}
    refute_received :unexpected_create_request
  end

  defp call(:video, opts), do: Video.generate_video(@model, [prompt: "A cat"], opts)
  defp call(:video_query, opts), do: Video.query_video(@model, "task-1", opts)

  defp call(:video_wait, opts) do
    Video.wait_video(@model, "task-1", Keyword.merge([max_transient_retries: 0], opts))
  end

  defp call(:video_upload, opts), do: Video.upload_file(@model, "bytes", opts)
  defp call(:video_retrieve, opts), do: Video.retrieve_file(@model, 42, opts)

  defp request(body, status \\ 200) do
    WorkflowHTTP.request(%Req.Response{status: status, body: body})
  end
end

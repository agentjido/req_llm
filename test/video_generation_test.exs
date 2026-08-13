defmodule ReqLLM.VideoGenerationTest do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Minimax

  alias ReqLLM.Providers.Minimax
  alias ReqLLM.Providers.Minimax.VideoAPI
  alias ReqLLM.Video
  alias ReqLLM.Video.Task

  defp minimax_video_model(model_id \\ "MiniMax-H3") do
    %LLMDB.Model{
      id: model_id,
      model: model_id,
      provider_model_id: model_id,
      provider: :minimax,
      name: model_id,
      family: "minimax-h3",
      capabilities: %{video: true},
      limits: %{},
      extra: %{}
    }
  end

  describe "model operation" do
    test ":video is a known operation" do
      assert ReqLLM.ModelOperation.known?(:video)
      assert :video in ReqLLM.ModelOperation.operations()
    end

    test "video-capable models are detected" do
      model = minimax_video_model()
      assert ReqLLM.ModelOperation.supported?(model, :video)
      refute ReqLLM.ModelOperation.supported?(model, :text)
    end
  end

  describe "prepare_request" do
    test "prepare_request for :video creates /v2/video_generation request with api_mod" do
      model = minimax_video_model()

      {:ok, request} =
        Minimax.prepare_request(:video, model, [prompt: "A boy playing basketball by the sea"],
          duration: 5,
          resolution: "2K",
          ratio: "16:9",
          api_key: "test-key"
        )

      assert %Req.Request{} = request
      assert request.url.path == "/v2/video_generation"
      assert request.method == :post
      assert request.options[:base_url] == "https://api.minimax.io"
      assert request.options[:api_mod] == VideoAPI
      assert request.options[:operation] == :video
      assert request.options[:content][:prompt] == "A boy playing basketball by the sea"
    end

    test "prepare_request for :video rejects empty prompt" do
      model = minimax_video_model()

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Minimax.prepare_request(:video, model, [prompt: "  "], api_key: "test-key")
    end

    test "prepare_request for :video_query creates query request with task_id" do
      model = minimax_video_model()

      {:ok, request} =
        Minimax.prepare_request(:video_query, model, "task-123", api_key: "test-key")

      assert %Req.Request{} = request
      assert request.url.path == "/v2/query/video_generation/task-123"
      assert request.method == :get
      assert request.options[:api_mod] == VideoAPI
      assert request.options[:operation] == :video_query
      assert request.options[:task_id] == "task-123"
    end
  end

  describe "encode_body" do
    defp video_request(content, opts \\ []) do
      Req.new(url: VideoAPI.path())
      |> Req.Request.register_options([
        :model,
        :content,
        :duration,
        :resolution,
        :ratio,
        :callback_url,
        :operation
      ])
      |> Req.Request.merge_options(
        Keyword.merge(
          [
            model: "MiniMax-H3",
            content: content,
            operation: :video
          ],
          opts
        )
      )
    end

    test "text-to-video content encoding" do
      encoded =
        video_request([prompt: "A boy playing basketball by the sea"],
          duration: 5,
          resolution: "2K",
          ratio: "16:9"
        )
        |> VideoAPI.encode_body()

      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["model"] == "MiniMax-H3"
      assert body["duration"] == 5
      assert body["resolution"] == "2K"
      assert body["ratio"] == "16:9"

      assert body["content"] == [
               %{"type" => "text", "text" => "A boy playing basketball by the sea"}
             ]
    end

    test "image-to-video content encoding with first and last frame" do
      encoded =
        video_request(
          [
            prompt: "A little girl grows up",
            first_frame_image: "https://example.com/start.png",
            last_frame_image: "https://example.com/end.png"
          ],
          duration: 5,
          resolution: "2K"
        )
        |> VideoAPI.encode_body()

      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["content"] == [
               %{"type" => "text", "text" => "A little girl grows up"},
               %{
                 "type" => "image_url",
                 "image_url" => %{"url" => "https://example.com/start.png"},
                 "role" => "first_frame"
               },
               %{
                 "type" => "image_url",
                 "image_url" => %{"url" => "https://example.com/end.png"},
                 "role" => "last_frame"
               }
             ]
    end

    test "reference-to-video content encoding" do
      encoded =
        video_request(
          [
            prompt: "Character dances following the reference",
            reference_images: ["https://example.com/char.png"],
            reference_videos: ["https://example.com/motion.mp4"],
            reference_audio: ["https://example.com/voice.mp3"]
          ],
          duration: 5,
          resolution: "2K"
        )
        |> VideoAPI.encode_body()

      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["content"] == [
               %{"type" => "text", "text" => "Character dances following the reference"},
               %{
                 "type" => "image_url",
                 "image_url" => %{"url" => "https://example.com/char.png"},
                 "role" => "reference_image"
               },
               %{
                 "type" => "video_url",
                 "video_url" => %{"url" => "https://example.com/motion.mp4"},
                 "role" => "reference_video"
               },
               %{
                 "type" => "audio_url",
                 "audio_url" => %{"url" => "https://example.com/voice.mp3"},
                 "role" => "reference_audio"
               }
             ]
    end

    test "single media value is accepted without a list" do
      encoded =
        video_request(
          [prompt: "A cat", first_frame_image: "https://example.com/cat.png"],
          duration: 4,
          resolution: "768P"
        )
        |> VideoAPI.encode_body()

      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert [%{"type" => "text"}, %{"type" => "image_url", "role" => "first_frame"}] =
               body["content"]
    end
  end

  describe "decode_response" do
    test "create response yields a Task with task_id" do
      req =
        Req.new(url: VideoAPI.path())
        |> Req.Request.register_options([:model, :operation])
        |> Req.Request.merge_options(model: "MiniMax-H3", operation: :video)

      resp = %Req.Response{
        status: 200,
        body: %{"task_id" => "424010985738629"}
      }

      {_req, updated} = VideoAPI.decode_response({req, resp})

      assert %Task{task_id: "424010985738629", status: :queued, provider: :minimax} =
               updated.body
    end

    test "query response yields a Task with url on success" do
      req =
        Req.new(url: VideoAPI.query_path("task-1"))
        |> Req.Request.register_options([:model, :operation, :task_id])
        |> Req.Request.merge_options(
          model: "MiniMax-H3",
          operation: :video_query,
          task_id: "task-1"
        )

      resp = %Req.Response{
        status: 200,
        body: %{
          "task" => %{
            "id" => "task-1",
            "model" => "MiniMax-H3",
            "status" => "succeeded",
            "content" => %{"url" => "https://cdn.example.com/output.mp4"},
            "resolution" => "2K",
            "duration" => 5,
            "ratio" => "16:9"
          }
        }
      }

      {_req, updated} = VideoAPI.decode_response({req, resp})

      assert %Task{
               task_id: "task-1",
               status: :succeeded,
               url: "https://cdn.example.com/output.mp4",
               error: nil
             } = updated.body
    end

    test "query response yields a Task with error on failure" do
      req =
        Req.new(url: VideoAPI.query_path("task-2"))
        |> Req.Request.register_options([:model, :operation, :task_id])
        |> Req.Request.merge_options(
          model: "MiniMax-H3",
          operation: :video_query,
          task_id: "task-2"
        )

      resp = %Req.Response{
        status: 200,
        body: %{
          "task" => %{
            "id" => "task-2",
            "status" => "failed",
            "error" => %{"code" => "1026", "message" => "sensitive content"}
          }
        }
      }

      {_req, updated} = VideoAPI.decode_response({req, resp})

      assert %Task{task_id: "task-2", status: :failed, error: "1026: sensitive content"} =
               updated.body
    end

    test "query response maps running status" do
      req =
        Req.new(url: VideoAPI.query_path("task-3"))
        |> Req.Request.register_options([:model, :operation, :task_id])
        |> Req.Request.merge_options(
          model: "MiniMax-H3",
          operation: :video_query,
          task_id: "task-3"
        )

      resp = %Req.Response{
        status: 200,
        body: %{"task" => %{"id" => "task-3", "status" => "running"}}
      }

      {_req, updated} = VideoAPI.decode_response({req, resp})

      assert %Task{task_id: "task-3", status: :running, url: nil} = updated.body
    end

    test "200 response with OpenAI-style error body is surfaced" do
      req =
        Req.new(url: VideoAPI.path())
        |> Req.Request.register_options([:model, :operation])
        |> Req.Request.merge_options(model: "MiniMax-H3", operation: :video)

      resp = %Req.Response{
        status: 200,
        body: %{
          "type" => "error",
          "error" => %{
            "type" => "bad_request_error",
            "message" => "invalid params, content must include a non-empty text item (2013)",
            "http_code" => "400"
          }
        }
      }

      {_req, updated} = VideoAPI.decode_response({req, resp})

      assert %ReqLLM.Error.API.Response{} = updated
      assert updated.reason =~ "2013"
    end

    test "OpenAI-style error body is surfaced" do
      req =
        Req.new(url: VideoAPI.path())
        |> Req.Request.register_options([:model, :operation])
        |> Req.Request.merge_options(model: "MiniMax-H3", operation: :video)

      resp = %Req.Response{
        status: 400,
        body: %{
          "type" => "error",
          "error" => %{
            "type" => "bad_request_error",
            "message" => "content must include a non-empty text item (2013)",
            "http_code" => "400"
          }
        }
      }

      {_req, updated} = VideoAPI.decode_response({req, resp})

      assert %ReqLLM.Error.API.Response{} = updated
    end
  end

  describe "generate_video" do
    test "completes a MiniMax public API round trip" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2/video_generation"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]

        {:ok, request_body, conn} = Plug.Conn.read_body(conn)
        request_json = Jason.decode!(request_body)

        assert request_json["model"] == "MiniMax-H3"
        assert request_json["duration"] == 5
        assert request_json["resolution"] == "2K"
        assert request_json["ratio"] == "16:9"

        assert [%{"type" => "text", "text" => "A boy playing basketball by the sea"}] =
                 request_json["content"]

        Req.Test.json(conn, %{"task_id" => "424010985738629"})
      end)

      assert {:ok, %Task{task_id: "424010985738629", status: :queued}} =
               ReqLLM.Video.generate_video(
                 minimax_video_model(),
                 [prompt: "A boy playing basketball by the sea"],
                 duration: 5,
                 resolution: "2K",
                 ratio: "16:9",
                 api_key: "test-key",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end

    test "rejects a model that does not support video generation" do
      model = %LLMDB.Model{
        id: "MiniMax-M2.7",
        model: "MiniMax-M2.7",
        provider_model_id: "MiniMax-M2.7",
        provider: :minimax,
        name: "MiniMax-M2.7",
        family: "minimax-m2",
        capabilities: %{chat: true},
        limits: %{},
        extra: %{}
      }

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               ReqLLM.Video.generate_video(model, prompt: "A cat")
    end

    test "returns validation errors for malformed content and upload tuples" do
      model = minimax_video_model()

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               ReqLLM.Video.generate_video(model, ["not", "a", "keyword", "list"])

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               ReqLLM.Video.generate_video(
                 model,
                 prompt: "A cat",
                 first_frame_image: {:upload, :not_binary, "image/png"}
               )

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               ReqLLM.Video.generate_video(
                 model,
                 prompt: "A cat",
                 first_frame_image: {:file, :not_a_path}
               )
    end
  end

  describe "query_video" do
    test "completes a MiniMax query round trip" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v2/query/video_generation/task-1"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]

        Req.Test.json(conn, %{
          "task" => %{
            "id" => "task-1",
            "model" => "MiniMax-H3",
            "status" => "succeeded",
            "content" => %{"url" => "https://cdn.example.com/output.mp4"}
          }
        })
      end)

      assert {:ok, %Task{status: :succeeded, url: "https://cdn.example.com/output.mp4"}} =
               ReqLLM.Video.query_video(minimax_video_model(), "task-1",
                 api_key: "test-key",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end
  end

  describe "wait_video" do
    test "polls until the task succeeds" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/v2/query/video_generation/task-1"

        Req.Test.json(conn, %{
          "task" => %{
            "id" => "task-1",
            "status" => "succeeded",
            "content" => %{"url" => "https://cdn.example.com/output.mp4"}
          }
        })
      end)

      assert {:ok, %Task{status: :succeeded, url: "https://cdn.example.com/output.mp4"}} =
               ReqLLM.Video.wait_video(minimax_video_model(), "task-1",
                 api_key: "test-key",
                 poll_interval: 1,
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end

    test "returns the failed task with error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "task" => %{
            "id" => "task-2",
            "status" => "failed",
            "error" => %{"code" => "1026", "message" => "sensitive content"}
          }
        })
      end)

      assert {:ok, %Task{status: :failed, error: "1026: sensitive content"}} =
               ReqLLM.Video.wait_video(minimax_video_model(), "task-2",
                 api_key: "test-key",
                 poll_interval: 1,
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end

    test "retries transient query errors until the task succeeds" do
      counter = :counters.new(1, [])

      Req.Test.stub(__MODULE__, fn conn ->
        if :counters.get(counter, 1) < 4 do
          :counters.add(counter, 1, 1)
          Req.Test.transport_error(conn, :closed)
        else
          Req.Test.json(conn, %{
            "task" => %{
              "id" => "task-1",
              "status" => "succeeded",
              "content" => %{"url" => "https://cdn.example.com/output.mp4"}
            }
          })
        end
      end)

      assert {:ok, %Task{status: :succeeded, url: "https://cdn.example.com/output.mp4"}} =
               ReqLLM.Video.wait_video(minimax_video_model(), "task-1",
                 api_key: "test-key",
                 poll_interval: 1,
                 max_transient_retries: 3,
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end

    test "gives up after max_transient_retries on persistent transient errors" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :closed)
      end)

      assert {:error, %ReqLLM.Error.API.Request{cause: %Req.TransportError{reason: :closed}}} =
               ReqLLM.Video.wait_video(minimax_video_model(), "task-1",
                 api_key: "test-key",
                 poll_interval: 1,
                 max_transient_retries: 1,
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end

    test "times out when the task never reaches a terminal state" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "task" => %{"id" => "task-3", "status" => "running"}
        })
      end)

      assert {:error, %ReqLLM.Error.API.Timeout{timeout: 5}} =
               ReqLLM.Video.wait_video(minimax_video_model(), "task-3",
                 api_key: "test-key",
                 poll_interval: 1,
                 timeout: 5,
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end

    test "enforces the wait timeout while a query request is running" do
      Req.Test.stub(__MODULE__, fn conn ->
        Process.sleep(50)

        Req.Test.json(conn, %{
          "task" => %{"id" => "task-4", "status" => "succeeded"}
        })
      end)

      assert {:error, %ReqLLM.Error.API.Timeout{timeout: 10}} =
               ReqLLM.Video.wait_video(minimax_video_model(), "task-4",
                 api_key: "test-key",
                 poll_interval: 1,
                 timeout: 10,
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end
  end
end

defmodule ReqLLM.VideoGenerationV1Test do
  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Minimax

  alias ReqLLM.Providers.Minimax
  alias ReqLLM.Providers.Minimax.VideoAPIV1
  alias ReqLLM.Video.Task

  defp minimax_hailuo_model(model_id \\ "MiniMax-Hailuo-2.3") do
    %LLMDB.Model{
      id: model_id,
      model: model_id,
      provider_model_id: model_id,
      provider: :minimax,
      name: model_id,
      family: "minimax-hailuo",
      capabilities: %{video: true},
      limits: %{},
      extra: %{}
    }
  end

  describe "V1 API dispatch" do
    test "H3 models route to the V2 API driver" do
      model = %LLMDB.Model{
        id: "MiniMax-H3",
        model: "MiniMax-H3",
        provider_model_id: "MiniMax-H3",
        provider: :minimax,
        name: "MiniMax-H3",
        family: "minimax-h3",
        capabilities: %{video: true},
        limits: %{},
        extra: %{}
      }

      {:ok, request} =
        Minimax.prepare_request(:video, model, [prompt: "test"], api_key: "test-key")

      assert request.options[:api_mod] == ReqLLM.Providers.Minimax.VideoAPI
      assert request.url.path == "/v2/video_generation"
    end

    test "Hailuo models route to the V1 API driver" do
      model = minimax_hailuo_model()

      {:ok, request} =
        Minimax.prepare_request(:video, model, [prompt: "test"], api_key: "test-key")

      assert request.options[:api_mod] == VideoAPIV1
      assert request.url.path == "/video_generation"
      assert request.options[:base_url] == "https://api.minimax.io/v1"
    end
  end

  describe "V1 prepare_request" do
    test "creates /video_generation request with api_mod" do
      model = minimax_hailuo_model()

      {:ok, request} =
        Minimax.prepare_request(
          :video,
          model,
          [prompt: "A cat", first_frame_image: "https://example.com/cat.png"],
          duration: 6,
          resolution: "768P",
          api_key: "test-key"
        )

      assert %Req.Request{} = request
      assert request.url.path == "/video_generation"
      assert request.method == :post
      assert request.options[:api_mod] == VideoAPIV1
      assert request.options[:operation] == :video
    end

    test "accepts fast pretreatment and preserves the video prompt optimizer default" do
      model = minimax_hailuo_model()

      assert {:ok, request} =
               Minimax.prepare_request(:video, model, [prompt: "A cat"],
                 fast_pretreatment: true,
                 api_key: "test-key"
               )

      assert request.options[:fast_pretreatment] == true
      assert request.options[:prompt_optimizer] == true

      assert {:ok, request} =
               Minimax.prepare_request(:video, model, [prompt: "A cat"],
                 prompt_optimizer: false,
                 api_key: "test-key"
               )

      assert request.options[:prompt_optimizer] == false
    end

    test "creates query request with task_id as query param" do
      model = minimax_hailuo_model()

      {:ok, request} =
        Minimax.prepare_request(:video_query, model, "task-1", api_key: "test-key")

      assert request.url.path == "/query/video_generation"
      assert request.url.query == "task_id=task-1"
      assert request.method == :get
      assert request.options[:api_mod] == VideoAPIV1
    end

    test "creates file retrieve request" do
      model = minimax_hailuo_model()

      {:ok, request} =
        Minimax.prepare_request(:video_retrieve, model, "file-1", api_key: "test-key")

      assert request.url.path == "/files/retrieve"
      assert request.url.query == "file_id=file-1"
      assert request.method == :get
      assert request.options[:api_mod] == VideoAPIV1
      assert request.options[:operation] == :video_retrieve
    end
  end

  describe "V1 encode_body" do
    test "emits flat MiniMax V1 JSON" do
      request =
        Req.new(url: VideoAPIV1.path())
        |> Req.Request.register_options([
          :model,
          :content,
          :duration,
          :resolution,
          :prompt_optimizer,
          :fast_pretreatment,
          :operation
        ])
        |> Req.Request.merge_options(
          model: "MiniMax-Hailuo-2.3",
          content: [
            prompt: "A cat",
            first_frame_image: "https://example.com/cat.png",
            last_frame_image: "https://example.com/adult-cat.png"
          ],
          duration: 6,
          resolution: "768P",
          prompt_optimizer: true,
          fast_pretreatment: false,
          operation: :video
        )

      encoded = VideoAPIV1.encode_body(request)
      body = ReqLLM.Test.Helpers.json_body(encoded)

      assert body["model"] == "MiniMax-Hailuo-2.3"
      assert body["prompt"] == "A cat"
      assert body["first_frame_image"] == "https://example.com/cat.png"
      assert body["last_frame_image"] == "https://example.com/adult-cat.png"
      assert body["duration"] == 6
      assert body["resolution"] == "768P"
      assert body["prompt_optimizer"] == true
      assert body["fast_pretreatment"] == false
      refute Map.has_key?(body, "content")
    end

    test "query and retrieve requests carry no body" do
      for operation <- [:video_query, :video_retrieve] do
        request =
          Req.new(url: VideoAPIV1.path())
          |> Req.Request.register_options([:model, :operation])
          |> Req.Request.merge_options(model: "MiniMax-Hailuo-2.3", operation: operation)

        encoded = VideoAPIV1.encode_body(request)
        refute Map.has_key?(encoded.options, :json)
      end
    end
  end

  describe "V1 decode_response" do
    test "query response maps statuses and file_id" do
      req =
        Req.new(url: VideoAPIV1.query_path("task-1"))
        |> Req.Request.register_options([:model, :operation, :task_id])
        |> Req.Request.merge_options(
          model: "MiniMax-Hailuo-2.3",
          operation: :video_query,
          task_id: "task-1"
        )

      resp = %Req.Response{
        status: 200,
        body: %{
          "task_id" => "task-1",
          "status" => "Success",
          "file_id" => "file-1",
          "video_width" => 1920,
          "video_height" => 1080,
          "base_resp" => %{"status_code" => 0, "status_msg" => "success"}
        }
      }

      {_req, updated} = VideoAPIV1.decode_response({req, resp})

      assert %Task{
               task_id: "task-1",
               status: :succeeded,
               file_id: "file-1",
               url: nil
             } = updated.body
    end

    test "query response maps processing and fail statuses" do
      req =
        Req.new(url: VideoAPIV1.query_path("task-2"))
        |> Req.Request.register_options([:model, :operation, :task_id])
        |> Req.Request.merge_options(
          model: "MiniMax-Hailuo-2.3",
          operation: :video_query,
          task_id: "task-2"
        )

      for {wire_status, expected} <- [
            {"Processing", :running},
            {"Queueing", :queued},
            {"Fail", :failed}
          ] do
        resp = %Req.Response{
          status: 200,
          body: %{"task_id" => "task-2", "status" => wire_status}
        }

        {_req, updated} = VideoAPIV1.decode_response({req, resp})
        assert updated.body.status == expected
      end
    end

    test "query response with Fail status yields a failed Task with error" do
      req =
        Req.new(url: VideoAPIV1.query_path("task-4"))
        |> Req.Request.register_options([:model, :operation, :task_id])
        |> Req.Request.merge_options(
          model: "MiniMax-Hailuo-2.3",
          operation: :video_query,
          task_id: "task-4"
        )

      resp = %Req.Response{
        status: 200,
        body: %{
          "task_id" => "task-4",
          "status" => "Fail",
          "file_id" => "",
          "video_width" => 0,
          "video_height" => 0,
          "base_resp" => %{
            "status_code" => 2013,
            "status_msg" => "invalid params, first_frame_image"
          }
        }
      }

      {_req, updated} = VideoAPIV1.decode_response({req, resp})

      assert %Task{
               task_id: "task-4",
               status: :failed,
               error: "invalid params, first_frame_image"
             } = updated.body
    end

    test "retrieve response passes through download_url" do
      req =
        Req.new(url: VideoAPIV1.retrieve_path("file-1"))
        |> Req.Request.register_options([:model, :operation, :file_id])
        |> Req.Request.merge_options(
          model: "MiniMax-Hailuo-2.3",
          operation: :video_retrieve,
          file_id: "file-1"
        )

      resp = %Req.Response{
        status: 200,
        body: %{
          "base_resp" => %{"status_code" => 0, "status_msg" => "success"},
          "file" => %{
            "file_id" => "file-1",
            "bytes" => 1024,
            "download_url" => "https://cdn.example.com/video.mp4",
            "filename" => "output.mp4",
            "purpose" => "video_generation"
          }
        }
      }

      {_req, updated} = VideoAPIV1.decode_response({req, resp})

      assert %ReqLLM.Video.File{
               file_id: "file-1",
               url: "https://cdn.example.com/video.mp4",
               filename: "output.mp4",
               bytes: 1024,
               purpose: "video_generation"
             } = updated.body
    end

    test "base_resp error is surfaced" do
      req =
        Req.new(url: VideoAPIV1.path())
        |> Req.Request.register_options([:model, :operation])
        |> Req.Request.merge_options(model: "MiniMax-Hailuo-2.3", operation: :video)

      resp = %Req.Response{
        status: 200,
        body: %{
          "base_resp" => %{"status_code" => 1004, "status_msg" => "auth failed"}
        }
      }

      {_req, updated} = VideoAPIV1.decode_response({req, resp})

      assert %ReqLLM.Error.API.Response{} = updated
    end
  end

  describe "V1 upload" do
    test "upload_file completes a multipart round trip" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/files/upload"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "video_generation_input"
        assert body =~ "cat.png"
        assert body =~ "fake-image-bytes"

        Req.Test.json(conn, %{
          "file" => %{
            "file_id" => 42_921_536_529_229,
            "bytes" => 17,
            "created_at" => 1_786_341_878,
            "filename" => "cat.png",
            "purpose" => "video_generation_input"
          },
          "base_resp" => %{"status_code" => 0, "status_msg" => "success"}
        })
      end)

      model = minimax_hailuo_model()

      assert {:ok, %ReqLLM.Video.File{file_id: 42_921_536_529_229, filename: "cat.png"}} =
               ReqLLM.Video.upload_file(model, "fake-image-bytes",
                 filename: "cat.png",
                 media_type: "image/png",
                 api_key: "test-key",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end

    test "upload filename derives extension from media_type" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ ~s(filename="input.jpg")

        Req.Test.json(conn, %{
          "file" => %{
            "file_id" => 789,
            "bytes" => 17,
            "filename" => "input.jpg",
            "purpose" => "video_generation_input"
          },
          "base_resp" => %{"status_code" => 0, "status_msg" => "success"}
        })
      end)

      model = minimax_hailuo_model()

      assert {:ok, %ReqLLM.Video.File{file_id: 789}} =
               ReqLLM.Video.upload_file(model, "fake-image-bytes",
                 media_type: "image/jpeg",
                 api_key: "test-key",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end

    test "generate_video inlines {:upload, binary, media_type} as a data URL for V1" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/video_generation"

        {:ok, request_body, conn} = Plug.Conn.read_body(conn)
        request_json = Jason.decode!(request_body)

        assert request_json["first_frame_image"] ==
                 "data:image/png;base64," <> Base.encode64("fake-image-bytes")

        Req.Test.json(conn, %{
          "task_id" => "task-1",
          "base_resp" => %{"status_code" => 0, "status_msg" => "success"}
        })
      end)

      model = minimax_hailuo_model()

      assert {:ok, %Task{task_id: "task-1"}} =
               ReqLLM.Video.generate_video(
                 model,
                 [
                   prompt: "A cat",
                   first_frame_image: {:upload, "fake-image-bytes", "image/png"}
                 ],
                 duration: 6,
                 resolution: "768P",
                 api_key: "test-key",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end

    test "generate_video inlines {:file, path} as a data URL for V1" do
      path = Path.join(System.tmp_dir!(), "req_llm_upload_test.png")
      File.write!(path, "fake-image-bytes")

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/video_generation"

        {:ok, request_body, conn} = Plug.Conn.read_body(conn)
        request_json = Jason.decode!(request_body)

        assert request_json["first_frame_image"] ==
                 "data:image/png;base64," <> Base.encode64("fake-image-bytes")

        Req.Test.json(conn, %{
          "task_id" => "task-2",
          "base_resp" => %{"status_code" => 0, "status_msg" => "success"}
        })
      end)

      model = minimax_hailuo_model()

      assert {:ok, %Task{task_id: "task-2"}} =
               ReqLLM.Video.generate_video(
                 model,
                 [prompt: "A cat", first_frame_image: {:file, path}],
                 duration: 6,
                 resolution: "768P",
                 api_key: "test-key",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )

      File.rm!(path)
    end
  end

  describe "upload content validation" do
    test "rejects {:upload, binary, media_type} with non-binary media_type" do
      model = %LLMDB.Model{
        id: "MiniMax-H3",
        model: "MiniMax-H3",
        provider_model_id: "MiniMax-H3",
        provider: :minimax,
        name: "MiniMax-H3",
        family: "minimax-h3",
        capabilities: %{video: true},
        limits: %{},
        extra: %{}
      }

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               ReqLLM.Video.generate_video(
                 model,
                 [prompt: "A cat", first_frame_image: {:upload, "bytes", nil}],
                 duration: 5,
                 resolution: "2K",
                 api_key: "test-key"
               )
    end
  end

  describe "V2 auto-upload" do
    test "generate_video uploads {:upload, ...} and references mm_file:// for H3" do
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/v1/files/upload"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert body =~ "video_generation_input"
            assert body =~ "fake-image-bytes"

            Req.Test.json(conn, %{
              "file" => %{
                "file_id" => 123,
                "bytes" => 17,
                "filename" => "input.jpg",
                "purpose" => "video_generation_input"
              },
              "base_resp" => %{"status_code" => 0, "status_msg" => "success"}
            })

          {"POST", "/v2/video_generation"} ->
            {:ok, request_body, conn} = Plug.Conn.read_body(conn)
            request_json = Jason.decode!(request_body)

            assert [%{"type" => "text"}, %{"type" => "image_url"}] =
                     request_json["content"]

            assert get_in(request_json, ["content", Access.at(1), "image_url", "url"]) ==
                     "mm_file://123"

            Req.Test.json(conn, %{"task_id" => "task-1"})
        end
      end)

      model = %LLMDB.Model{
        id: "MiniMax-H3",
        model: "MiniMax-H3",
        provider_model_id: "MiniMax-H3",
        provider: :minimax,
        name: "MiniMax-H3",
        family: "minimax-h3",
        capabilities: %{video: true},
        limits: %{},
        extra: %{}
      }

      assert {:ok, %Task{task_id: "task-1"}} =
               ReqLLM.Video.generate_video(
                 model,
                 [
                   prompt: "A cat",
                   first_frame_image: {:upload, "fake-image-bytes", "image/jpeg"}
                 ],
                 duration: 5,
                 resolution: "2K",
                 api_key: "test-key",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end

    test "uploads private media inside reference lists" do
      upload_counter = :counters.new(1, [])

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/v1/files/upload"} ->
            :counters.add(upload_counter, 1, 1)
            file_id = :counters.get(upload_counter, 1)

            Req.Test.json(conn, %{
              "file" => %{
                "file_id" => file_id,
                "bytes" => 17,
                "filename" => "input.jpg",
                "purpose" => "video_generation_input"
              },
              "base_resp" => %{"status_code" => 0, "status_msg" => "success"}
            })

          {"POST", "/v2/video_generation"} ->
            {:ok, request_body, conn} = Plug.Conn.read_body(conn)
            request_json = Jason.decode!(request_body)

            assert [
                     %{"type" => "text"},
                     %{"image_url" => %{"url" => "mm_file://1"}},
                     %{"image_url" => %{"url" => "mm_file://2"}}
                   ] = request_json["content"]

            Req.Test.json(conn, %{"task_id" => "task-list"})
        end
      end)

      model = %LLMDB.Model{
        id: "MiniMax-H3",
        model: "MiniMax-H3",
        provider_model_id: "MiniMax-H3",
        provider: :minimax,
        name: "MiniMax-H3",
        family: "minimax-h3",
        capabilities: %{video: true},
        limits: %{},
        extra: %{}
      }

      assert {:ok, %Task{task_id: "task-list"}} =
               ReqLLM.Video.generate_video(
                 model,
                 [
                   prompt: "A cat",
                   reference_images: [
                     {:upload, "first-image", "image/jpeg"},
                     {:upload, "second-image", "image/jpeg"}
                   ]
                 ],
                 api_key: "test-key",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end
  end

  describe "V1 round trip" do
    test "generate, query, and retrieve complete a full flow" do
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/v1/video_generation"} ->
            assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]

            {:ok, request_body, conn} = Plug.Conn.read_body(conn)
            request_json = Jason.decode!(request_body)

            assert request_json["model"] == "MiniMax-Hailuo-2.3"
            assert request_json["prompt"] == "A cat"
            assert request_json["first_frame_image"] == "https://example.com/cat.png"

            Req.Test.json(conn, %{
              "task_id" => "task-1",
              "base_resp" => %{"status_code" => 0, "status_msg" => "success"}
            })

          {"GET", "/v1/query/video_generation"} ->
            assert conn.query_string == "task_id=task-1"

            Req.Test.json(conn, %{
              "task_id" => "task-1",
              "status" => "Success",
              "file_id" => "file-1",
              "base_resp" => %{"status_code" => 0, "status_msg" => "success"}
            })

          {"GET", "/v1/files/retrieve"} ->
            assert conn.query_string == "file_id=file-1"

            Req.Test.json(conn, %{
              "base_resp" => %{"status_code" => 0, "status_msg" => "success"},
              "file" => %{
                "file_id" => "file-1",
                "bytes" => 1024,
                "download_url" => "https://cdn.example.com/video.mp4",
                "filename" => "output.mp4",
                "purpose" => "video_generation"
              }
            })
        end
      end)

      model = minimax_hailuo_model()

      assert {:ok, %Task{task_id: "task-1"}} =
               ReqLLM.Video.generate_video(
                 model,
                 [prompt: "A cat", first_frame_image: "https://example.com/cat.png"],
                 duration: 6,
                 resolution: "768P",
                 api_key: "test-key",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )

      assert {:ok, %Task{status: :succeeded, file_id: "file-1"}} =
               ReqLLM.Video.query_video(model, "task-1",
                 api_key: "test-key",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )

      assert {:ok, %ReqLLM.Video.File{url: "https://cdn.example.com/video.mp4"}} =
               ReqLLM.Video.retrieve_file(model, "file-1",
                 api_key: "test-key",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )
    end
  end
end

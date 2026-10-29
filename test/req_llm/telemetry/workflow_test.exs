defmodule ReqLLM.WorkflowTelemetryTest do
  use ExUnit.Case, async: false

  @moduletag contract: :public_api
  @video_model %{provider: :minimax, id: "MiniMax-H3", capabilities: %{video: true}}
  @v1_model %{provider: :minimax, id: "MiniMax-Hailuo-2.3", capabilities: %{video: true}}

  setup do
    owner = self()
    handler = "workflow-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [[:req_llm, :request, :start], [:req_llm, :request, :stop]],
        fn event, measurements, metadata, _config ->
          send(owner, {:event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  for {operation, provider} <- [
        {:rerank, :cohere},
        {:compact, :openai},
        {:video, :minimax},
        {:video_query, :minimax},
        {:video_upload, :minimax},
        {:video_retrieve, :minimax}
      ] do
    @operation operation
    @provider provider

    test "#{operation} preserves lifecycle events, measurements and request correlation" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, response_body(@operation)) end)
      opts = [api_key: "test-key", req_http_options: [plug: {Req.Test, __MODULE__}]]

      assert {:ok, _result} = call(@operation, opts)

      assert_receive {:event, [:req_llm, :request, :start], start_measurements, start_meta}
      assert_receive {:event, [:req_llm, :request, :stop], stop_measurements, stop_meta}
      assert %{system_time: start_time} = start_measurements
      assert is_integer(start_time)
      assert Enum.sort(Map.keys(start_measurements)) == [:system_time]
      assert %{duration: duration, system_time: stop_time} = stop_measurements
      assert is_integer(duration) and duration >= 0
      assert is_integer(stop_time)
      assert Enum.sort(Map.keys(stop_measurements)) == [:duration, :system_time]
      assert start_meta.operation == @operation
      assert start_meta.provider == @provider
      assert start_meta.transport == :req
      assert start_meta.mode == :sync
      assert stop_meta.request_id == start_meta.request_id
      assert stop_meta.operation == @operation
      assert stop_meta.provider == @provider
      assert stop_meta.http_status == 200
      refute_received {:event, _, _, _}
    end
  end

  test "video wait preserves per-poll lifecycle events and shared request correlation" do
    Req.Test.verify_on_exit!()

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"task" => %{"id" => "task-1", "status" => "running"}})
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      Req.Test.json(conn, response_body(:video_query))
    end)

    opts = [
      api_key: "test-key",
      req_http_options: [plug: {Req.Test, __MODULE__}],
      poll_interval: 1,
      timeout: 1_000
    ]

    assert {:ok, %ReqLLM.Video.Task{task_id: "task-1", status: :succeeded}} =
             ReqLLM.Video.wait_video(@video_model, "task-1", opts)

    [first_request_id, second_request_id] =
      for _poll <- 1..2 do
        assert_receive {:event, [:req_llm, :request, :start], start_measurements, start_meta}
        assert_receive {:event, [:req_llm, :request, :stop], stop_measurements, stop_meta}
        assert %{system_time: start_time} = start_measurements
        assert is_integer(start_time)
        assert Enum.sort(Map.keys(start_measurements)) == [:system_time]
        assert %{duration: duration, system_time: stop_time} = stop_measurements
        assert is_integer(duration) and duration >= 0
        assert is_integer(stop_time)
        assert Enum.sort(Map.keys(stop_measurements)) == [:duration, :system_time]

        assert %{
                 operation: :video_query,
                 provider: :minimax,
                 transport: :req,
                 mode: :sync,
                 request_id: request_id
               } = start_meta

        assert %{
                 operation: :video_query,
                 provider: :minimax,
                 transport: :req,
                 mode: :sync,
                 http_status: 200,
                 request_id: ^request_id
               } = stop_meta

        request_id
      end

    assert second_request_id == first_request_id
    refute_received {:event, _, _, _}
  end

  defp call(:rerank, opts) do
    ReqLLM.rerank("cohere:rerank-v3.5", [query: "rank", documents: ["one"]] ++ opts)
  end

  defp call(:compact, opts), do: ReqLLM.compact_context("openai:gpt-5.4", "Hello", opts)
  defp call(:video, opts), do: ReqLLM.Video.generate_video(@video_model, [prompt: "A cat"], opts)
  defp call(:video_query, opts), do: ReqLLM.Video.query_video(@video_model, "task-1", opts)
  defp call(:video_upload, opts), do: ReqLLM.Video.upload_file(@video_model, "bytes", opts)
  defp call(:video_retrieve, opts), do: ReqLLM.Video.retrieve_file(@v1_model, 42, opts)

  defp response_body(:rerank) do
    %{"id" => "rerank_1", "results" => [%{"index" => 0, "relevance_score" => 0.9}]}
  end

  defp response_body(:compact) do
    %{
      "id" => "cmp_1",
      "output" => [%{"type" => "compaction", "id" => "cmp_item", "encrypted_content" => "opaque"}]
    }
  end

  defp response_body(:video), do: %{"task_id" => "task-1"}

  defp response_body(:video_query) do
    %{"task" => %{"id" => "task-1", "status" => "succeeded"}}
  end

  defp response_body(operation) when operation in [:video_upload, :video_retrieve] do
    %{
      "file" => %{
        "file_id" => 42,
        "bytes" => 5,
        "filename" => "frame.png",
        "purpose" => "video_generation_input",
        "download_url" => "https://video.example/output.mp4"
      },
      "base_resp" => %{"status_code" => 0, "status_msg" => "success"}
    }
  end
end

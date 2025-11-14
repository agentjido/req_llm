defmodule ReqLLM.Test.VCRTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Test.ChunkCollector
  alias ReqLLM.Test.Transcript
  alias ReqLLM.Test.VCR

  @fixture_dir "tmp/vcr_test"

  setup do
    File.rm_rf(@fixture_dir)
    File.mkdir_p!(@fixture_dir)
    :ok
  end

  describe "record/2 with collector (streaming)" do
    test "records from ChunkCollector" do
      {:ok, collector} = ChunkCollector.start_link()
      ChunkCollector.add_chunk(collector, "data: chunk1\n\n")
      ChunkCollector.add_chunk(collector, "data: chunk2\n\n")

      path = Path.join(@fixture_dir, "streaming.json")

      assert :ok =
               VCR.record(path,
                 provider: :openai,
                 model: "gpt-4",
                 request: %{
                   method: "POST",
                   url: "https://api.openai.com/v1/chat/completions",
                   headers: [{"authorization", "Bearer sk-test"}],
                   canonical_json: %{"model" => "gpt-4"}
                 },
                 response: %{status: 200, headers: [{"content-type", "text/event-stream"}]},
                 collector: collector
               )

      assert File.exists?(path)
      {:ok, transcript} = VCR.load(path)

      assert transcript.provider == :openai
      assert transcript.model_spec == "openai:gpt-4"
      assert Transcript.streaming?(transcript)
      assert length(Transcript.data_chunks(transcript)) == 2
    end

    test "sanitizes API keys in headers" do
      {:ok, collector} = ChunkCollector.start_link()
      ChunkCollector.add_chunk(collector, "chunk")

      path = Path.join(@fixture_dir, "sanitized.json")

      :ok =
        VCR.record(path,
          provider: :anthropic,
          model: "claude-3",
          request: %{
            method: "POST",
            url: "https://api.anthropic.com/v1/messages",
            headers: [{"x-api-key", "sk-ant-secret123"}],
            canonical_json: %{}
          },
          response: %{status: 200, headers: []},
          collector: collector
        )

      json = File.read!(path)
      refute String.contains?(json, "sk-ant-secret123")
      assert String.contains?(json, "[REDACTED:")
    end
  end

  describe "record/2 with body (non-streaming)" do
    test "records from binary body" do
      path = Path.join(@fixture_dir, "non_streaming.json")
      body = ~s({"choices":[{"message":{"content":"Hello"}}],"id":"chatcmpl-123"})

      assert :ok =
               VCR.record(path,
                 provider: :openai,
                 model: "gpt-4",
                 request: %{
                   method: "POST",
                   url: "https://api.openai.com/v1/chat/completions",
                   headers: [],
                   canonical_json: %{}
                 },
                 response: %{status: 200, headers: []},
                 body: body
               )

      assert File.exists?(path)
      {:ok, transcript} = VCR.load(path)

      refute Transcript.streaming?(transcript)
      assert VCR.replay_body(transcript) == body
    end
  end

  describe "record/2 validation" do
    test "requires either collector or body" do
      path = Path.join(@fixture_dir, "invalid.json")

      result =
        VCR.record(path,
          provider: :openai,
          model: "gpt-4",
          request: %{method: "POST", url: "...", headers: [], canonical_json: %{}},
          response: %{status: 200, headers: []}
        )

      assert {:error, %ArgumentError{message: message}} = result
      assert message =~ "must provide either :collector or :body"
    end

    test "rejects both collector and body" do
      {:ok, collector} = ChunkCollector.start_link()
      path = Path.join(@fixture_dir, "invalid.json")

      result =
        VCR.record(path,
          provider: :openai,
          model: "gpt-4",
          request: %{method: "POST", url: "...", headers: [], canonical_json: %{}},
          response: %{status: 200, headers: []},
          collector: collector,
          body: "data"
        )

      assert {:error, %ArgumentError{message: message}} = result
      assert message =~ "cannot provide both :collector and :body"

      ChunkCollector.stop(collector)
    end

    test "validates transcript structure" do
      {:ok, collector} = ChunkCollector.start_link()
      path = Path.join(@fixture_dir, "invalid_request.json")

      result =
        VCR.record(path,
          provider: :openai,
          model: "gpt-4",
          request: %{},
          response: %{status: 200, headers: []},
          collector: collector
        )

      assert {:error, {:validation_failed, _}} = result
    end
  end

  describe "load/1 and load!/1" do
    test "loads existing fixture" do
      path = Path.join(@fixture_dir, "loadable.json")

      :ok =
        VCR.record(path,
          provider: :openai,
          model: "gpt-4",
          request: %{
            method: "POST",
            url: "https://api.openai.com/v1/chat/completions",
            headers: [],
            canonical_json: %{}
          },
          response: %{status: 200, headers: []},
          body: "test body"
        )

      assert {:ok, %Transcript{}} = VCR.load(path)
      assert %Transcript{} = VCR.load!(path)
    end

    test "returns error for missing file" do
      assert {:error, _} = VCR.load("nonexistent.json")
    end

    test "raises for missing file with load!" do
      assert_raise ArgumentError, ~r/Fixture file not found/, fn ->
        VCR.load!("nonexistent.json")
      end
    end
  end

  describe "replay_body/1" do
    test "concatenates all data chunks" do
      {:ok, collector} = ChunkCollector.start_link()
      ChunkCollector.add_chunk(collector, "Hello ")
      ChunkCollector.add_chunk(collector, "world")
      ChunkCollector.add_chunk(collector, "!")

      path = Path.join(@fixture_dir, "concat.json")

      :ok =
        VCR.record(path,
          provider: :openai,
          model: "gpt-4",
          request: %{
            method: "POST",
            url: "https://api.openai.com/v1/chat/completions",
            headers: [],
            canonical_json: %{}
          },
          response: %{status: 200, headers: []},
          collector: collector
        )

      transcript = VCR.load!(path)
      assert VCR.replay_body(transcript) == "Hello world!"
    end

    test "returns full body for non-streaming" do
      path = Path.join(@fixture_dir, "body.json")
      body = "Complete response body"

      :ok =
        VCR.record(path,
          provider: :openai,
          model: "gpt-4",
          request: %{
            method: "POST",
            url: "https://api.openai.com/v1/chat/completions",
            headers: [],
            canonical_json: %{}
          },
          response: %{status: 200, headers: []},
          body: body
        )

      transcript = VCR.load!(path)
      assert VCR.replay_body(transcript) == body
    end
  end

  describe "replay_stream/1" do
    test "streams data chunks in order" do
      {:ok, collector} = ChunkCollector.start_link()
      ChunkCollector.add_chunk(collector, "chunk1")
      ChunkCollector.add_chunk(collector, "chunk2")
      ChunkCollector.add_chunk(collector, "chunk3")

      path = Path.join(@fixture_dir, "stream.json")

      :ok =
        VCR.record(path,
          provider: :openai,
          model: "gpt-4",
          request: %{
            method: "POST",
            url: "https://api.openai.com/v1/chat/completions",
            headers: [],
            canonical_json: %{}
          },
          response: %{status: 200, headers: []},
          collector: collector
        )

      transcript = VCR.load!(path)
      stream = VCR.replay_stream(transcript)

      chunks = Enum.to_list(stream)
      assert chunks == ["chunk1", "chunk2", "chunk3"]
    end

    test "can be consumed multiple times" do
      path = Path.join(@fixture_dir, "replayable.json")

      :ok =
        VCR.record(path,
          provider: :openai,
          model: "gpt-4",
          request: %{
            method: "POST",
            url: "https://api.openai.com/v1/chat/completions",
            headers: [],
            canonical_json: %{}
          },
          response: %{status: 200, headers: []},
          body: "data"
        )

      transcript = VCR.load!(path)
      stream = VCR.replay_stream(transcript)

      assert Enum.to_list(stream) == ["data"]
      assert Enum.to_list(stream) == ["data"]
    end
  end

  describe "status/1" do
    test "extracts status code from transcript" do
      path = Path.join(@fixture_dir, "status.json")

      :ok =
        VCR.record(path,
          provider: :openai,
          model: "gpt-4",
          request: %{
            method: "POST",
            url: "https://api.openai.com/v1/chat/completions",
            headers: [],
            canonical_json: %{}
          },
          response: %{status: 201, headers: []},
          body: "ok"
        )

      transcript = VCR.load!(path)
      assert VCR.status(transcript) == 201
    end
  end

  describe "headers/1" do
    test "extracts headers from transcript" do
      path = Path.join(@fixture_dir, "headers.json")

      :ok =
        VCR.record(path,
          provider: :openai,
          model: "gpt-4",
          request: %{
            method: "POST",
            url: "https://api.openai.com/v1/chat/completions",
            headers: [],
            canonical_json: %{}
          },
          response: %{
            status: 200,
            headers: [{"content-type", "application/json"}, {"x-request-id", "123"}]
          },
          body: "ok"
        )

      transcript = VCR.load!(path)
      headers = VCR.headers(transcript)

      assert {"content-type", "application/json"} in headers
      assert {"x-request-id", "123"} in headers
    end

    test "returns empty list when no headers" do
      path = Path.join(@fixture_dir, "no_headers.json")

      :ok =
        VCR.record(path,
          provider: :openai,
          model: "gpt-4",
          request: %{
            method: "POST",
            url: "https://api.openai.com/v1/chat/completions",
            headers: [],
            canonical_json: %{}
          },
          response: %{status: 200, headers: []},
          body: "ok"
        )

      transcript = VCR.load!(path)
      assert VCR.headers(transcript) == []
    end
  end

  describe "directory creation" do
    test "creates nested directories automatically" do
      path = Path.join([@fixture_dir, "deep", "nested", "path", "fixture.json"])

      :ok =
        VCR.record(path,
          provider: :openai,
          model: "gpt-4",
          request: %{
            method: "POST",
            url: "https://api.openai.com/v1/chat/completions",
            headers: [],
            canonical_json: %{}
          },
          response: %{status: 200, headers: []},
          body: "test"
        )

      assert File.exists?(path)
    end
  end

  describe "round-trip consistency" do
    test "streaming: record then replay preserves data" do
      {:ok, collector} = ChunkCollector.start_link()
      original_chunks = ["data: first\n\n", "data: second\n\n", "data: third\n\n"]

      Enum.each(original_chunks, &ChunkCollector.add_chunk(collector, &1))

      path = Path.join(@fixture_dir, "roundtrip_stream.json")

      :ok =
        VCR.record(path,
          provider: :anthropic,
          model: "claude-3-sonnet",
          request: %{
            method: "POST",
            url: "https://api.anthropic.com/v1/messages",
            headers: [],
            canonical_json: %{}
          },
          response: %{status: 200, headers: []},
          collector: collector
        )

      transcript = VCR.load!(path)
      replayed = Enum.to_list(VCR.replay_stream(transcript))

      assert replayed == original_chunks
    end

    test "non-streaming: record then replay preserves data" do
      original_body = ~s({"data":[1,2,3],"result":"success"})
      path = Path.join(@fixture_dir, "roundtrip_body.json")

      :ok =
        VCR.record(path,
          provider: :openai,
          model: "gpt-4",
          request: %{
            method: "POST",
            url: "https://api.openai.com/v1/chat/completions",
            headers: [],
            canonical_json: %{}
          },
          response: %{status: 200, headers: []},
          body: original_body
        )

      transcript = VCR.load!(path)
      assert VCR.replay_body(transcript) == original_body
    end
  end
end

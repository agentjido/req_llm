defmodule ReqLLM.Test.TranscriptTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Test.Transcript

  describe "Transcript.new/1" do
    test "creates transcript with all required fields" do
      transcript =
        Transcript.new(
          provider: :anthropic,
          model_spec: "anthropic:claude-3-haiku-20240307",
          captured_at: DateTime.utc_now(),
          request: %{
            method: "POST",
            url: "https://api.anthropic.com/v1/messages",
            headers: [{"content-type", "application/json"}],
            canonical_json: %{"model" => "claude-3-haiku-20240307"}
          },
          response_meta: %{
            status: 200,
            headers: [{"content-type", "application/json"}]
          },
          events: [
            {:status, 200},
            {:headers, [{"content-type", "application/json"}]},
            {:data, ~s({"content": "Hello"})},
            {:done, :ok}
          ]
        )

      assert transcript.provider == :anthropic
      assert transcript.model_spec == "anthropic:claude-3-haiku-20240307"
      assert length(transcript.events) == 4
    end
  end

  describe "Transcript.validate/1" do
    test "validates correct transcript" do
      transcript = valid_transcript()
      assert :ok = Transcript.validate(transcript)
    end

    test "rejects invalid provider" do
      transcript = %{valid_transcript() | provider: "not_atom"}
      assert {:error, msg} = Transcript.validate(transcript)
      assert msg =~ "provider must be an atom"
    end

    test "rejects empty model_spec" do
      transcript = %{valid_transcript() | model_spec: ""}
      assert {:error, msg} = Transcript.validate(transcript)
      assert msg =~ "model_spec"
    end

    test "rejects missing request fields" do
      transcript = %{valid_transcript() | request: %{method: "POST"}}
      assert {:error, msg} = Transcript.validate(transcript)
      assert msg =~ "request missing"
    end

    test "rejects invalid event types" do
      transcript = %{valid_transcript() | events: [{:invalid, "data"}]}
      assert {:error, msg} = Transcript.validate(transcript)
      assert msg =~ "invalid event types"
    end
  end

  describe "Transcript.streaming?/1" do
    test "returns false for single data event" do
      transcript = %{
        valid_transcript()
        | events: [
            {:status, 200},
            {:data, "single chunk"},
            {:done, :ok}
          ]
      }

      refute Transcript.streaming?(transcript)
    end

    test "returns true for multiple data events" do
      transcript = %{
        valid_transcript()
        | events: [
            {:status, 200},
            {:data, "chunk 1"},
            {:data, "chunk 2"},
            {:done, :ok}
          ]
      }

      assert Transcript.streaming?(transcript)
    end
  end

  describe "Transcript.data_chunks/1" do
    test "extracts all data chunks in order" do
      transcript = %{
        valid_transcript()
        | events: [
            {:status, 200},
            {:data, "first"},
            {:headers, []},
            {:data, "second"},
            {:data, "third"},
            {:done, :ok}
          ]
      }

      assert ["first", "second", "third"] = Transcript.data_chunks(transcript)
    end
  end

  describe "Transcript.joined_data/1" do
    test "concatenates all data chunks" do
      transcript = %{
        valid_transcript()
        | events: [
            {:status, 200},
            {:data, "Hello "},
            {:data, "world"},
            {:done, :ok}
          ]
      }

      assert "Hello world" = Transcript.joined_data(transcript)
    end
  end

  describe "JSON encoding/decoding" do
    test "round-trip preserves transcript" do
      original = valid_transcript()

      json = Transcript.to_json(original)
      decoded = Transcript.from_json!(json)

      assert decoded.provider == original.provider
      assert decoded.model_spec == original.model_spec
      assert decoded.events == original.events
    end

    test "write! and read! round-trip via filesystem" do
      original = valid_transcript()
      path = Path.join(System.tmp_dir!(), "test-transcript-#{:rand.uniform(10_000)}.json")

      try do
        Transcript.write!(original, path)
        assert File.exists?(path)

        loaded = Transcript.read!(path)
        assert loaded.provider == original.provider
        assert loaded.model_spec == original.model_spec
        assert loaded.events == original.events
      after
        File.rm(path)
      end
    end

    test "sanitizes sensitive headers" do
      transcript = %{
        valid_transcript()
        | request: %{
            method: "POST",
            url: "https://api.anthropic.com/v1/messages",
            headers: [
              {"authorization", "Bearer sk-secret-key"},
              {"x-api-key", "my-api-key"}
            ],
            canonical_json: %{}
          }
      }

      json_map = Transcript.to_map(transcript)
      headers = json_map["request"]["headers"]

      assert is_map(headers)
      assert headers["authorization"] =~ "REDACTED"
      assert headers["x-api-key"] =~ "REDACTED"
    end

    test "sanitizes sensitive JSON fields" do
      transcript = %{
        valid_transcript()
        | request: %{
            method: "POST",
            url: "https://api.anthropic.com/v1/messages",
            headers: [],
            canonical_json: %{
              "api_key" => "secret",
              "model" => "claude-3-haiku-20240307"
            }
          }
      }

      json_map = Transcript.to_map(transcript)
      canonical = json_map["request"]["canonical_json"]

      assert canonical["api_key"] =~ "REDACTED"
      assert canonical["model"] == "claude-3-haiku-20240307"
    end

    test "sanitizes sensitive URL query parameters" do
      transcript = %{
        valid_transcript()
        | request: %{
            method: "POST",
            url:
              "https://generativelanguage.googleapis.com/v1beta/models/gemini:generateContent?key=AIzaSyA8A-ZQ8x7fImehoOYbWtuHelAYzGjH-bw",
            headers: [],
            canonical_json: %{}
          }
      }

      json_map = Transcript.to_map(transcript)
      url = json_map["request"]["url"]

      assert url =~ "key=[REDACTED]"
      refute url =~ "AIzaSyA8A-ZQ8x7fImehoOYbWtuHelAYzGjH-bw"
    end

    test "sanitizes multiple URL query parameters" do
      transcript = %{
        valid_transcript()
        | request: %{
            method: "POST",
            url:
              "https://api.example.com/endpoint?api_key=secret123&model=gpt-4&token=abc&other=value",
            headers: [],
            canonical_json: %{}
          }
      }

      json_map = Transcript.to_map(transcript)
      url = json_map["request"]["url"]

      assert url =~ "api_key=[REDACTED]"
      assert url =~ "token=[REDACTED]"
      assert url =~ "model=gpt-4"
      assert url =~ "other=value"
      refute url =~ "secret123"
      refute url =~ "abc"
    end
  end

  defp valid_transcript do
    Transcript.new(
      provider: :anthropic,
      model_spec: "anthropic:claude-3-haiku-20240307",
      captured_at: DateTime.utc_now(),
      request: %{
        method: "POST",
        url: "https://api.anthropic.com/v1/messages",
        headers: [{"content-type", "application/json"}],
        canonical_json: %{"model" => "claude-3-haiku-20240307"}
      },
      response_meta: %{
        status: 200,
        headers: [{"content-type", "application/json"}]
      },
      events: [
        {:status, 200},
        {:headers, [{"content-type", "application/json"}]},
        {:data, ~s({"content":"Hello"})},
        {:done, :ok}
      ]
    )
  end
end

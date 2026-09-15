defmodule ReqLLM.Providers.OpenAICodex.TurnMetadataTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Providers.OpenAICodex.TurnMetadata

  defp metadata do
    %{
      turn_id: "turn",
      window_id: "window",
      request_kind: "compaction",
      turn_started_at_unix_ms: 123
    }
  end

  test "normalizes atom and string keys without inventing optional identity" do
    {:ok, normalized} = TurnMetadata.validate(metadata())
    assert {:ok, ^normalized} = TurnMetadata.validate(normalized)
    refute Map.has_key?(normalized, "installation_id")
    opts = [session_id: "session", thread_id: "thread", codex_turn_metadata: normalized]
    body = TurnMetadata.put_body(%{}, opts)
    refute Map.has_key?(body["client_metadata"], "x-codex-installation-id")

    assert Jason.decode!(body["client_metadata"]["x-codex-turn-metadata"])["request_kind"] ==
             "compaction"
  end

  test "rejects malformed, ambiguous, oversized and unsafe metadata" do
    for invalid <- [
          nil,
          [],
          %{},
          Map.delete(metadata(), :turn_id),
          Map.put(metadata(), :turn_id, ""),
          Map.put(metadata(), :turn_id, "turn\r\nsecret: value"),
          Map.put(metadata(), :window_id, String.duplicate("x", 257)),
          Map.put(metadata(), :turn_started_at_unix_ms, -1),
          Map.put(metadata(), :turn_started_at_unix_ms, "123"),
          Map.put(metadata(), :unknown, "secret"),
          Map.put(metadata(), "turn_id", "other")
        ] do
      assert {:error, _} = TurnMetadata.validate(invalid)
    end
  end

  test "requires explicit valid session and thread when attribution is supplied" do
    for identity <- [
          [],
          [session_id: "session"],
          [session_id: "session", thread_id: "bad\nthread"]
        ] do
      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        TurnMetadata.headers(Keyword.put(identity, :codex_turn_metadata, metadata()))
      end
    end
  end

  test "telemetry includes the same attribution without auth or arbitrary values" do
    provider = [
      session_id: "session",
      thread_id: "thread",
      codex_turn_metadata: metadata(),
      access_token: "secret"
    ]

    for options <- [provider, [openai_codex: provider]] do
      summary = ReqLLM.Telemetry.RequestOptions.extract(:stream, provider_options: options)
      assert summary.codex_session_id == "session"
      assert summary.codex_thread_id == "thread"
      assert summary.codex_turn_id == "turn"
      assert summary.codex_request_kind == "compaction"
      assert summary.codex_turn_started_at_unix_ms == 123
      refute inspect(summary) =~ "secret"
    end

    assert TurnMetadata.telemetry(codex_turn_metadata: %{arbitrary: "secret"}) == %{}
  end
end

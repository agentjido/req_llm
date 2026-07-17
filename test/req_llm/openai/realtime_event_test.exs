defmodule ReqLLM.OpenAI.Realtime.EventTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.OpenAI.Realtime
  alias ReqLLM.OpenAI.Realtime.Event
  alias ReqLLM.StreamEvent

  @model %LLMDB.Model{provider: :openai, id: "gpt-realtime"}
  @fixture Path.join(__DIR__, "fixtures/realtime_events.json")

  describe "project_event/2" do
    test "projects only exact portable overlap in provider order" do
      raw_events = fixture_events()

      projected =
        Enum.map(raw_events, &Realtime.project_event(&1, model: @model, payloads: :raw))

      assert Enum.map(projected, & &1.type) == Enum.map(raw_events, & &1["type"])
      assert Enum.map(projected, & &1.native) == raw_events

      stream_events = Enum.flat_map(projected, & &1.stream_events)

      assert Enum.map(stream_events, & &1.type) == [
               :start,
               :text_delta,
               :text_delta,
               :tool_call_start,
               :tool_call_delta,
               :tool_call,
               :tool_result,
               :usage,
               :finish
             ]

      assert %StreamEvent{
               type: :start,
               data: %{model: %{id: "gpt-realtime", provider: :openai}},
               metadata: %{event_id: "evt_start", response_id: "resp_1"}
             } = Enum.at(stream_events, 0)

      assert %StreamEvent{
               type: :text_delta,
               data: "private text output",
               metadata: %{modality: :text, item_id: "msg_1", response_id: "resp_1"}
             } = Enum.at(stream_events, 1)

      assert %StreamEvent{
               type: :text_delta,
               data: "private audio transcript",
               metadata: %{modality: :audio_transcript}
             } = Enum.at(stream_events, 2)

      assert %StreamEvent{
               type: :tool_call,
               data: %{id: "call_1", name: "lookup", arguments: %{"query" => "private query"}},
               metadata: %{item_id: "fc_1"}
             } = Enum.at(stream_events, 5)

      assert %StreamEvent{type: :tool_result, data: %Message{} = result} =
               Enum.at(stream_events, 6)

      assert Enum.at(stream_events, 6).metadata.item_id == "fco_1"

      assert result.role == :tool
      assert result.tool_call_id == "call_1"
      assert [%ContentPart{type: :text, text: "private tool result"}] = result.content

      assert %StreamEvent{
               type: :usage,
               data: %{input_tokens: 12, output_tokens: 5, total_tokens: 17, cached_tokens: 4},
               metadata: %{event_id: "evt_done", response_id: "resp_1"}
             } = Enum.at(stream_events, 7)

      assert %StreamEvent{
               type: :finish,
               data: %{finish_reason: :tool_calls},
               metadata: %{response_id: "resp_1", status: "completed"}
             } = Enum.at(stream_events, 8)

      refute Enum.at(projected, 4) |> Event.portable?()
      refute Enum.at(projected, 9) |> Event.portable?()
      refute Enum.at(projected, 10) |> Event.portable?()
      assert Enum.at(projected, 11) |> Event.terminal?()
    end

    test "redacts native and canonical payloads by default" do
      projected =
        fixture_events()
        |> Enum.map(&Realtime.project_event(&1, model: @model))

      rendered = inspect(projected)

      refute rendered =~ "private session instructions"
      refute rendered =~ "sk-session-secret"
      refute rendered =~ "private text output"
      refute rendered =~ "private audio transcript"
      refute rendered =~ "cHJpdmF0ZSBhdWRpbw=="
      refute rendered =~ "private query"
      refute rendered =~ "private tool result"
      refute rendered =~ "private recoverable error"

      assert rendered =~ "[REDACTED]"

      text = projected |> Enum.at(2) |> Map.fetch!(:stream_events) |> List.first()
      assert text.data == "[REDACTED]"

      tool = projected |> Enum.at(7) |> Map.fetch!(:stream_events) |> List.first()
      assert tool.data.arguments == %{"redacted" => true}

      recoverable_error = Enum.at(projected, 9)
      assert recoverable_error.stream_events == []
      assert get_in(recoverable_error.native, ["error", "message"]) == "[REDACTED]"

      rate_limits = Enum.at(projected, 10)
      assert get_in(rate_limits.native, ["rate_limits", Access.at(0), "remaining"]) == 49_950
    end

    test "redacts structured payload values" do
      event = %{
        "type" => "session.updated",
        "arguments" => %{"query" => "private query"},
        "audio" => [1, 2, 3],
        "content" => [%{"value" => "private content"}],
        "instructions" => 12_345,
        "metadata" => %{"visible" => "retained"}
      }

      assert %Event{
               native: %{
                 "arguments" => "[REDACTED]",
                 "audio" => "[REDACTED]",
                 "content" => "[REDACTED]",
                 "instructions" => "[REDACTED]",
                 "metadata" => %{"visible" => "retained"}
               }
             } = Realtime.project_event(event)
    end

    test "does not project response start without a resolved model" do
      event = %{
        "type" => "response.created",
        "event_id" => "evt_1",
        "response" => %{"id" => "resp_1", "status" => "in_progress"}
      }

      assert %Event{stream_events: []} = Realtime.project_event(event)
    end

    test "maps terminal status without treating recoverable errors as terminal" do
      cancelled = response_done("cancelled", %{"reason" => "client_cancelled"})

      failed =
        response_done("failed", %{"error" => %{"code" => "server_error", "message" => "private"}})

      length = response_done("incomplete", %{"reason" => "max_output_tokens"})
      filtered = response_done("incomplete", %{"reason" => "content_filter"})
      recoverable = %{"type" => "error", "error" => %{"message" => "try again"}}

      assert [%StreamEvent{type: :cancelled, metadata: %{status_reason: "client_cancelled"}}] =
               Realtime.project_event(cancelled).stream_events

      assert [
               %StreamEvent{
                 type: :error,
                 data: %{"code" => "server_error", "message" => "[REDACTED]"}
               }
             ] =
               Realtime.project_event(failed).stream_events

      assert [%StreamEvent{type: :error, data: %{"message" => "private"}}] =
               Realtime.project_event(failed, payloads: :raw).stream_events

      assert [%StreamEvent{type: :finish, data: %{finish_reason: :length}}] =
               Realtime.project_event(length).stream_events

      assert [%StreamEvent{type: :finish, data: %{finish_reason: :content_filter}}] =
               Realtime.project_event(filtered).stream_events

      assert Realtime.project_event(recoverable).stream_events == []
    end

    test "leaves invalid or provider-native tool input unprojected" do
      invalid_arguments = %{
        "type" => "response.function_call_arguments.done",
        "call_id" => "call_1",
        "name" => "lookup",
        "arguments" => "not-json"
      }

      mcp_arguments = %{
        "type" => "response.mcp_call_arguments.done",
        "item_id" => "mcp_1",
        "arguments" => "{\"query\":\"private\"}"
      }

      assert Realtime.project_event(invalid_arguments).stream_events == []
      assert Realtime.project_event(mcp_arguments).stream_events == []
    end

    test "validates payload mode" do
      assert_raise NimbleOptions.ValidationError, fn ->
        Realtime.project_event(%{"type" => "session.created"}, payloads: :unsafe)
      end
    end
  end

  defp fixture_events do
    @fixture
    |> File.read!()
    |> Jason.decode!()
  end

  defp response_done(status, status_details) do
    %{
      "type" => "response.done",
      "event_id" => "evt_done",
      "response" => %{
        "id" => "resp_1",
        "status" => status,
        "status_details" => status_details
      }
    }
  end
end

defmodule ReqLLM.Step.StreamTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Step.Stream

  # Shared helpers
  defp sse_response(body, content_type \\ "text/event-stream") do
    %Req.Response{
      status: 200,
      headers: %{"content-type" => [content_type]},
      body: body
    }
  end

  defp handle_sse(body, content_type \\ "text/event-stream") do
    req = %Req.Request{}
    resp = sse_response(body, content_type)
    {_req, returned_resp} = Stream.handle({req, resp})
    returned_resp.body |> Enum.to_list()
  end

  defp assert_request_preserved(original_req, updated_req, additional_checks) do
    # Common assertions for request structure preservation
    for {field, value} <- Map.from_struct(original_req) do
      case field do
        :response_steps ->
          for check <- additional_checks, do: check.(updated_req)

        _ ->
          assert Map.get(updated_req, field) == value
      end
    end
  end

  describe "attach/1" do
    test "attaches stream_sse step and preserves request structure" do
      request = %Req.Request{
        options: [test: "value"],
        headers: %{"content-type" => "application/json"},
        response_steps: [other_step: &Function.identity/1]
      }

      updated_request = Stream.attach(request)

      assert_request_preserved(request, updated_request, [
        fn req -> assert Keyword.has_key?(req.response_steps, :stream_sse) end,
        fn req -> assert req.response_steps[:stream_sse] == (&Stream.handle/1) end,
        fn req -> assert req.response_steps[:other_step] == (&Function.identity/1) end
      ])
    end
  end

  describe "maybe_attach/2" do
    @falsy_values [false, nil, 0, "", []]

    test "conditionally attaches based on boolean parameter" do
      request = %Req.Request{}

      # Should attach when true
      attached = Stream.maybe_attach(request, true)
      assert Keyword.has_key?(attached.response_steps, :stream_sse)

      # Should not attach for falsy values
      for falsy_value <- @falsy_values do
        not_attached = Stream.maybe_attach(request, falsy_value)
        refute Keyword.has_key?(not_attached.response_steps, :stream_sse)
      end
    end

    test "preserves original request when streaming disabled" do
      request = %Req.Request{options: [test: "value"]}
      updated_request = Stream.maybe_attach(request, false)
      assert updated_request == request
    end
  end

  describe "handle/1 content-type detection" do
    @non_sse_types [
      {"application/json", ~s({"message": "Hello"})},
      {"text/plain", "plain text response"},
      {"text/html", "<html></html>"}
    ]

    @sse_types [
      "text/event-stream",
      "text/event-stream; charset=utf-8",
      "text/event-stream; charset=utf-8; boundary=something"
    ]

    test "passes through non-SSE responses unchanged" do
      req = %Req.Request{}

      for {content_type, body} <- @non_sse_types do
        resp = sse_response(body, content_type)
        {returned_req, returned_resp} = Stream.handle({req, resp})

        assert returned_req == req
        assert returned_resp == resp
      end
    end

    test "handles missing or empty content-type headers" do
      req = %Req.Request{}

      for headers <- [%{}, %{"content-type" => []}] do
        resp = %Req.Response{status: 200, headers: headers, body: "test"}
        {returned_req, returned_resp} = Stream.handle({req, resp})

        assert returned_req == req
        assert returned_resp == resp
      end
    end

    test "processes SSE responses with various content-type formats" do
      sse_body = "data: {\"test\": true}\n\n"

      for content_type <- @sse_types do
        events = handle_sse(sse_body, content_type)
        assert length(events) == 1
        assert %{data: %{"test" => true}} = hd(events)
      end
    end

    test "uses first content-type header when multiple present" do
      req = %Req.Request{}

      resp = %Req.Response{
        status: 200,
        headers: %{"content-type" => ["application/json", "text/plain"]},
        body: ~s({"test": true})
      }

      {returned_req, returned_resp} = Stream.handle({req, resp})
      assert returned_req == req
      assert returned_resp == resp
    end
  end

  describe "SSE parsing - binary input" do
    test "parses complete SSE structure with all fields" do
      sse_body = """
      event: completion
      data: {"message": "hello"}
      id: msg-123
      retry: 1000

      """

      events = handle_sse(sse_body)
      assert length(events) == 1

      event = hd(events)
      assert event.event == "completion"
      assert event.data == %{"message" => "hello"}
      assert event.id == "msg-123"
      assert event.retry == 1000
    end

    test "handles events without data field" do
      events = handle_sse("event: heartbeat\nid: hb-1\n\n")

      assert length(events) == 1
      event = hd(events)
      assert event.event == "heartbeat"
      assert event.id == "hb-1"
      refute Map.has_key?(event, :data)
    end

    test "processes multiple events in sequence" do
      sse_body = """
      data: {"id": "1"}

      data: {"id": "2"}

      event: done
      data: {"finished": true}

      """

      events = handle_sse(sse_body)
      assert length(events) == 3
      assert %{data: %{"id" => "1"}} = Enum.at(events, 0)
      assert %{data: %{"id" => "2"}} = Enum.at(events, 1)
      assert %{event: "done", data: %{"finished" => true}} = Enum.at(events, 2)
    end

    test "handles empty and whitespace-only bodies" do
      for body <- ["", "\n\n  \n\n"] do
        events = handle_sse(body)
        assert events == []
      end
    end
  end

  describe "SSE parsing - stream input" do
    test "processes chunked stream correctly" do
      chunk_stream =
        [
          ~s(data: {"id": "1", "content),
          ~s(": "hello"}\n\ndata: {"id":),
          ~s( "2", "content": "world"}\n\n)
        ]
        |> Elixir.Stream.map(& &1)

      req = %Req.Request{}
      resp = sse_response(chunk_stream)
      {_req, returned_resp} = Stream.handle({req, resp})
      events = Enum.to_list(returned_resp.body)

      assert length(events) == 2
      # Note: Streaming produces different format than binary parsing
      assert {:data, ~s({"id": "1", "content": "hello"})} = Enum.at(events, 0)
      assert {:data, ~s({"id": "2", "content": "world"})} = Enum.at(events, 1)
    end

    test "maintains buffer state across incomplete chunks" do
      chunk_stream =
        [
          "data: {\"partial",
          ~s(": "data"}\n\ndata: {"complete": true}\n\n)
        ]
        |> Elixir.Stream.map(& &1)

      req = %Req.Request{}
      resp = sse_response(chunk_stream)
      {_req, returned_resp} = Stream.handle({req, resp})
      events = Enum.to_list(returned_resp.body)

      assert length(events) == 2
      assert {:data, ~s({"partial": "data"})} = Enum.at(events, 0)
      assert {:data, ~s({"complete": true})} = Enum.at(events, 1)
    end
  end

  describe "JSON parsing in data field" do
    test "parses valid JSON objects and preserves invalid data" do
      sse_body = """
      data: {"valid": "json", "number": 42, "null": null}

      data: {invalid json}

      data: plain text data

      """

      events = handle_sse(sse_body)
      assert length(events) == 3
      assert %{data: %{"valid" => "json", "number" => 42, "null" => nil}} = Enum.at(events, 0)
      assert %{data: "{invalid json}"} = Enum.at(events, 1)
      assert %{data: "plain text data"} = Enum.at(events, 2)
    end

    test "handles deeply nested JSON structures" do
      nested_json = %{"level1" => %{"level2" => %{"level3" => %{"data" => "deep"}}}}
      sse_body = "data: #{Jason.encode!(nested_json)}\n\n"

      events = handle_sse(sse_body)
      assert length(events) == 1
      assert hd(events).data == nested_json
    end

    test "current implementation bugs with non-object JSON" do
      # These are known bugs in the current implementation
      for data <- ["[1,2,3]", "\"string\"", "42", "true", "null"] do
        sse_body = "data: #{data}\n\n"

        assert_raise CaseClauseError, fn ->
          handle_sse(sse_body)
        end
      end
    end

    test "handles large payloads and special characters" do
      large_data = %{"content" => String.duplicate("x", 10_000)}
      unicode_data = %{"message" => "Hello 世界! 🌍", "emoji" => "🚀💻🎉"}

      for test_data <- [large_data, unicode_data] do
        sse_body = "data: #{Jason.encode!(test_data)}\n\n"
        events = handle_sse(sse_body)
        assert length(events) == 1
        assert hd(events).data == test_data
      end
    end
  end

  describe "real-world format compatibility" do
    test "processes OpenAI streaming format" do
      sse_body = """
      data: {"id":"chatcmpl-123","choices":[{"delta":{"role":"assistant"}}]}

      data: {"id":"chatcmpl-123","choices":[{"delta":{"content":"Hello"}}]}

      data: {"id":"chatcmpl-123","choices":[{"delta":{},"finish_reason":"stop"}]}

      data: [DONE]

      """

      events = handle_sse(sse_body)
      assert length(events) == 4

      # Verify key structure elements
      assert get_in(Enum.at(events, 0), [:data, "choices", Access.at(0), "delta", "role"]) ==
               "assistant"

      assert get_in(Enum.at(events, 1), [:data, "choices", Access.at(0), "delta", "content"]) ==
               "Hello"

      assert get_in(Enum.at(events, 2), [:data, "choices", Access.at(0), "finish_reason"]) ==
               "stop"

      assert Enum.at(events, 3).data == "[DONE]"
    end

    test "processes Anthropic streaming format" do
      sse_body = """
      event: message_start
      data: {"type":"message_start","message":{"role":"assistant"}}

      event: content_block_delta
      data: {"type":"content_block_delta","delta":{"text":"Hello"}}

      event: message_stop
      data: {"type":"message_stop"}

      """

      events = handle_sse(sse_body)
      assert length(events) == 3

      event_types = Enum.map(events, & &1.event)
      assert event_types == ["message_start", "content_block_delta", "message_stop"]

      delta_event = Enum.at(events, 1)
      assert delta_event.data["delta"]["text"] == "Hello"
    end
  end

  describe "edge cases" do
    test "filters out nil events and handles incomplete SSE" do
      # Test that process_sse_event properly filters nils
      sse_body = ~s(data: {"valid": "event"}\n\n)
      events = handle_sse(sse_body)

      assert Enum.all?(events, &(not is_nil(&1)))
      assert length(events) == 1
    end

    test "handles SSE without proper termination" do
      # SSE without double newline terminator won't be recognized as complete
      sse_body = ~s(data: {"incomplete": "event"})
      events = handle_sse(sse_body)

      assert Enum.empty?(events)
    end
  end

  describe "Req pipeline integration" do
    test "works correctly in Req response pipeline" do
      request = %Req.Request{url: "https://example.com/stream"}
      updated_request = Stream.attach(request)

      mock_response = sse_response(~s(data: {"message": "pipeline test"}\n\n))

      step_fun = updated_request.response_steps[:stream_sse]
      {returned_req, returned_resp} = step_fun.({updated_request, mock_response})

      assert returned_req.url == "https://example.com/stream"
      assert is_struct(returned_resp.body, Elixir.Stream)

      events = Enum.to_list(returned_resp.body)
      assert %{data: %{"message" => "pipeline test"}} = hd(events)
    end
  end
end

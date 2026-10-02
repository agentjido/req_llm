defmodule ReqLLM.TelemetryRedactionTest do
  use ExUnit.Case, async: false

  alias ReqLLM.{Context, Message, Response}
  alias ReqLLM.Message.ContentPart

  def handle_telemetry(event, _, metadata, pid),
    do: send(pid, {:telemetry_probe, event, metadata})

  test "public Anthropic generation redacts thinking blocks in stop and replayed start metadata" do
    id = "issue1068-anthropic"

    :ok =
      :telemetry.attach_many(
        id,
        [[:req_llm, :request, :start], [:req_llm, :request, :stop]],
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)
    marker = "ISSUE1068_ANTHROPIC_THINKING"

    Req.Test.stub(:issue1068_anthropic, fn conn ->
      Req.Test.json(conn, %{
        "id" => "msg_probe",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-5",
        "content" => [
          %{
            "type" => "server_tool_use",
            "id" => "srv_probe",
            "name" => "tool_search_tool_regex",
            "input" => %{"pattern" => "probe"}
          },
          %{"type" => "thinking", "thinking" => marker, "signature" => "probe_signature"},
          %{"type" => "text", "text" => "done"}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
      })
    end)

    assert {:ok, response} =
             ReqLLM.generate_text("anthropic:claude-sonnet-4-5", "probe",
               api_key: "probe",
               telemetry: [payloads: :raw],
               req_http_options: [plug: {Req.Test, :issue1068_anthropic}]
             )

    assert_receive {:telemetry_probe, [:req_llm, :request, :stop], metadata}
    refute inspect(metadata, structs: false, limit: :infinity) =~ marker
    assert inspect(response.message, structs: false, limit: :infinity) =~ marker

    assert {:ok, _} =
             ReqLLM.generate_text("anthropic:claude-sonnet-4-5", response.context,
               api_key: "probe",
               telemetry: [payloads: :raw],
               req_http_options: [plug: {Req.Test, :issue1068_anthropic}]
             )

    assert_receive {:telemetry_probe, [:req_llm, :request, :start], first}
    refute inspect(first, structs: false, limit: :infinity) =~ marker
    assert_receive {:telemetry_probe, [:req_llm, :request, :start], replayed}
    refute inspect(replayed, structs: false, limit: :infinity) =~ marker
  end

  test "public OpenAI generation redacts nested reasoning summaries" do
    id = "issue1068-openai"

    :ok =
      :telemetry.attach(id, [:req_llm, :request, :stop], &__MODULE__.handle_telemetry/4, self())

    on_exit(fn -> :telemetry.detach(id) end)
    marker = "ISSUE1068_OPENAI_SUMMARY"

    Req.Test.stub(:issue1068_openai, fn conn ->
      Req.Test.json(conn, %{
        "id" => "resp_probe",
        "object" => "response",
        "status" => "completed",
        "model" => "gpt-5",
        "output" => [
          %{
            "id" => "rs_probe",
            "type" => "reasoning",
            "summary" => [%{"type" => "summary_text", "text" => marker}]
          },
          %{
            "id" => "msg_probe",
            "type" => "message",
            "role" => "assistant",
            "status" => "completed",
            "content" => [%{"type" => "output_text", "text" => "done", "annotations" => []}]
          }
        ],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 2, "total_tokens" => 3}
      })
    end)

    assert {:ok, _} =
             ReqLLM.generate_text("openai:gpt-5", "probe",
               api_key: "probe",
               telemetry: [payloads: :raw],
               req_http_options: [plug: {Req.Test, :issue1068_openai}]
             )

    assert_receive {:telemetry_probe, [:req_llm, :request, :stop], metadata}
    refute inspect(metadata, structs: false, limit: :infinity) =~ marker
  end

  test "raw maps and reasoning details retain only redacted metadata" do
    id = "reasoning-redaction-maps"

    :ok =
      :telemetry.attach_many(
        id,
        [[:req_llm, :request, :start], [:req_llm, :request, :stop]],
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)
    marker = "PRIVATE_REASONING"

    message = %Message{
      role: :assistant,
      content: [
        ContentPart.provider_block(:anthropic, %{"type" => "thinking", "thinking" => marker}),
        ContentPart.provider_block(:openai, %{"type" => "reasoning", "text" => marker})
      ],
      reasoning_details: [
        %{
          "text" => marker,
          "provider_data" => %{"summary" => [%{"text" => marker}], "unknown" => marker}
        },
        %Message.ReasoningDetails{
          provider: :openai,
          provider_data: %{"summary" => [%{"text" => marker}], "unknown" => marker}
        }
      ]
    }

    response = %Response{
      id: "redaction",
      model: "probe",
      context: Context.new([message]),
      message: message,
      provider_meta: %{reasoning: %{"type" => "reasoning", "summary" => [%{"text" => marker}]}}
    }

    model = %LLMDB.Model{provider: :openai, id: "probe"}

    telemetry =
      ReqLLM.Telemetry.new_context(model, context: response.context, telemetry: [payloads: :raw])

    telemetry = ReqLLM.Telemetry.start_request(telemetry, %{})
    ReqLLM.Telemetry.stop_request(telemetry, response)

    for event <- [[:req_llm, :request, :start], [:req_llm, :request, :stop]] do
      assert_receive {:telemetry_probe, ^event, metadata}
      refute inspect(metadata, structs: false, limit: :infinity) =~ marker
    end

    sanitized = telemetry.request_payload.messages |> hd()

    for detail <- sanitized.reasoning_details do
      assert detail.redacted?
      assert detail.text_bytes == byte_size(marker)
      refute Map.has_key?(detail, :provider_data)
      refute Map.has_key?(detail, "provider_data")
    end

    assert hd(sanitized.content).data.redacted?
    assert hd(sanitized.content).data.text_bytes == byte_size(marker)
    assert response.message == message
  end
end

defmodule ReqLLM.ResponseProjectionTest do
  use ExUnit.Case, async: true

  @moduletag contract: :public_api

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.Response
  alias ReqLLM.Response.OutputItem
  alias ReqLLM.ToolCall

  describe "output_items/1" do
    test "projects retained output values in deterministic order" do
      text =
        ContentPart.text("Hello", %{
          sources: [%{"uri" => "https://example.com/a?api_key=secret", "title" => "A"}],
          annotations: [%{kind: :citation, start: 0, stop: 5}],
          refusal: "I cannot include that detail",
          signature: "opaque-reasoning-signature"
        })

      image = ContentPart.image(<<1, 2, 3>>, "image/png")
      file = ContentPart.file("report", "report.txt", "text/plain")
      thinking = ContentPart.thinking("Check the available facts", %{signature: "opaque"})
      tool_call = ToolCall.new("call_123", "lookup", ~s({"query":"facts"}))

      provider_item = %{
        "type" => "code_interpreter_call",
        "outputs" => [%{"type" => "file", "file_id" => "file_123"}]
      }

      response =
        response(
          message: %Message{
            role: :assistant,
            content: [text, image, file, thinking],
            tool_calls: [tool_call]
          },
          provider_meta: %{
            "google" => %{
              "sources" => [%{"uri" => "https://example.com/b", "title" => "B"}]
            },
            "code_interpreter" => %{"items" => [provider_item]}
          }
        )

      items = Response.output_items(response)

      assert Enum.map(items, & &1.type) == [
               :text,
               :source,
               :annotation,
               :refusal,
               :image,
               :file,
               :thinking,
               :tool_call,
               :source,
               :provider_item
             ]

      assert [%OutputItem{data: "Hello", metadata: text_metadata} | _rest] = items
      assert text_metadata.signature == "[REDACTED]"
      assert Enum.at(items, 4).data == image
      assert Enum.at(items, 5).data == file
      assert Enum.at(items, 6).data == "Check the available facts"
      assert Enum.at(items, 6).metadata.signature == "[REDACTED]"
      assert Enum.at(items, 7).data == tool_call
      assert List.last(items).data == provider_item

      assert Response.files(response) == [file]

      assert Response.sources(response) == [
               %{"uri" => "https://example.com/a?api_key=[REDACTED]", "title" => "A"},
               %{"uri" => "https://example.com/b", "title" => "B"}
             ]

      assert Response.annotations(response) == [%{kind: :citation, start: 0, stop: 5}]
      assert Response.refusals(response) == ["I cannot include that detail"]
      assert Response.provider_items(response) == [provider_item]
    end

    test "groups projections into stable channels" do
      response =
        response(
          message: %Message{
            role: :assistant,
            content: [ContentPart.text("Answer"), ContentPart.thinking("Reason")],
            tool_calls: [ToolCall.new("call_123", "lookup", "{}")]
          }
        )

      channels = Response.channels(response)

      assert Map.keys(channels) |> Enum.sort() == OutputItem.channels() |> Enum.sort()
      assert Enum.map(channels.message, & &1.type) == [:text]
      assert Enum.map(channels.reasoning, & &1.type) == [:thinking]
      assert Enum.map(channels.tools, & &1.type) == [:tool_call]
      assert Response.channel_items(response, :media) == []
    end

    test "omits output values that were not retained" do
      response = response(message: nil, finish_reason: :content_filter)

      assert Response.output_items(response) == []
      assert Response.refusals(response) == []
    end

    test "handles malformed source URLs and unusual metadata keys defensively" do
      response =
        response(
          provider_meta: %{
            "sources" => [%{"uri" => "https://example.com/result?bad=%"}],
            {:provider, :version} => 1
          }
        )

      assert Response.sources(response) == [%{"uri" => "https://example.com/result?bad=%25"}]
      assert Response.call_metadata(response).provider_metadata[{:provider, :version}] == 1
    end

    test "does not invent a canonical type for unrecognized message content" do
      object_part = %{type: :object, object: %{answer: 42}}
      response = response(message: %Message{role: :assistant, content: [object_part]})

      assert Response.output_items(response) == []
      assert response.object == nil
    end

    test "projects retained reasoning details without duplicating thinking content" do
      detail = %ReasoningDetails{
        text: "Reason from retained details",
        signature: "opaque",
        encrypted?: true,
        provider: :anthropic,
        format: "anthropic-thinking-v1",
        index: 0,
        provider_data: %{"input" => "hidden"}
      }

      response =
        response(
          message: %Message{
            role: :assistant,
            content: [ContentPart.text("Answer")],
            reasoning_details: [detail, detail]
          }
        )

      assert [reasoning] = Response.channel_items(response, :reasoning)
      assert reasoning.data == "Reason from retained details"
      assert reasoning.metadata.signature == "[REDACTED]"
      assert reasoning.metadata.provider_data == %{"input" => "[REDACTED]"}
    end
  end

  describe "call_metadata/1" do
    test "projects available call values and recursively redacts sensitive metadata" do
      response =
        response(
          finish_reason: :stop,
          usage: %{input_tokens: 4, output_tokens: 2, total_tokens: 6},
          message: %Message{
            role: :assistant,
            content: [ContentPart.text("Done")],
            metadata: %{
              request_id: "req_123",
              raw_finish_reason: "end_turn",
              warnings: ["temperature was ignored for sk-secret"],
              attempts: [%{prompt: "first"}, %{prompt: "second"}],
              timings: %{total_ms: 12, phases: %{network_ms: 7, name: "network"}}
            }
          },
          provider_meta: %{
            "service_tier" => "priority",
            "output_tokens" => 2,
            "api_key" => "sk-secret",
            "prompt" => "private prompt",
            "files" => [%{"file_id" => "file_secret"}],
            "reasoningDetails" => %{"signature" => "opaque"},
            "request" => %{"id" => "provider_req", "body" => "private"},
            "warnings" => ["temperature was ignored for sk-secret"],
            "url" => "https://example.com/result?token=secret&format=json"
          }
        )

      metadata = Response.call_metadata(response)

      assert metadata.response_id == "resp_123"
      assert metadata.model == "test-model"
      assert metadata.finish_reason == :stop
      assert metadata.usage == %{input_tokens: 4, output_tokens: 2, total_tokens: 6}
      assert metadata.request_id == "req_123"
      assert metadata.raw_finish_reason == "end_turn"
      assert metadata.warnings == ["temperature was ignored for [REDACTED]"]
      assert metadata.attempts == 2
      assert metadata.timings == %{total_ms: 12, phases: %{network_ms: 7}}

      assert metadata.provider_metadata == %{
               "service_tier" => "priority",
               "output_tokens" => 2,
               "api_key" => "[REDACTED]",
               "prompt" => "[REDACTED]",
               "files" => "[REDACTED]",
               "reasoningDetails" => "[REDACTED]",
               "request" => "[REDACTED]",
               "warnings" => "[REDACTED]",
               "url" => "https://example.com/result?format=json&token=[REDACTED]"
             }

      encoded = inspect(metadata)
      refute encoded =~ "sk-secret"
      refute encoded =~ "private prompt"
      refute encoded =~ "file_secret"
      refute encoded =~ "opaque"
    end

    test "omits call metadata that is unavailable instead of synthesizing it" do
      response = response(message: nil)

      assert Response.call_metadata(response) == %{
               response_id: "resp_123",
               model: "test-model"
             }
    end

    test "keeps error and response values unchanged" do
      error = RuntimeError.exception("provider failed")
      response = response(message: nil, error: error, finish_reason: :error)

      assert Response.output_items(response) == []
      assert Response.call_metadata(response).finish_reason == :error
      assert response.error == error
      refute Map.has_key?(Response.call_metadata(response), :error)
    end
  end

  describe "legacy Response compatibility" do
    test "projections do not change fields, equality, Inspect, Jason, helpers, or schema" do
      response =
        response(
          message: %Message{role: :assistant, content: [ContentPart.text("Hello")]},
          finish_reason: :stop,
          usage: %{total_tokens: 3}
        )

      original = response
      original_inspect = inspect(response)
      original_json = Jason.encode!(response)

      assert Map.keys(Map.from_struct(response)) |> Enum.sort() ==
               [
                 :context,
                 :error,
                 :finish_reason,
                 :id,
                 :message,
                 :model,
                 :object,
                 :provider_meta,
                 :stream,
                 :stream?,
                 :usage
               ]
               |> Enum.sort()

      assert {:ok, %OutputItem{type: :text, data: "Hello"}} =
               Zoi.parse(OutputItem.schema(), %OutputItem{type: :text, data: "Hello"})

      assert Jason.decode!(Jason.encode!(hd(Response.output_items(response)))) == %{
               "type" => "text",
               "data" => "Hello",
               "metadata" => %{}
             }

      assert Response.text(response) == "Hello"
      assert Response.thinking(response) == ""
      assert Response.tool_calls(response) == []
      assert Response.finish_reason(response) == :stop
      assert Response.usage(response) == %{total_tokens: 3}

      assert response == original
      assert inspect(response) == original_inspect
      assert Jason.encode!(response) == original_json
      refute Map.has_key?(Jason.decode!(original_json), "output_items")
      refute Map.has_key?(Jason.decode!(original_json), "call_metadata")
    end
  end

  defp response(opts) do
    defaults = %{
      id: "resp_123",
      model: "test-model",
      context: Context.new([]),
      message: nil,
      object: nil,
      stream?: false,
      stream: nil,
      usage: nil,
      finish_reason: nil,
      provider_meta: %{},
      error: nil
    }

    struct!(Response, Map.merge(defaults, Map.new(opts)))
  end
end

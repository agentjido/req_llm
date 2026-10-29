defmodule ReqLLM.Providers.Google.ThoughtSignaturesTest do
  @moduledoc """
  Google thought signature decoding, preservation, and replay.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Google, async: true

  alias ReqLLM.Context
  alias ReqLLM.Providers.Google

  describe "body encoding & context translation" do
    test "encode_body uses preserved tool call thought signature metadata" do
      {:ok, model} = ReqLLM.model("google:gemini-2.5-flash")

      tool_call =
        "call_1"
        |> ReqLLM.ToolCall.new("get_weather", ~s({"location":"SF"}))
        |> ReqLLM.ToolCall.put_metadata(%{thought_signature: "real_signature_123"})

      context =
        Context.new([
          Context.user("What's the weather?"),
          Context.assistant("", tool_calls: [tool_call])
        ])

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false,
          operation: :chat
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      [function_call_part] =
        decoded["contents"]
        |> Enum.flat_map(& &1["parts"])
        |> Enum.filter(&Map.has_key?(&1, "functionCall"))

      assert function_call_part["thoughtSignature"] == "real_signature_123"
    end
  end

  describe "ordinary text thought signatures" do
    test "buffered and public stream responses replay signed text parts unchanged" do
      model = ReqLLM.model!("google:gemini-2.5-flash")
      context = Context.new([Context.user("Question")])

      cases = [
        [%{"text" => "Answer", "thoughtSignature" => "text-signature"}],
        [%{"text" => "", "thoughtSignature" => "empty-signature"}],
        [
          %{"text" => "First", "thoughtSignature" => "first-signature"},
          %{"text" => "", "thoughtSignature" => "terminal-signature"},
          %{"text" => "Last", "thoughtSignature" => "last-signature"}
        ],
        [
          %{"text" => "Unsigned"},
          %{"text" => "", "thoughtSignature" => "standalone-signature"}
        ]
      ]

      for parts <- cases do
        body = google_text_signature_body(parts)
        buffered = decode_text_signature_response(body, model, context)
        chunks = google_text_signature_chunks(parts, model)

        signed_chunks = Enum.filter(chunks, &Map.has_key?(&1.metadata, :thought_signature))
        expected_signed = Enum.filter(parts, &Map.has_key?(&1, "thoughtSignature"))

        assert Enum.map(signed_chunks, &{&1.text, &1.metadata.thought_signature}) ==
                 Enum.map(expected_signed, &{&1["text"], &1["thoughtSignature"]})

        for consume <- [:to_response, :process_stream] do
          stream = text_signature_stream_response(chunks, model, context)
          assert {:ok, streamed} = apply(ReqLLM.StreamResponse, consume, [stream])
          assert streamed.message.content == buffered.message.content

          for response <- [buffered, streamed] do
            assert List.last(response.context.messages) == response.message
            assert ReqLLM.Response.text(response) == Enum.map_join(parts, & &1["text"])
            assert response.message.reasoning_details in [nil, []]
            assert_text_signature_replay(response, model, parts)
          end
        end
      end
    end

    test "unsigned deltas stay unsigned before a separate terminal signature" do
      model = ReqLLM.model!("google:gemini-2.5-flash")
      context = Context.new([Context.user("Question")])

      parts = [
        %{"text" => "Hello "},
        %{"text" => "world"},
        %{"text" => "", "thoughtSignature" => "terminal-signature"}
      ]

      chunks = google_text_signature_chunks(parts, model)

      assert {:ok, response} =
               ReqLLM.StreamResponse.process_stream(
                 text_signature_stream_response(chunks, model, context)
               )

      assert [unsigned, signed] = response.message.content
      assert unsigned.text == "Hello world"
      assert unsigned.metadata == %{}
      assert signed.text == ""
      assert signed.metadata == %{thought_signature: "terminal-signature"}

      assert_text_signature_replay(response, model, [
        %{"text" => "Hello world"},
        %{"text" => "", "thoughtSignature" => "terminal-signature"}
      ])
    end

    test "unsigned text and unsigned empty chunks keep their existing shape" do
      model = ReqLLM.model!("google:gemini-2.5-flash")
      context = Context.new([Context.user("Question")])
      parts = [%{"text" => "Hello "}, %{"text" => ""}, %{"text" => "world"}]
      chunks = google_text_signature_chunks(parts, model)
      assert Enum.count(chunks, &(&1.type == :content)) == 2

      buffered = decode_text_signature_response(google_text_signature_body(parts), model, context)

      assert {:ok, streamed} =
               ReqLLM.StreamResponse.to_response(
                 text_signature_stream_response(chunks, model, context)
               )

      for response <- [buffered, streamed] do
        assert [%ReqLLM.Message.ContentPart{type: :text, text: "Hello world", metadata: %{}}] =
                 response.message.content

        assert_text_signature_replay(response, model, [%{"text" => "Hello world"}])
      end
    end

    test "text signatures remain distinct from thinking and tool signatures" do
      model = ReqLLM.model!("google:gemini-2.5-flash")
      context = Context.new([Context.user("Question")])

      parts = [
        %{"text" => "Plan", "thought" => true, "thoughtSignature" => "thinking-signature"},
        %{"text" => "Answer", "thoughtSignature" => "answer-signature"},
        %{
          "functionCall" => %{"name" => "lookup", "args" => %{}},
          "thoughtSignature" => "tool-signature"
        }
      ]

      buffered_parts = Enum.drop(parts, -1)

      buffered =
        decode_text_signature_response(google_text_signature_body(buffered_parts), model, context)

      chunks = google_text_signature_chunks(parts, model)

      assert {:ok, streamed} =
               ReqLLM.StreamResponse.process_stream(
                 text_signature_stream_response(chunks, model, context)
               )

      assert [tool_call] = streamed.message.tool_calls
      assert ReqLLM.ToolCall.metadata(tool_call)[:thought_signature] == "tool-signature"

      for {response, expected_parts} <- [{buffered, buffered_parts}, {streamed, parts}] do
        assert [%{signature: "thinking-signature", text: "Plan"}] =
                 response.message.reasoning_details

        text_part = Enum.find(response.message.content, &(&1.type == :text))
        assert text_part.metadata == %{thought_signature: "answer-signature"}
        assert List.last(response.context.messages) == response.message
        assert_text_signature_replay(response, model, expected_parts)
      end
    end

    test "encoder preserves binary message content beside signed text" do
      model = ReqLLM.model!("google:gemini-2.5-flash")

      context = %Context{
        messages: [
          %ReqLLM.Message{role: :user, content: "Question"},
          %ReqLLM.Message{role: :assistant, content: "Background"},
          %ReqLLM.Message{role: :user, content: "Follow up"},
          %ReqLLM.Message{
            role: :assistant,
            content: [
              %ReqLLM.Message.ContentPart{
                type: :text,
                text: "Answer",
                metadata: %{thought_signature: "text-signature"}
              }
            ]
          },
          %ReqLLM.Message{role: :user, content: "Continue"}
        ]
      }

      request = %Req.Request{options: [model: model.id, context: context, stream: false]}
      body = request |> Google.encode_body() |> ReqLLM.Test.Helpers.json_body()
      assert {:ok, stream_request} = Google.attach_stream(model, context, [api_key: "test"], nil)

      expected = [
        %{"role" => "user", "parts" => [%{"text" => "Question"}]},
        %{"role" => "model", "parts" => [%{"text" => "Background"}]},
        %{"role" => "user", "parts" => [%{"text" => "Follow up"}]},
        %{
          "role" => "model",
          "parts" => [%{"text" => "Answer", "thoughtSignature" => "text-signature"}]
        },
        %{"role" => "user", "parts" => [%{"text" => "Continue"}]}
      ]

      assert body["contents"] == expected
      assert Jason.decode!(stream_request.body)["contents"] == expected
    end

    test "encoder accepts persisted string-key text signature metadata" do
      model = ReqLLM.model!("google:gemini-2.5-flash")

      message = %ReqLLM.Message{
        role: :assistant,
        content: [
          %ReqLLM.Message.ContentPart{
            type: :text,
            text: "Answer",
            metadata: %{"thought_signature" => "persisted-signature"}
          }
        ]
      }

      response = %ReqLLM.Response{
        id: "persisted-response",
        model: model.id,
        message: message,
        context: Context.new([Context.user("Question"), message])
      }

      assert_text_signature_replay(response, model, [
        %{"text" => "Answer", "thoughtSignature" => "persisted-signature"}
      ])
    end
  end

  describe "thought signature support" do
    test "decode_response extracts reasoning_details from thought parts" do
      google_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "text" => "Let me think about this...",
                  "thought" => true,
                  "thoughtSignature" => "base64signature123"
                },
                %{"text" => "The answer is 42."}
              ],
              "role" => "model"
            },
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 15,
          "totalTokenCount" => 25,
          "thoughtsTokenCount" => 5
        }
      }

      mock_resp = %Req.Response{
        status: 200,
        body: google_response
      }

      {:ok, model} = ReqLLM.model("google:gemini-2.5-flash")
      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false, model: model.model]
      }

      {_req, resp} = Google.decode_response({mock_req, mock_resp})

      assert %ReqLLM.Response{} = resp.body
      response = resp.body

      assert response.message.reasoning_details != nil
      assert length(response.message.reasoning_details) == 1

      [detail] = response.message.reasoning_details
      assert %ReqLLM.Message.ReasoningDetails{} = detail
      assert detail.text == "Let me think about this..."
      assert detail.signature == "base64signature123"
      assert detail.encrypted? == true
      assert detail.provider == :google
      assert detail.format == "google-gemini-v1"
      assert detail.index == 0
      assert detail.provider_data == %{"thought" => true}
    end

    test "decode_response returns nil reasoning_details when no thought parts" do
      google_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"text" => "The answer is 42."}],
              "role" => "model"
            },
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 15,
          "totalTokenCount" => 25
        }
      }

      mock_resp = %Req.Response{
        status: 200,
        body: google_response
      }

      {:ok, model} = ReqLLM.model("google:gemini-2.5-flash")
      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false, model: model.model]
      }

      {_req, resp} = Google.decode_response({mock_req, mock_resp})

      assert %ReqLLM.Response{} = resp.body
      assert resp.body.message.reasoning_details == nil
    end

    test "encode_body includes thought parts from assistant message reasoning_details" do
      {:ok, model} = ReqLLM.model("google:gemini-2.5-flash")

      reasoning_detail = %ReqLLM.Message.ReasoningDetails{
        text: "Let me think step by step...",
        signature: "signatureABC123",
        encrypted?: true,
        provider: :google,
        format: "google-gemini-v1",
        index: 0,
        provider_data: %{"thought" => true}
      }

      assistant_message = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "The answer is 42."}],
        reasoning_details: [reasoning_detail]
      }

      user_message = %ReqLLM.Message{
        role: :user,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "What is the answer?"}]
      }

      context = %ReqLLM.Context{messages: [user_message, assistant_message]}

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      updated_request = Google.encode_body(mock_request)
      decoded = ReqLLM.Test.Helpers.json_body(updated_request)

      assert is_list(decoded["contents"])
      assert length(decoded["contents"]) == 2

      [_user_msg, model_msg] = decoded["contents"]
      assert model_msg["role"] == "model"

      parts = model_msg["parts"]
      assert length(parts) == 2

      [thought_part, text_part] = parts
      assert thought_part["thought"] == true
      assert thought_part["text"] == "Let me think step by step..."
      assert thought_part["thoughtSignature"] == "signatureABC123"

      assert text_part["text"] == "The answer is 42."
      refute Map.has_key?(text_part, "thought")
    end

    test "encode_body skips non-Google reasoning_details with warning" do
      import ExUnit.CaptureLog

      {:ok, model} = ReqLLM.model("google:gemini-2.5-flash")

      anthropic_detail = %ReqLLM.Message.ReasoningDetails{
        text: "Anthropic thinking...",
        signature: "anthropic-sig",
        encrypted?: false,
        provider: :anthropic,
        format: "anthropic-thinking-v1",
        index: 0,
        provider_data: %{"type" => "thinking"}
      }

      assistant_message = %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: "Response"}],
        reasoning_details: [anthropic_detail]
      }

      context = %ReqLLM.Context{messages: [assistant_message]}

      mock_request = %Req.Request{
        options: [
          context: context,
          model: model.model,
          stream: false
        ]
      }

      log =
        capture_log(fn ->
          updated_request = Google.encode_body(mock_request)
          decoded = ReqLLM.Test.Helpers.json_body(updated_request)

          [model_msg] = decoded["contents"]
          parts = model_msg["parts"]

          assert length(parts) == 1
          [text_part] = parts
          assert text_part["text"] == "Response"
          refute Map.has_key?(text_part, "thought")
        end)

      assert log =~ "Skipping non-Google reasoning detail"
    end
  end

  defp google_text_signature_body(parts) do
    %{
      "candidates" => [
        %{"content" => %{"role" => "model", "parts" => parts}, "finishReason" => "STOP"}
      ]
    }
  end

  defp decode_text_signature_response(body, model, context) do
    request = %Req.Request{options: [model: model.id, context: context, stream: false]}
    {_, response} = Google.decode_response({request, %Req.Response{status: 200, body: body}})
    response.body
  end

  defp google_text_signature_chunks(parts, model) do
    Enum.flat_map(parts, fn part ->
      event = %{data: google_text_signature_body([part])}
      Google.decode_stream_event(event, model)
    end)
  end

  defp text_signature_stream_response(chunks, model, context) do
    {:ok, handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn -> %{finish_reason: :stop} end)

    %ReqLLM.StreamResponse{
      stream: chunks,
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: model,
      context: context
    }
  end

  defp assert_text_signature_replay(response, model, expected_parts) do
    context = Context.new(response.context.messages ++ [Context.user("Continue")])

    assert {:ok, stream_request} = Google.attach_stream(model, context, [api_key: "test"], nil)
    stream_body = Jason.decode!(stream_request.body)

    assert {:ok, request} = Google.prepare_request(:chat, model, context, api_key: "test")
    body = request |> Google.encode_body() |> ReqLLM.Test.Helpers.json_body()

    for encoded <- [stream_body, body] do
      [assistant] = Enum.filter(encoded["contents"], &(&1["role"] == "model"))
      assert assistant["parts"] == expected_parts
    end
  end
end

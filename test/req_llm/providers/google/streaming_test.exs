defmodule ReqLLM.Providers.Google.StreamingTest do
  @moduledoc """
  Google stream protocol parsing, event decoding, and authentication.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Google, async: true

  alias ReqLLM.Context
  alias ReqLLM.Providers.Google

  describe "stream protocol parsing" do
    test "emits complete JSON array elements before the array is closed" do
      first = ~s([{"text":"hello"})
      second = ~s(,{"text":"world"})

      assert {:ok, [%{data: %{"text" => "hello"}}], state} =
               Google.parse_stream_protocol(first, nil)

      assert {:ok, [%{data: %{"text" => "world"}}], state} =
               Google.parse_stream_protocol(second, state)

      assert {:ok, [], nil} = Google.parse_stream_protocol("]", state)
    end

    test "buffers incomplete JSON array elements across chunks" do
      first = ~s([{"text":"hel)
      second = ~s(lo"})

      assert {:incomplete, state} = Google.parse_stream_protocol(first, nil)

      assert {:ok, [%{data: %{"text" => "hello"}}], state} =
               Google.parse_stream_protocol(second, state)

      assert {:ok, [], nil} = Google.parse_stream_protocol("]", state)
    end

    test "parses multiple JSON array elements from one chunk" do
      chunk = ~s([{"text":"hello"},{"text":"world"}])

      assert {:ok, events, nil} = Google.parse_stream_protocol(chunk, nil)

      assert events == [
               %{data: %{"text" => "hello"}},
               %{data: %{"text" => "world"}}
             ]
    end

    test "holds terminal JSON array elements until the array is closed" do
      first = ~s([{"text":"hello"})

      terminal =
        ~s(,{"candidates":[{"content":{"parts":[{"text":"done"}]},"finishReason":"STOP"}]})

      assert {:ok, [%{data: %{"text" => "hello"}}], state} =
               Google.parse_stream_protocol(first, nil)

      assert {:incomplete, state} = Google.parse_stream_protocol(terminal, state)

      assert {:ok, [event], nil} = Google.parse_stream_protocol("]", state)

      assert event == %{
               data: %{
                 "candidates" => [
                   %{
                     "content" => %{"parts" => [%{"text" => "done"}]},
                     "finishReason" => "STOP"
                   }
                 ]
               }
             }
    end

    test "holds usage-only JSON array terminal elements until the array is closed" do
      usage = ~s([{"usageMetadata":{"totalTokenCount":12}})

      assert {:incomplete, state} = Google.parse_stream_protocol(usage, nil)

      assert {:ok, [%{data: %{"usageMetadata" => %{"totalTokenCount" => 12}}}], nil} =
               Google.parse_stream_protocol("]", state)
    end

    test "waits for complete JSON array when strings contain delimiters" do
      first = ~s([{"text":"look ] here and \\"quote\\"")
      second = ~s(}])

      assert {:incomplete, state} = Google.parse_stream_protocol(first, nil)

      assert {:ok, [%{data: %{"text" => ~s(look ] here and "quote")}}], nil} =
               Google.parse_stream_protocol(second, state)
    end

    test "returns an error for complete malformed JSON array streams" do
      chunk = ~s([{"text":}])

      assert {:error, {:invalid_json_array_stream, %Jason.DecodeError{}}} =
               Google.parse_stream_protocol(chunk, nil)
    end

    test "delegates SSE chunks to SSE parser" do
      chunk = ~s(data: {"text":"hello"}\n\n)

      assert {:ok, [%{data: ~s({"text":"hello"})}], state} =
               Google.parse_stream_protocol(chunk, nil)

      assert %ServerSentEvents.Parser{} = state
    end
  end

  describe "decode_stream_event/2 finish_reason capture" do
    setup do
      {:ok, model: %LLMDB.Model{id: "gemini-2.5-flash", provider: :google}}
    end

    test "finishReason on candidate without content.parts + usageMetadata", %{model: model} do
      event = %{
        data: %{
          "candidates" => [%{"finishReason" => "STOP", "index" => 0}],
          "usageMetadata" => %{
            "promptTokenCount" => 10,
            "candidatesTokenCount" => 5,
            "totalTokenCount" => 15
          }
        }
      }

      [meta_chunk] = Google.decode_stream_event(event, model)
      assert meta_chunk.type == :meta
      assert meta_chunk.metadata[:finish_reason] == "stop"
      assert meta_chunk.metadata[:terminal?] == true
      assert meta_chunk.metadata[:usage][:input_tokens] == 10
    end

    test "streaming usageMetadata includes thought tokens in output usage", %{model: model} do
      event = %{
        data: %{
          "candidates" => [%{"finishReason" => "STOP", "index" => 0}],
          "usageMetadata" => %{
            "promptTokenCount" => 10,
            "candidatesTokenCount" => 15,
            "thoughtsTokenCount" => 5,
            "totalTokenCount" => 30
          }
        }
      }

      [meta_chunk] = Google.decode_stream_event(event, model)
      assert meta_chunk.type == :meta
      assert meta_chunk.metadata[:usage][:input_tokens] == 10
      assert meta_chunk.metadata[:usage][:output_tokens] == 20
      assert meta_chunk.metadata[:usage][:total_tokens] == 30
      assert meta_chunk.metadata[:usage][:reasoning_tokens] == 5
    end

    test "streaming usageMetadata exposes tool-use input tokens", %{model: model} do
      event = %{
        data: %{
          "candidates" => [%{"finishReason" => "STOP", "index" => 0}],
          "usageMetadata" => %{
            "promptTokenCount" => 31,
            "candidatesTokenCount" => 73,
            "thoughtsTokenCount" => 77,
            "toolUsePromptTokenCount" => 73,
            "totalTokenCount" => 254
          }
        }
      }

      [meta_chunk] = Google.decode_stream_event(event, model)
      usage = meta_chunk.metadata.usage

      assert usage.input_tokens == 31
      assert usage.output_tokens == 150
      assert usage.tool_use_input_tokens == 73
      assert usage.total_tokens == 254
    end

    test "streaming usageMetadata derives totals from partial counts", %{model: model} do
      event = %{
        data: %{
          "candidates" => [%{"finishReason" => "STOP", "index" => 0}],
          "usageMetadata" => %{
            "candidatesTokenCount" => 486,
            "thoughtsTokenCount" => 4297
          }
        }
      }

      [meta_chunk] = Google.decode_stream_event(event, model)
      assert meta_chunk.type == :meta
      assert meta_chunk.metadata[:usage][:input_tokens] == 0
      assert meta_chunk.metadata[:usage][:output_tokens] == 4783
      assert meta_chunk.metadata[:usage][:total_tokens] == 4783
      assert meta_chunk.metadata[:usage][:reasoning_tokens] == 4297
    end

    test "finishReason on candidate without content.parts (no usage)", %{model: model} do
      event = %{data: %{"candidates" => [%{"finishReason" => "STOP", "index" => 0}]}}

      [meta_chunk] = Google.decode_stream_event(event, model)
      assert meta_chunk.type == :meta
      assert meta_chunk.metadata[:finish_reason] == "stop"
      assert meta_chunk.metadata[:terminal?] == true
    end

    test "finishReason on candidate with content role but no parts key", %{model: model} do
      event = %{
        data: %{
          "candidates" => [
            %{"content" => %{"role" => "model"}, "finishReason" => "STOP", "index" => 0}
          ],
          "usageMetadata" => %{"promptTokenCount" => 1, "totalTokenCount" => 1}
        }
      }

      [meta_chunk] = Google.decode_stream_event(event, model)
      assert meta_chunk.type == :meta
      assert meta_chunk.metadata[:finish_reason] == "stop"
      assert meta_chunk.metadata[:terminal?] == true
    end

    test "preserves raw finishReason and finishMessage on abnormal finishes", %{model: model} do
      event = %{
        data: %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [%{"text" => "", "thoughtSignature" => "sig"}],
                "role" => "model"
              },
              "finishReason" => "MALFORMED_FUNCTION_CALL",
              "finishMessage" =>
                "Malformed function call: Failed to parse function call: Function call is empty - no input to parse.",
              "index" => 0
            }
          ],
          "usageMetadata" => %{
            "promptTokenCount" => 10,
            "candidatesTokenCount" => 5,
            "totalTokenCount" => 15
          }
        }
      }

      chunks = Google.decode_stream_event(event, model)
      meta_chunk = Enum.find(chunks, &(&1.type == :meta))
      assert meta_chunk.metadata[:finish_reason] == "error"
      assert meta_chunk.metadata[:finish_reason_raw] == "MALFORMED_FUNCTION_CALL"
      assert meta_chunk.metadata[:finish_message] =~ "Function call is empty"
      assert meta_chunk.metadata[:terminal?] == true
    end

    test "preserves raw finishReason without finishMessage", %{model: model} do
      event = %{
        data: %{"candidates" => [%{"finishReason" => "UNEXPECTED_TOOL_CALL", "index" => 0}]}
      }

      [meta_chunk] = Google.decode_stream_event(event, model)
      assert meta_chunk.metadata[:finish_reason] == "error"
      assert meta_chunk.metadata[:finish_reason_raw] == "UNEXPECTED_TOOL_CALL"
      refute Map.has_key?(meta_chunk.metadata, :finish_message)
    end

    test "normal STOP finishes carry the raw reason too", %{model: model} do
      event = %{data: %{"candidates" => [%{"finishReason" => "STOP", "index" => 0}]}}

      [meta_chunk] = Google.decode_stream_event(event, model)
      assert meta_chunk.metadata[:finish_reason] == "stop"
      assert meta_chunk.metadata[:finish_reason_raw] == "STOP"
    end

    test "policy stops normalize to content_filter like SAFETY", %{model: model} do
      for reason <- [
            "BLOCKLIST",
            "PROHIBITED_CONTENT",
            "SPII",
            "LANGUAGE",
            "IMAGE_SAFETY",
            "IMAGE_PROHIBITED_CONTENT",
            "IMAGE_RECITATION"
          ] do
        event = %{data: %{"candidates" => [%{"finishReason" => reason, "index" => 0}]}}

        [meta_chunk] = Google.decode_stream_event(event, model)

        assert meta_chunk.metadata[:finish_reason] == "content_filter",
               "#{reason} should be a content filter stop, got #{inspect(meta_chunk.metadata[:finish_reason])}"
      end
    end

    # These are stops, but not content flags, and they want handling the
    # content_filter path cannot give them ("the model refused" would be wrong).
    # Pinning them keeps a later pass from sweeping the whole enum into
    # content_filter for tidiness.
    test "non-content-flag stops stay error", %{model: model} do
      for reason <- [
            "UNEXPECTED_TOOL_CALL",
            "TOO_MANY_TOOL_CALLS",
            "NO_IMAGE",
            "IMAGE_OTHER",
            "OTHER"
          ] do
        event = %{data: %{"candidates" => [%{"finishReason" => reason, "index" => 0}]}}

        [meta_chunk] = Google.decode_stream_event(event, model)

        assert meta_chunk.metadata[:finish_reason] == "error",
               "#{reason} is not a content flag and should stay error, got #{inspect(meta_chunk.metadata[:finish_reason])}"
      end
    end

    # Body captured verbatim from gemini-2.5-pro on the non-streaming endpoint
    # with no tools declared: the candidate carries only a finishReason and no
    # "content" key. This used to fall through to the catch-all and report
    # "stop", making a provider abort look like a successful empty answer.
    test "non-streaming abort with no content keeps its reason and raw name" do
      google_response = %{
        "candidates" => [
          %{
            "finishReason" => "UNEXPECTED_TOOL_CALL",
            "finishMessage" => "Unexpected tool call",
            "index" => 0
          }
        ],
        "usageMetadata" => %{"promptTokenCount" => 22, "totalTokenCount" => 22},
        "modelVersion" => "gemini-2.5-pro"
      }

      mock_resp = %Req.Response{status: 200, body: google_response}
      {:ok, model} = ReqLLM.model("google:gemini-2.5-pro")

      mock_req = %Req.Request{
        options: [context: context_fixture(), stream: false, model: model.model]
      }

      {_req, resp} = Google.decode_response({mock_req, mock_resp})

      refute ReqLLM.Response.finish_reason(resp.body) == :stop,
             "an abort must not be reported as a clean stop"

      assert ReqLLM.Response.finish_reason(resp.body) == :error
      assert resp.body.provider_meta["finish_reason_raw"] == "UNEXPECTED_TOOL_CALL"
      assert resp.body.provider_meta["finish_message"] == "Unexpected tool call"
    end

    test "usageMetadata alone still has no finish_reason (unchanged)", %{model: model} do
      event = %{
        data: %{
          "usageMetadata" => %{"promptTokenCount" => 1, "totalTokenCount" => 1}
        }
      }

      [meta_chunk] = Google.decode_stream_event(event, model)
      assert meta_chunk.type == :meta
      refute Map.has_key?(meta_chunk.metadata, :finish_reason)
      assert meta_chunk.metadata[:terminal?] == true
    end

    test "content.parts + finishReason still preferred (regression)", %{model: model} do
      event = %{
        data: %{
          "candidates" => [
            %{
              "content" => %{"parts" => [%{"text" => "hello"}], "role" => "model"},
              "finishReason" => "STOP"
            }
          ],
          "usageMetadata" => %{"promptTokenCount" => 2, "totalTokenCount" => 2}
        }
      }

      chunks = Google.decode_stream_event(event, model)
      assert Enum.any?(chunks, &match?(%{type: :content, text: "hello"}, &1))
      meta_chunk = Enum.find(chunks, &(&1.type == :meta))
      assert meta_chunk.metadata[:finish_reason] == "stop"
    end
  end

  describe "google_auth_header option for streaming" do
    setup do
      {:ok, model} = ReqLLM.model("google:gemini-2.0-flash-exp")
      context = Context.new([Context.user("test")])
      {:ok, model: model, context: context}
    end

    test "default streaming uses header auth", %{model: model, context: context} do
      opts = [api_key: "test-api-key"]

      {:ok, finch_request} = Google.attach_stream(model, context, opts, nil)

      assert finch_request.query == "alt=sse"
      assert has_header_value?(finch_request.headers, "x-goog-api-key", "test-api-key")
    end

    test "google_auth_header: true uses header auth instead of query param", %{
      model: model,
      context: context
    } do
      opts = [
        api_key: "test-api-key",
        provider_options: [google_auth_header: true]
      ]

      {:ok, finch_request} = Google.attach_stream(model, context, opts, nil)

      refute finch_request.query =~ "key="
      assert finch_request.query == "alt=sse"
      assert has_header_value?(finch_request.headers, "x-goog-api-key", "test-api-key")
    end

    test "google_auth_header: false opts into query auth", %{model: model, context: context} do
      opts = [
        api_key: "test-api-key",
        provider_options: [google_auth_header: false]
      ]

      {:ok, finch_request} = Google.attach_stream(model, context, opts, nil)

      assert finch_request.query =~ "key=test-api-key"
      assert finch_request.query =~ "alt=sse"
      refute has_header?(finch_request.headers, "x-goog-api-key")
    end

    test "debug logging redacts query auth", %{model: model, context: context} do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert {:ok, _request} =
                   Google.attach_stream(
                     model,
                     context,
                     [
                       api_key: "query-auth-secret",
                       provider_options: [google_auth_header: false]
                     ],
                     nil
                   )
        end)

      assert log =~ "key=[REDACTED]"
      refute log =~ "query-auth-secret"
    end

    test "debug logging excludes the default auth credential", %{model: model, context: context} do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert {:ok, _request} =
                   Google.attach_stream(model, context, [api_key: "header-auth-secret"], nil)
        end)

      assert log =~ "alt=sse"
      refute log =~ "header-auth-secret"
    end

    test "google_auth_header works with custom base_url for proxies", %{
      model: model,
      context: context
    } do
      opts = [
        api_key: "proxy-api-key",
        base_url: "https://openai-proxy.example.com/v1",
        provider_options: [google_auth_header: true]
      ]

      {:ok, finch_request} = Google.attach_stream(model, context, opts, nil)

      assert finch_request.host == "openai-proxy.example.com"
      refute finch_request.query =~ "key="
      assert has_header_value?(finch_request.headers, "x-goog-api-key", "proxy-api-key")
    end

    defp has_header?(headers, name) do
      Enum.any?(headers, fn {n, _v} -> n == name end)
    end

    defp has_header_value?(headers, name, value) do
      Enum.any?(headers, fn {n, v} -> n == name and v == value end)
    end
  end
end

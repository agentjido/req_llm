defmodule ReqLLM.Providers.Google.ResponseDecodingTest do
  @moduledoc """
  Google response decoding and usage normalization.
  """

  use ReqLLM.ProviderCase, provider: ReqLLM.Providers.Google, async: true

  alias ReqLLM.Providers.Google

  describe "response decoding" do
    test "decode_response handles non-streaming responses" do
      # Create a mock Google response
      google_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"text" => "Hello there! How can I help you today?"}],
              "role" => "model"
            },
            "finishReason" => "STOP",
            "safetyRatings" => []
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 15,
          "totalTokenCount" => 25
        }
      }

      # Create a mock Req response
      mock_resp = %Req.Response{
        status: 200,
        body: google_response
      }

      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false, model: model.model]
      }

      # Test decode_response directly
      {req, resp} = Google.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Response{} = resp.body

      response = resp.body
      assert is_binary(response.id)
      assert response.model == model.model
      assert response.stream? == false

      # Verify message normalization
      assert response.message.role == :assistant
      text = ReqLLM.Response.text(response)
      assert text == "Hello there! How can I help you today?"
      assert response.finish_reason == :stop

      # Verify usage normalization
      assert response.usage.input_tokens == 10
      assert response.usage.output_tokens == 15
      assert response.usage.total_tokens == 25

      # Verify context advancement (original + assistant)
      assert length(response.context.messages) == 3
      assert List.last(response.context.messages).role == :assistant
    end

    test "decode_response extracts cached token counts" do
      # Create a mock Google response with cached tokens
      google_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"text" => "Response using cached context"}],
              "role" => "model"
            },
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 1500,
          "candidatesTokenCount" => 50,
          "totalTokenCount" => 1550,
          "cachedContentTokenCount" => 1200
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

      # Verify cached tokens are extracted
      assert response.usage.cached_tokens == 1200
      assert response.usage.input_tokens == 1500
      assert response.usage.output_tokens == 50
      assert response.usage.total_tokens == 1550
    end

    test "decode_response includes thought tokens in output usage" do
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
          "thoughtsTokenCount" => 5,
          "totalTokenCount" => 30
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
      assert response.usage.input_tokens == 10
      assert response.usage.output_tokens == 20
      assert response.usage.total_tokens == 30
      assert response.usage.reasoning_tokens == 5
    end

    test "decode_response derives usage from partial usageMetadata" do
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
          "candidatesTokenCount" => 486,
          "thoughtsTokenCount" => 4297,
          "serviceTier" => "standard"
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
      assert response.usage.input_tokens == 0
      assert response.usage.output_tokens == 4783
      assert response.usage.total_tokens == 4783
      assert response.usage.reasoning_tokens == 4297
    end

    test "decode_response derives prompt tokens from usage detail entries" do
      google_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"text" => ~s({"summary":"ok"})}],
              "role" => "model"
            },
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => %{
          "promptTokensDetails" => [
            %{"modality" => "TEXT", "tokenCount" => 12},
            %{"modality" => "IMAGE", "tokenCount" => 5}
          ],
          "candidatesTokenCount" => 3,
          "thoughtsTokenCount" => 2
        }
      }

      mock_resp = %Req.Response{
        status: 200,
        body: google_response
      }

      {:ok, model} = ReqLLM.model("google:gemini-2.5-flash")
      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false, operation: :object, model: model.model]
      }

      {_req, resp} = Google.decode_response({mock_req, mock_resp})

      assert %ReqLLM.Response{} = resp.body
      response = resp.body
      assert response.object == %{"summary" => "ok"}
      assert response.usage.input_tokens == 17
      assert response.usage.output_tokens == 5
      assert response.usage.total_tokens == 22
      assert response.usage.reasoning_tokens == 2
    end

    test "decode_response preserves tool calls" do
      google_response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "functionCall" => %{
                    "name" => "demo_tool",
                    "args" => %{"payload" => "value"},
                    "id" => "call-1"
                  }
                }
              ],
              "role" => "model"
            },
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 12,
          "candidatesTokenCount" => 3,
          "totalTokenCount" => 15
        }
      }

      mock_resp = %Req.Response{status: 200, body: google_response}

      context = context_fixture()

      mock_req = %Req.Request{
        options: [context: context, stream: false, id: "gemini-1.5-flash"]
      }

      {_req, resp} = Google.decode_response({mock_req, mock_resp})

      response = resp.body
      assert %ReqLLM.Response{} = response

      assert [tool_call] = ReqLLM.Response.tool_calls(response)
      assert tool_call.function.name == "demo_tool"
      assert tool_call.id == "call-1"
      # Bug #271 fix: Google returns "STOP" even with tool calls, but we correctly
      # detect tool calls and return :tool_calls finish_reason
      assert ReqLLM.Response.finish_reason(response) == :tool_calls
    end

    test "decode_response handles streaming responses" do
      # Create mock streaming chunks (Google format)
      stream_chunks = [
        %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello"}]}}]},
        %{"candidates" => [%{"content" => %{"parts" => [%{"text" => " world"}]}}]},
        %{"candidates" => [%{"finishReason" => "STOP"}]}
      ]

      # Create a mock stream
      mock_stream = Stream.map(stream_chunks, & &1)

      # Create a mock Req response with streaming body
      mock_resp = %Req.Response{
        status: 200,
        body: mock_stream
      }

      # Create a mock request with context and model
      context = context_fixture()
      model = "gemini-1.5-flash"

      mock_req = %Req.Request{
        options: [context: context, stream: true, model: model]
      }

      # Test decode_response directly
      {req, resp} = Google.decode_response({mock_req, mock_resp})

      assert req == mock_req
      assert %ReqLLM.Response{} = resp.body

      response = resp.body
      assert response.stream? == true
      assert is_struct(response.stream, Stream)
      assert response.model == model

      # Verify context is preserved (original messages only in streaming)
      assert length(response.context.messages) == 2

      # Verify stream structure and processing
      assert response.usage == %{
               input_tokens: 0,
               output_tokens: 0,
               total_tokens: 0,
               cached_tokens: 0,
               reasoning_tokens: 0
             }

      assert response.finish_reason == nil
      assert response.provider_meta == %{}
    end

    test "decode_response for embedding returns normalized OpenAI format" do
      embedding_response = %{
        "embedding" => %{
          "values" => [0.1, -0.2, 0.3, 0.4, -0.5]
        },
        "usageMetadata" => %{
          "promptTokenCount" => 2,
          "totalTokenCount" => 2
        }
      }

      mock_resp = %Req.Response{
        status: 200,
        body: embedding_response
      }

      mock_req = %Req.Request{
        options: [operation: :embedding, id: "gemini-embedding-001"]
      }

      {req, resp} = Google.decode_response({mock_req, mock_resp})

      assert req == mock_req

      assert resp.body == %{
               "data" => [%{"index" => 0, "embedding" => [0.1, -0.2, 0.3, 0.4, -0.5]}],
               "usageMetadata" => %{
                 "promptTokenCount" => 2,
                 "totalTokenCount" => 2
               }
             }
    end
  end

  describe "usage extraction" do
    test "extract_usage with valid usage data" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

      body_with_usage = %{
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 20,
          "totalTokenCount" => 30
        }
      }

      {:ok, usage} = Google.extract_usage(body_with_usage, model)
      assert usage.input_tokens == 10
      assert usage.output_tokens == 20
      assert usage.total_tokens == 30
    end

    test "extract_usage exposes tool-use input tokens" do
      model = ReqLLM.model!("google:gemini-2.5-flash")

      body = %{
        "usageMetadata" => %{
          "promptTokenCount" => 31,
          "candidatesTokenCount" => 73,
          "thoughtsTokenCount" => 77,
          "toolUsePromptTokenCount" => 73,
          "totalTokenCount" => 254
        }
      }

      assert {:ok, usage} = Google.extract_usage(body, model)
      assert usage.input_tokens == 31
      assert usage.output_tokens == 150
      assert usage.tool_use_input_tokens == 73
      assert usage.total_tokens == 254
    end

    test "extract_usage excludes tool-use input from fallback output tokens" do
      model = ReqLLM.model!("google:gemini-2.5-flash")

      body = %{
        "usageMetadata" => %{
          "promptTokenCount" => 31,
          "toolUsePromptTokenCount" => 73,
          "totalTokenCount" => 254
        }
      }

      assert {:ok, usage} = Google.extract_usage(body, model)
      assert usage.input_tokens == 31
      assert usage.output_tokens == 150
      assert usage.tool_use_input_tokens == 73
      assert usage.total_tokens == 254
    end

    test "decode_response exposes tool-use input tokens" do
      model = ReqLLM.model!("google:gemini-2.5-flash")

      body = %{
        "candidates" => [
          %{
            "content" => %{"parts" => [%{"text" => "Grounded answer"}], "role" => "model"},
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 31,
          "candidatesTokenCount" => 73,
          "thoughtsTokenCount" => 77,
          "toolUsePromptTokenCount" => 73,
          "totalTokenCount" => 254
        }
      }

      request = %Req.Request{
        options: [context: context_fixture(), stream: false, model: model.model]
      }

      {_request, response} =
        Google.decode_response({request, %Req.Response{status: 200, body: body}})

      usage = response.body.usage

      assert usage.input_tokens == 31
      assert usage.output_tokens == 150
      assert usage.tool_use_input_tokens == 73
      assert usage.total_tokens == 254
    end

    test "extract_usage with missing usage data" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")
      body_without_usage = %{"candidates" => []}

      {:error, :no_usage_found} = Google.extract_usage(body_without_usage, model)
    end

    test "extract_usage with invalid body type" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

      {:error, :invalid_body} = Google.extract_usage("invalid", model)
      {:error, :invalid_body} = Google.extract_usage(nil, model)
      {:error, :invalid_body} = Google.extract_usage(123, model)
    end

    test "extract_usage with cached content tokens" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

      body_with_cached_tokens = %{
        "usageMetadata" => %{
          "promptTokenCount" => 500,
          "candidatesTokenCount" => 200,
          "totalTokenCount" => 700,
          "cachedContentTokenCount" => 120
        }
      }

      {:ok, usage} = Google.extract_usage(body_with_cached_tokens, model)
      assert usage.input_tokens == 500
      assert usage.output_tokens == 200
      assert usage.total_tokens == 700
      assert usage.cached_tokens == 120
    end

    test "extract_usage without cached content tokens" do
      {:ok, model} = ReqLLM.model("google:gemini-1.5-flash")

      body_without_cached_tokens = %{
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 20,
          "totalTokenCount" => 30
        }
      }

      {:ok, usage} = Google.extract_usage(body_without_cached_tokens, model)
      assert usage.input_tokens == 10
      assert usage.output_tokens == 20
      assert usage.total_tokens == 30
      assert usage.cached_tokens == 0
    end

    test "extract_usage includes image usage when inline data is present" do
      model = %LLMDB.Model{provider: :google, id: "gemini-2.5-flash-image"}

      body_with_image = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [
                %{
                  "inlineData" => %{
                    "mimeType" => "image/png",
                    "data" => "AAA"
                  }
                }
              ]
            }
          }
        ]
      }

      {:ok, usage} = Google.extract_usage(body_with_image, model)
      assert usage.image_usage.generated.count == 1
    end

    test "extract_usage counts web searches when pricing unit is query" do
      model = %LLMDB.Model{
        id: "gemini-query-billed",
        provider: :google,
        pricing: %{
          components: [
            %{
              id: "tool.web_search",
              kind: "tool",
              tool: "web_search",
              unit: "query",
              per: 1000,
              rate: 14.0
            }
          ]
        }
      }

      body = %{
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 20,
          "totalTokenCount" => 30
        },
        "candidates" => [
          %{
            "groundingMetadata" => %{
              "webSearchQueries" => ["q1", "q2"]
            }
          }
        ]
      }

      {:ok, usage} = Google.extract_usage(body, model)
      assert usage[:tool_usage][:web_search][:count] == 2
      assert usage[:tool_usage][:web_search][:unit] == "query"
    end

    test "extract_usage defaults web search count to 1 when pricing unit is not query" do
      model = %LLMDB.Model{
        id: "gemini-2.5-flash",
        provider: :google,
        pricing: %{
          components: [
            %{
              id: "tool.web_search",
              kind: "tool",
              tool: "web_search",
              unit: "call",
              per: 1000,
              rate: 35.0
            }
          ]
        }
      }

      body = %{
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 20,
          "totalTokenCount" => 30
        },
        "candidates" => [
          %{
            "groundingMetadata" => %{
              "webSearchQueries" => ["q1", "q2"]
            }
          }
        ]
      }

      {:ok, usage} = Google.extract_usage(body, model)
      assert usage[:tool_usage][:web_search][:count] == 1
      assert usage[:tool_usage][:web_search][:unit] == "call"
    end

    test "extract_usage handles missing web search pricing component" do
      model = %LLMDB.Model{id: "gemini-no-pricing", provider: :google, pricing: nil}

      body = %{
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 20,
          "totalTokenCount" => 30
        },
        "candidates" => [
          %{
            "groundingMetadata" => %{
              "webSearchQueries" => ["q1", "q2"]
            }
          }
        ]
      }

      {:ok, usage} = Google.extract_usage(body, model)
      assert usage[:tool_usage][:web_search][:count] == 1
      assert usage[:tool_usage][:web_search][:unit] == :call
    end
  end
end

defmodule ReqLLM.Providers.GoogleVertex.OpenAICompatTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias ReqLLM.Providers.GoogleVertex
  alias ReqLLM.Providers.GoogleVertex.OpenAICompat

  defp context_fixture(user_message \\ "Hello, how are you?") do
    Context.new([
      Context.system("You are a helpful assistant."),
      Context.user(user_message)
    ])
  end

  describe "endpoint routing" do
    test "openai_compat model routes to endpoints/openapi/chat/completions" do
      {:ok, model} = ReqLLM.model("google_vertex:zai-org/glm-4.7-maas")
      context = context_fixture()

      opts = [
        access_token: "fake-token",
        project_id: "test-project",
        region: "us-central1"
      ]

      {:ok, request} = GoogleVertex.prepare_request(:chat, model, context, opts)
      url = URI.to_string(request.url)

      assert url =~
               "endpoints/openapi/chat/completions"

      refute url =~ "publishers/"
      refute url =~ "rawPredict"
    end

    test "openai_compat streaming routes to endpoints/openapi/chat/completions" do
      {:ok, model} = ReqLLM.model("google_vertex:zai-org/glm-4.7-maas")
      context = context_fixture()

      opts = [
        access_token: "fake-token",
        project_id: "test-project",
        region: "us-central1"
      ]

      {:ok, finch_request} = GoogleVertex.attach_stream(model, context, opts, nil)

      assert finch_request.path =~ "endpoints/openapi/chat/completions"
      refute finch_request.path =~ "publishers/"
      refute finch_request.path =~ "streamRawPredict"
    end

    test "openai_compat model includes project and region in path" do
      {:ok, model} = ReqLLM.model("google_vertex:zai-org/glm-4.7-maas")
      context = context_fixture()

      opts = [
        access_token: "fake-token",
        project_id: "my-project",
        region: "europe-west1"
      ]

      {:ok, request} = GoogleVertex.prepare_request(:chat, model, context, opts)
      url = URI.to_string(request.url)

      assert url =~ "projects/my-project"
      assert url =~ "locations/europe-west1"
    end
  end

  describe "model family resolution" do
    test "GLM model resolves to openai_compat formatter via extra.family" do
      {:ok, model} = ReqLLM.model("google_vertex:zai-org/glm-4.7-maas")

      assert model.extra[:family] == "glm"

      # Verify it doesn't raise and routes through the openai_compat path
      # by calling extract_usage (which internally calls get_formatter -> get_model_family)
      body = %{"usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}}
      assert {:ok, _} = GoogleVertex.extract_usage(body, model)
    end

    test "GPT-OSS model resolves to openai_compat formatter via extra.family" do
      {:ok, model} = ReqLLM.model("google_vertex:openai/gpt-oss-120b-maas")

      assert model.extra[:family] == "gpt-oss"

      body = %{"usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}}
      assert {:ok, _} = GoogleVertex.extract_usage(body, model)
    end

    test "Claude model still resolves via prefix matching" do
      {:ok, model} = ReqLLM.model("google_vertex:claude-haiku-4-5@20251001")

      # Claude models have claude-prefixed extra.family values too,
      # but should be caught by the primary prefix match on model ID
      body = %{"usage" => %{"input_tokens" => 10, "output_tokens" => 5}}
      assert {:ok, _} = GoogleVertex.extract_usage(body, model)
    end

    test "Gemini model still resolves via prefix matching" do
      {:ok, model} = ReqLLM.model("google_vertex:gemini-2.5-flash")

      body = %{
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 5,
          "totalTokenCount" => 15
        }
      }

      assert {:ok, _} = GoogleVertex.extract_usage(body, model)
    end

    test "model with no extra.family raises ArgumentError" do
      model = LLMDB.Model.new!(%{id: "unknown-model", provider: :google_vertex})

      assert_raise ArgumentError, ~r/Unknown model family/, fn ->
        GoogleVertex.extract_usage(%{}, model)
      end
    end

    test "model with nil extra raises ArgumentError" do
      model = LLMDB.Model.new!(%{id: "unknown-model", provider: :google_vertex, extra: nil})

      assert_raise ArgumentError, ~r/Unknown model family/, fn ->
        GoogleVertex.extract_usage(%{}, model)
      end
    end
  end

  describe "format_request/3" do
    test "produces OpenAI Chat Completions format" do
      context = context_fixture()
      opts = [max_tokens: 1024]

      body = OpenAICompat.format_request("zai-org/glm-4.7-maas", context, opts)

      assert body[:model] == "zai-org/glm-4.7-maas"
      assert is_list(body[:messages])
      assert length(body[:messages]) >= 2

      system_msg = Enum.find(body[:messages], &(&1[:role] == "system"))
      assert system_msg[:content] =~ "helpful assistant"

      user_msg = Enum.find(body[:messages], &(&1[:role] == "user"))
      assert user_msg != nil
    end

    test "includes temperature and max_tokens when provided" do
      context = context_fixture()
      opts = [temperature: 0.7, max_tokens: 2048]

      body = OpenAICompat.format_request("zai-org/glm-4.7-maas", context, opts)

      assert body[:temperature] == 0.7
      assert body[:max_tokens] == 2048
    end

    test "includes stream flag when set" do
      context = context_fixture()
      opts = [stream: true]

      body = OpenAICompat.format_request("zai-org/glm-4.7-maas", context, opts)

      assert body[:stream] == true
    end

    test "works with different model IDs" do
      context = context_fixture()
      opts = []

      body = OpenAICompat.format_request("openai/gpt-oss-120b-maas", context, opts)

      assert body[:model] == "openai/gpt-oss-120b-maas"
      assert is_list(body[:messages])
    end

    test "injects structured_output tool for :object operation" do
      context = context_fixture("Extract the name")

      {:ok, schema} =
        ReqLLM.Schema.compile(name: [type: :string, required: true, doc: "The name"])

      opts = [operation: :object, compiled_schema: schema]

      body = OpenAICompat.format_request("zai-org/glm-4.7-maas", context, opts)

      # Should have tools with structured_output
      assert is_list(body[:tools])

      tool_names =
        Enum.map(body[:tools], fn t ->
          get_in(t, [:function, :name]) || get_in(t, ["function", "name"])
        end)

      assert "structured_output" in tool_names

      # Should force tool_choice to structured_output
      assert body[:tool_choice] == %{type: "function", function: %{name: "structured_output"}}
    end
  end

  describe "parse_response/3" do
    test "parses standard OpenAI response format" do
      model = LLMDB.Model.new!(%{id: "zai-org/glm-4.7-maas", provider: :google_vertex})

      body = %{
        "id" => "chatcmpl-123",
        "model" => "glm-4.7-maas",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => "Hello! I'm doing well, thank you for asking."
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 20,
          "completion_tokens" => 12,
          "total_tokens" => 32
        }
      }

      assert {:ok, response} = OpenAICompat.parse_response(body, model, [])
      assert response.message.role == :assistant

      text = ReqLLM.Response.text(response)
      assert text =~ "Hello!"
    end

    test "parses response with tool calls" do
      model = LLMDB.Model.new!(%{id: "zai-org/glm-4.7-maas", provider: :google_vertex})

      body = %{
        "id" => "chatcmpl-456",
        "model" => "glm-4.7-maas",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "call_abc",
                  "type" => "function",
                  "function" => %{
                    "name" => "get_weather",
                    "arguments" => ~s({"location": "San Francisco"})
                  }
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 30,
          "completion_tokens" => 15,
          "total_tokens" => 45
        }
      }

      assert {:ok, response} = OpenAICompat.parse_response(body, model, [])
      assert response.finish_reason == :tool_calls
    end

    test "merges with input context" do
      model = LLMDB.Model.new!(%{id: "zai-org/glm-4.7-maas", provider: :google_vertex})

      input_context =
        Context.new([
          Context.system("You are helpful."),
          Context.user("Hi")
        ])

      body = %{
        "id" => "chatcmpl-789",
        "model" => "glm-4.7-maas",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{
              "role" => "assistant",
              "content" => "Hello there!"
            },
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{
          "prompt_tokens" => 10,
          "completion_tokens" => 5,
          "total_tokens" => 15
        }
      }

      assert {:ok, response} = OpenAICompat.parse_response(body, model, context: input_context)
      # Should have the input messages plus the assistant response
      assert length(response.context.messages) >= 2
    end
  end

  describe "extract_usage/2" do
    test "extracts usage from standard OpenAI format" do
      model = LLMDB.Model.new!(%{id: "zai-org/glm-4.7-maas", provider: :google_vertex})

      body = %{
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 50,
          "total_tokens" => 150
        }
      }

      assert {:ok, usage} = OpenAICompat.extract_usage(body, model)
      assert usage["prompt_tokens"] == 100
      assert usage["completion_tokens"] == 50
    end

    test "returns error when no usage field" do
      model = LLMDB.Model.new!(%{id: "zai-org/glm-4.7-maas", provider: :google_vertex})

      assert {:error, _} = OpenAICompat.extract_usage(%{}, model)
    end
  end

  describe "decode_stream_event/2" do
    test "decodes content delta" do
      model = LLMDB.Model.new!(%{id: "zai-org/glm-4.7-maas", provider: :google_vertex})

      event = %{
        data: %{
          "id" => "chatcmpl-stream",
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "content" => "Hello"
              }
            }
          ]
        }
      }

      chunks = OpenAICompat.decode_stream_event(event, model)
      assert is_list(chunks)
      assert length(chunks) > 0
    end

    test "handles terminal [DONE] event" do
      model = LLMDB.Model.new!(%{id: "zai-org/glm-4.7-maas", provider: :google_vertex})

      event = %{data: "[DONE]"}

      chunks = OpenAICompat.decode_stream_event(event, model)
      assert is_list(chunks)
      assert length(chunks) > 0
    end
  end
end

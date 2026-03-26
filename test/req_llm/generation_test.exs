defmodule ReqLLM.GenerationTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Context, Generation, Response, StreamResponse}

  @chat_model "openai:gpt-4-turbo"

  defmodule CacheBackend do
    alias ReqLLM.Context
    alias ReqLLM.Message
    alias ReqLLM.Message.ContentPart

    def get(key, opts) do
      agent = Keyword.fetch!(opts, :agent)

      Agent.get(agent, fn state ->
        case Map.fetch(state.entries, key) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, :not_found}
        end
      end)
    end

    def put(key, value, ttl, opts) do
      agent = Keyword.fetch!(opts, :agent)

      Agent.update(agent, fn state ->
        state
        |> Map.update!(:puts, &(&1 + 1))
        |> put_in([:entries, key], %{
          value
          | provider_meta: Map.put(value.provider_meta, :ttl, ttl)
        })
      end)

      :ok
    end

    def delete(key, opts) do
      agent = Keyword.fetch!(opts, :agent)
      Agent.update(agent, fn state -> update_in(state.entries, &Map.delete(&1, key)) end)
      :ok
    end

    def generate_key(model, request, opts) do
      namespace = Keyword.get(opts, :namespace, "default")

      schema =
        case request.schema do
          nil -> "none"
          schema -> :erlang.phash2(schema)
        end

      text =
        request.context.messages
        |> Enum.map_join("|", fn
          %Message{role: role, content: content} ->
            content_text =
              content
              |> Enum.map_join("", fn
                %ContentPart{text: text} when is_binary(text) -> text
                _ -> ""
              end)

            "#{role}:#{content_text}"
        end)

      "#{namespace}:#{model.id}:#{request.operation}:#{schema}:#{text}"
    end

    def state(agent) do
      Agent.get(agent, & &1)
    end
  end

  defmodule FailingHTTP do
  end

  defmodule ObjectHTTP do
  end

  defmodule BrokenObjectHTTP do
  end

  defmodule ErrorHTTP do
  end

  defmodule ErrorObjectHTTP do
  end

  defmodule CoerceObjectHTTP do
  end

  defmodule ObjectStreamHTTP do
  end

  setup do
    # Stub HTTP responses for testing
    Req.Test.stub(ReqLLM.GenerationTest, fn conn ->
      Req.Test.json(conn, %{
        "id" => "cmpl_test_123",
        "model" => "gpt-4-turbo",
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => "Hello! How can I help you today?"}
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 9, "total_tokens" => 19}
      })
    end)

    :ok
  end

  describe "generate_text/3 core functionality" do
    test "accepts string input format" do
      {:ok, response} =
        Generation.generate_text(
          @chat_model,
          "Hello",
          req_http_options: [plug: {Req.Test, ReqLLM.GenerationTest}]
        )

      assert %Response{} = response
      # Model might have version suffix
      assert response.model =~ "gpt-4-turbo"
      assert is_binary(Response.text(response))
      assert String.length(Response.text(response)) > 0
    end

    test "accepts Context input format" do
      context = Context.new([Context.user("Hello world")])

      {:ok, response} =
        Generation.generate_text(
          @chat_model,
          context,
          req_http_options: [plug: {Req.Test, ReqLLM.GenerationTest}]
        )

      assert %Response{} = response
    end

    test "accepts message list input format" do
      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there!"}
      ]

      {:ok, response} =
        Generation.generate_text(
          @chat_model,
          messages,
          req_http_options: [plug: {Req.Test, ReqLLM.GenerationTest}]
        )

      assert %Response{} = response
    end

    test "handles system prompt option" do
      {:ok, response} =
        Generation.generate_text(
          @chat_model,
          "Hello",
          system_prompt: "Be helpful",
          req_http_options: [plug: {Req.Test, ReqLLM.GenerationTest}]
        )

      assert %Response{} = response
      # System prompt gets added to context, which we can verify indirectly
      # system + user at minimum
      assert length(response.context.messages) >= 2
    end

    test "uses application cache on repeated requests" do
      {:ok, cache_agent} = Agent.start_link(fn -> %{entries: %{}, puts: 0} end)

      {:ok, first_response} =
        Generation.generate_text(
          @chat_model,
          "Hello",
          cache: CacheBackend,
          cache_ttl: 600,
          cache_options: [agent: cache_agent, namespace: "chat"],
          req_http_options: [plug: {Req.Test, ReqLLM.GenerationTest}]
        )

      Req.Test.stub(FailingHTTP, fn _conn ->
        raise "HTTP request should not execute on cache hit"
      end)

      {:ok, cached_response} =
        Generation.generate_text(
          @chat_model,
          "Hello",
          cache: CacheBackend,
          cache_ttl: 600,
          cache_options: [agent: cache_agent, namespace: "chat"],
          req_http_options: [plug: {Req.Test, FailingHTTP}]
        )

      assert Response.text(first_response) == Response.text(cached_response)
      assert first_response.usage.total_tokens == 19
      assert cached_response.usage.total_tokens == 0
      assert cached_response.usage.input_tokens == 0
      assert cached_response.usage.output_tokens == 0
      assert cached_response.usage.cached_tokens == 0
      assert CacheBackend.state(cache_agent).puts == 1
      assert cached_response.provider_meta.response_cache_hit == true
      assert cached_response.provider_meta.ttl == 600
      assert cached_response.context.messages |> List.last() |> Map.get(:role) == :assistant
    end
  end

  describe "generate_text/3 error cases" do
    test "returns error for invalid model spec" do
      assert {:error, :unknown_provider} = Generation.generate_text("invalid:model", "Hello")
    end

    test "returns error for invalid role in message list" do
      messages = [
        %{role: "invalid_role", content: "Hello"}
      ]

      {:error, error} = Generation.generate_text(@chat_model, messages)

      # Should get a Role error
      assert %ReqLLM.Error.Invalid.Role{} = error
      assert error.role == "invalid_role"
    end

    test "returns validation error for invalid options" do
      {:error, error} =
        Generation.generate_text(
          @chat_model,
          "Hello",
          temperature: "invalid"
        )

      # The error gets wrapped in Unknown, so we need to check the wrapped error
      assert %ReqLLM.Error.Unknown.Unknown{} = error
      assert %NimbleOptions.ValidationError{} = error.error
    end

    test "handles warnings correctly with on_unsupported: :error" do
      {:error, error} =
        Generation.generate_text(
          "openai:o1-mini",
          "Hello",
          temperature: 0.7,
          on_unsupported: :error
        )

      assert is_struct(error)
    end

    test "returns request errors for non-success responses" do
      Req.Test.stub(ErrorHTTP, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"message" => "rate limited"}})
      end)

      assert {:error, %ReqLLM.Error.API.Request{status: 429, response_body: body}} =
               Generation.generate_text(
                 @chat_model,
                 "Hello",
                 req_http_options: [plug: {Req.Test, ErrorHTTP}]
               )

      assert body == %{"error" => %{"message" => "rate limited"}}
    end
  end

  describe "generate_text!/3" do
    test "returns text on success" do
      result =
        Generation.generate_text!(
          @chat_model,
          "Hello",
          req_http_options: [plug: {Req.Test, ReqLLM.GenerationTest}]
        )

      assert is_binary(result)
      assert String.length(result) > 0
    end

    test "raises on error" do
      assert_raise UndefinedFunctionError, fn ->
        Generation.generate_text!("invalid:model", "Hello")
      end
    end
  end

  describe "stream_text/3 core functionality" do
    setup do
      # Stub streaming response with SSE format
      Req.Test.stub(ReqLLM.GenerationStreamTest, fn conn ->
        sse_body =
          ~s(data: {"id":"chatcmpl-123","choices":[{"delta":{"content":"Hello"}}]}\n\n) <>
            ~s(data: {"id":"chatcmpl-123","choices":[{"delta":{"content":" world"}}]}\n\n) <>
            "data: [DONE]\n\n"

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, sse_body)
      end)

      :ok
    end

    test "returns streaming response" do
      {:ok, response} =
        Generation.stream_text(
          @chat_model,
          "Tell me a story",
          req_http_options: [plug: {Req.Test, ReqLLM.GenerationStreamTest}]
        )

      assert %StreamResponse{} = response
      assert is_function(response.stream)
    end

    test "replays cached responses as a stream" do
      {:ok, cache_agent} = Agent.start_link(fn -> %{entries: %{}, puts: 0} end)

      {:ok, _response} =
        Generation.generate_text(
          @chat_model,
          "Tell me a story",
          cache: CacheBackend,
          cache_options: [agent: cache_agent, namespace: "stream"],
          req_http_options: [plug: {Req.Test, ReqLLM.GenerationTest}]
        )

      Req.Test.stub(FailingHTTP, fn _conn ->
        raise "HTTP request should not execute on cache hit"
      end)

      {:ok, response} =
        Generation.stream_text(
          @chat_model,
          "Tell me a story",
          cache: CacheBackend,
          cache_options: [agent: cache_agent, namespace: "stream"],
          req_http_options: [plug: {Req.Test, FailingHTTP}]
        )

      assert %StreamResponse{} = response
      assert StreamResponse.usage(response).total_tokens == 0
      assert StreamResponse.usage(response).cached_tokens == 0

      {:ok, materialized_response} = StreamResponse.to_response(response)

      assert Response.text(materialized_response) == "Hello! How can I help you today?"
      assert materialized_response.usage.total_tokens == 0
      assert materialized_response.provider_meta.response_cache_hit == true
    end
  end

  describe "stream_text/3 error cases" do
    test "returns error for invalid model spec" do
      assert {:error, :unknown_provider} = Generation.stream_text("invalid:model", "Hello")
    end
  end

  describe "stream_text!/3" do
    test "emits a deprecation warning" do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert :ok = apply(Generation, :stream_text!, [@chat_model, "Hello"])
        end)

      assert warning =~ "ReqLLM.Generation.stream_text!/3 is deprecated"
      assert warning =~ "Please migrate to the new streaming API"
    end
  end

  describe "generate_object/4 cache support" do
    test "uses schema-aware cache keys" do
      {:ok, cache_agent} = Agent.start_link(fn -> %{entries: %{}, puts: 0} end)

      Req.Test.stub(ObjectHTTP, fn conn ->
        Req.Test.json(conn, %{
          "id" => "cmpl_object_123",
          "model" => "gpt-4-turbo",
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "tool_calls" => [
                  %{
                    "id" => "call_123",
                    "type" => "function",
                    "function" => %{
                      "name" => "structured_output",
                      "arguments" => "{\"name\":\"Ada\"}"
                    }
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 4, "total_tokens" => 14}
        })
      end)

      schema = [name: [type: :string, required: true]]

      {:ok, first_response} =
        Generation.generate_object(
          @chat_model,
          "Return a person",
          schema,
          cache: CacheBackend,
          cache_options: [agent: cache_agent, namespace: "object"],
          req_http_options: [plug: {Req.Test, ObjectHTTP}]
        )

      Req.Test.stub(FailingHTTP, fn _conn ->
        raise "HTTP request should not execute on cache hit"
      end)

      {:ok, cached_response} =
        Generation.generate_object(
          @chat_model,
          "Return a person",
          schema,
          cache: CacheBackend,
          cache_options: [agent: cache_agent, namespace: "object"],
          req_http_options: [plug: {Req.Test, FailingHTTP}]
        )

      assert first_response.object == %{"name" => "Ada"}
      assert first_response.usage.total_tokens == 14
      assert cached_response.object == %{"name" => "Ada"}
      assert cached_response.usage.total_tokens == 0
      assert cached_response.provider_meta.response_cache_hit == true
      assert CacheBackend.state(cache_agent).puts == 1
    end
  end

  describe "generate_object/4 basic errors and bang helpers" do
    test "returns an error for invalid model specs" do
      assert {:error, :unknown_provider} =
               Generation.generate_object("invalid:model", "Return a person", [])
    end

    test "returns schema compilation errors" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Generation.generate_object(@chat_model, "Return a person", "invalid")
    end

    test "generate_object!/4 returns the decoded object on success" do
      Req.Test.stub(ObjectHTTP, fn conn ->
        Req.Test.json(conn, %{
          "id" => "cmpl_object_123",
          "model" => "gpt-4-turbo",
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "tool_calls" => [
                  %{
                    "id" => "call_123",
                    "type" => "function",
                    "function" => %{
                      "name" => "structured_output",
                      "arguments" => "{\"name\":\"Ada\"}"
                    }
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 4, "total_tokens" => 14}
        })
      end)

      schema = [name: [type: :string, required: true]]

      assert Generation.generate_object!(
               @chat_model,
               "Return a person",
               schema,
               req_http_options: [plug: {Req.Test, ObjectHTTP}]
             ) == %{"name" => "Ada"}
    end

    test "generate_object!/4 raises on request errors" do
      Req.Test.stub(ErrorObjectHTTP, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => %{"message" => "server error"}})
      end)

      assert_raise ReqLLM.Error.API.Request, fn ->
        Generation.generate_object!(
          @chat_model,
          "Return a person",
          [name: [type: :string, required: true]],
          req_http_options: [plug: {Req.Test, ErrorObjectHTTP}]
        )
      end
    end
  end

  describe "generate_object/4 JSON repair" do
    test "repairs slightly broken structured output arguments by default" do
      Req.Test.stub(BrokenObjectHTTP, fn conn ->
        Req.Test.json(conn, %{
          "id" => "cmpl_object_123",
          "model" => "gpt-4-turbo",
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "tool_calls" => [
                  %{
                    "id" => "call_123",
                    "type" => "function",
                    "function" => %{
                      "name" => "structured_output",
                      "arguments" => ~s({"name":"Ada",})
                    }
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 4, "total_tokens" => 14}
        })
      end)

      schema = [name: [type: :string, required: true]]

      {:ok, response} =
        Generation.generate_object(
          @chat_model,
          "Return a person",
          schema,
          openai_structured_output_mode: :tool_strict,
          req_http_options: [plug: {Req.Test, BrokenObjectHTTP}]
        )

      assert response.object == %{"name" => "Ada"}
    end

    test "allows JSON repair to be disabled" do
      Req.Test.stub(BrokenObjectHTTP, fn conn ->
        Req.Test.json(conn, %{
          "id" => "cmpl_object_123",
          "model" => "gpt-4-turbo",
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "tool_calls" => [
                  %{
                    "id" => "call_123",
                    "type" => "function",
                    "function" => %{
                      "name" => "structured_output",
                      "arguments" => ~s({"name":"Ada",})
                    }
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 4, "total_tokens" => 14}
        })
      end)

      schema = [name: [type: :string, required: true]]

      {:ok, response} =
        Generation.generate_object(
          @chat_model,
          "Return a person",
          schema,
          json_repair: false,
          openai_structured_output_mode: :tool_strict,
          req_http_options: [plug: {Req.Test, BrokenObjectHTTP}]
        )

      assert response.object == nil
    end
  end

  describe "generate_object/4 error handling and coercion" do
    test "returns request errors for non-success responses" do
      Req.Test.stub(ErrorObjectHTTP, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => %{"message" => "server error"}})
      end)

      assert {:error, %ReqLLM.Error.API.Request{status: 500, response_body: body}} =
               Generation.generate_object(
                 @chat_model,
                 "Return a person",
                 [name: [type: :string, required: true]],
                 req_http_options: [plug: {Req.Test, ErrorObjectHTTP}]
               )

      assert body == %{"error" => %{"message" => "server error"}}
    end

    test "coerces primitive values to match the requested schema for non-strict models" do
      Req.Test.stub(CoerceObjectHTTP, fn conn ->
        Req.Test.json(conn, %{
          "id" => "cmpl_object_123",
          "model" => "gpt-4-turbo",
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "tool_calls" => [
                  %{
                    "id" => "call_123",
                    "type" => "function",
                    "function" => %{
                      "name" => "structured_output",
                      "arguments" => ~s({"count":"42","active":"true","rating":"4.5"})
                    }
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 4, "total_tokens" => 14}
        })
      end)

      schema = [
        count: [type: :integer, required: true],
        active: [type: :boolean, required: true],
        rating: [type: :float, required: true]
      ]

      {:ok, response} =
        Generation.generate_object(
          @chat_model,
          "Return typed values",
          schema,
          req_http_options: [plug: {Req.Test, CoerceObjectHTTP}]
        )

      assert response.object == %{"count" => 42, "active" => true, "rating" => 4.5}
    end
  end

  describe "stream_object/4" do
    test "returns a streaming response for structured output" do
      Req.Test.stub(ObjectStreamHTTP, fn conn ->
        sse_body =
          ~s(data: {"id":"chatcmpl-123","choices":[{"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_123","type":"function","function":{"name":"structured_output","arguments":"{\\"name\\":\\"Ada\\"}"}}]},"finish_reason":null}]}\n\n) <>
            ~s(data: {"id":"chatcmpl-123","choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n) <>
            "data: [DONE]\n\n"

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, sse_body)
      end)

      {:ok, response} =
        Generation.stream_object(
          @chat_model,
          "Return a person",
          [name: [type: :string, required: true]],
          req_http_options: [plug: {Req.Test, ObjectStreamHTTP}]
        )

      assert %StreamResponse{} = response
      assert is_function(response.stream)
    end

    test "returns an error for invalid model specs" do
      assert {:error, :unknown_provider} =
               Generation.stream_object("invalid:model", "Hello", [])
    end
  end

  describe "stream_object!/4" do
    test "emits a deprecation warning" do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert :ok =
                   apply(Generation, :stream_object!, [
                     @chat_model,
                     "Hello",
                     [name: [type: :string, required: true]]
                   ])
        end)

      assert warning =~ "ReqLLM.Generation.stream_object!/4 is deprecated"
      assert warning =~ "Please migrate to the new streaming API"
    end
  end

  describe "option validation and translation" do
    test "validates base schema options" do
      schema = Generation.schema()

      {:ok, validated} =
        NimbleOptions.validate([temperature: 0.7, max_tokens: 100], schema)

      assert validated[:temperature] == 0.7
      assert validated[:max_tokens] == 100
    end

    test "includes on_unsupported option in schema" do
      schema = Generation.schema()
      on_unsupported_spec = Keyword.get(schema.schema, :on_unsupported)

      assert on_unsupported_spec != nil
      assert on_unsupported_spec[:type] == {:in, [:warn, :error, :ignore]}
      assert on_unsupported_spec[:default] == :warn
    end

    test "includes cache options in schema" do
      schema = Generation.schema()

      assert Keyword.has_key?(schema.schema, :cache)
      assert Keyword.has_key?(schema.schema, :cache_key)
      assert Keyword.has_key?(schema.schema, :cache_ttl)
      assert Keyword.has_key?(schema.schema, :cache_options)
    end

    test "includes json_repair option in schema" do
      schema = Generation.schema()
      json_repair_spec = Keyword.get(schema.schema, :json_repair)

      assert json_repair_spec != nil
      assert json_repair_spec[:type] == :boolean
      assert json_repair_spec[:default] == true
    end

    test "provider schema composition works" do
      provider_schema =
        ReqLLM.Provider.Options.compose_schema(
          Generation.schema(),
          ReqLLM.Providers.OpenAI
        )

      # Should include both base and provider options
      assert provider_schema.schema[:temperature] != nil
      assert provider_schema.schema[:provider_options] != nil
    end
  end

  describe "options and generation parameters" do
    test "accepts generation options without errors" do
      {:ok, response} =
        Generation.generate_text(
          @chat_model,
          "Hello",
          temperature: 0.8,
          max_tokens: 50,
          top_p: 0.9,
          req_http_options: [plug: {Req.Test, ReqLLM.GenerationTest}]
        )

      assert %Response{} = response
    end

    test "handles provider-specific options" do
      {:ok, response} =
        Generation.generate_text(
          @chat_model,
          "Hello",
          frequency_penalty: 0.1,
          req_http_options: [plug: {Req.Test, ReqLLM.GenerationTest}]
        )

      assert %Response{} = response
    end
  end

  describe "generate_text/3 with req_http_options" do
    test "correctly passes http options to Req" do
      # We pass an intentionally invalid option to Req. If `req_http_options` are being passed correctly,
      # Req's internal validation will raise an ArgumentError. This confirms the options are being passed
      # all the way to `Req.new/1` without making a real network request.
      assert_raise ArgumentError, ~r/got unsupported atom method :invalid_method/, fn ->
        Generation.generate_text(@chat_model, "Hello",
          req_http_options: [method: :invalid_method]
        )
      end
    end
  end

  describe "api_key option precedence" do
    test "api_key option takes precedence over other configuration methods" do
      custom_key = "test-api-key-#{System.unique_integer([:positive])}"

      Req.Test.stub(ReqLLM.GenerationTestAPIKey, fn conn ->
        auth_header = Plug.Conn.get_req_header(conn, "authorization")

        assert auth_header == ["Bearer #{custom_key}"],
               "Expected Authorization header to contain custom api_key"

        Req.Test.json(conn, %{
          "id" => "cmpl_test_123",
          "model" => "gpt-4-turbo",
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => "Response"}
            }
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
        })
      end)

      {:ok, response} =
        Generation.generate_text(
          @chat_model,
          "Hello",
          api_key: custom_key,
          req_http_options: [plug: {Req.Test, ReqLLM.GenerationTestAPIKey}]
        )

      assert %Response{} = response
    end

    test "auth_mode :api_key ignores access_token and uses API key" do
      custom_key = "test-api-key-explicit-mode-#{System.unique_integer([:positive])}"

      Req.Test.stub(ReqLLM.GenerationTestAPIKeyMode, fn conn ->
        auth_header = Plug.Conn.get_req_header(conn, "authorization")

        assert auth_header == ["Bearer #{custom_key}"],
               "Expected Authorization header to use API key when auth_mode is :api_key"

        Req.Test.json(conn, %{
          "id" => "cmpl_test_123",
          "model" => "gpt-4-turbo",
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => "Response"}
            }
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
        })
      end)

      {:ok, response} =
        Generation.generate_text(
          @chat_model,
          "Hello",
          api_key: custom_key,
          provider_options: [auth_mode: :api_key, access_token: "stale-oauth-token"],
          req_http_options: [plug: {Req.Test, ReqLLM.GenerationTestAPIKeyMode}]
        )

      assert %Response{} = response
    end
  end

  describe "oauth access_token option precedence" do
    test "access_token in provider_options takes precedence for generate_text" do
      oauth_token = "oauth-token-#{System.unique_integer([:positive])}"

      Req.Test.stub(ReqLLM.GenerationTestOAuthAccessToken, fn conn ->
        auth_header = Plug.Conn.get_req_header(conn, "authorization")

        assert auth_header == ["Bearer #{oauth_token}"],
               "Expected Authorization header to contain OAuth access_token"

        Req.Test.json(conn, %{
          "id" => "cmpl_test_123",
          "model" => "gpt-4-turbo",
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => "Response"}
            }
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
        })
      end)

      {:ok, response} =
        Generation.generate_text(
          @chat_model,
          "Hello",
          provider_options: [auth_mode: :oauth, access_token: oauth_token],
          req_http_options: [plug: {Req.Test, ReqLLM.GenerationTestOAuthAccessToken}]
        )

      assert %Response{} = response
    end

    test "oauth_file in provider_options is used for generate_text" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "req_llm_generation_oauth_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      path = Path.join(tmp_dir, "oauth.json")

      on_exit(fn -> File.rm_rf(tmp_dir) end)

      File.write!(
        path,
        Jason.encode_to_iodata!(
          %{
            "openai-codex" => %{
              "type" => "oauth",
              "access" => "oauth-file-token-generate",
              "refresh" => "oauth-file-refresh-generate",
              "expires" => System.system_time(:millisecond) + 60_000
            }
          },
          pretty: true
        )
      )

      Req.Test.stub(ReqLLM.GenerationTestOAuthFile, fn conn ->
        auth_header = Plug.Conn.get_req_header(conn, "authorization")

        assert auth_header == ["Bearer oauth-file-token-generate"],
               "Expected Authorization header to contain OAuth token loaded from oauth file"

        Req.Test.json(conn, %{
          "id" => "cmpl_test_123",
          "model" => "gpt-4-turbo",
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => "Response"}
            }
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
        })
      end)

      {:ok, response} =
        Generation.generate_text(
          @chat_model,
          "Hello",
          provider_options: [auth_mode: :oauth, oauth_file: path],
          req_http_options: [plug: {Req.Test, ReqLLM.GenerationTestOAuthFile}]
        )

      assert %Response{} = response
    end

    test "access_token in provider_options takes precedence for stream_text" do
      oauth_token = "oauth-stream-token-#{System.unique_integer([:positive])}"

      Req.Test.stub(ReqLLM.GenerationStreamTestOAuthAccessToken, fn conn ->
        auth_header = Plug.Conn.get_req_header(conn, "authorization")

        assert auth_header == ["Bearer #{oauth_token}"],
               "Expected Authorization header to contain OAuth access_token in streaming request"

        sse_body =
          ~s(data: {"id":"chatcmpl-123","choices":[{"delta":{"content":"Hello"}}]}\n\n) <>
            "data: [DONE]\n\n"

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, sse_body)
      end)

      {:ok, response} =
        Generation.stream_text(
          @chat_model,
          "Hello",
          provider_options: [auth_mode: :oauth, access_token: oauth_token],
          req_http_options: [plug: {Req.Test, ReqLLM.GenerationStreamTestOAuthAccessToken}]
        )

      assert %StreamResponse{} = response
    end
  end

  describe "stream_text/3 api_key option precedence" do
    test "api_key option takes precedence in streaming requests" do
      custom_key = "test-stream-key-#{System.unique_integer([:positive])}"

      Req.Test.stub(ReqLLM.GenerationStreamTestAPIKey, fn conn ->
        auth_header = Plug.Conn.get_req_header(conn, "authorization")

        assert auth_header == ["Bearer #{custom_key}"],
               "Expected Authorization header to contain custom api_key in streaming request"

        sse_body =
          ~s(data: {"id":"chatcmpl-123","choices":[{"delta":{"content":"Hello"}}]}\n\n) <>
            "data: [DONE]\n\n"

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_resp(200, sse_body)
      end)

      {:ok, response} =
        Generation.stream_text(
          @chat_model,
          "Hello",
          api_key: custom_key,
          req_http_options: [plug: {Req.Test, ReqLLM.GenerationStreamTestAPIKey}]
        )

      assert %StreamResponse{} = response
    end
  end
end

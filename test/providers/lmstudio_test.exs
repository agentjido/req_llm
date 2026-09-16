defmodule ReqLLM.Providers.LMStudioTest do
  @moduledoc """
  LM Studio provider contracts verified with an in-process HTTP stub.

  These tests make no requests to LM Studio. They run synchronously because
  authentication tests temporarily change environment and application settings.
  """

  use ExUnit.Case, async: false

  alias ReqLLM.{Context, Response, StreamResponse}
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.LMStudio

  @moduletag provider: :lmstudio
  @moduletag category: :core

  defmodule Server do
    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(opts[:owner], {:request, conn.request_path, conn.req_headers, Jason.decode!(body)})

      if opts[:events] do
        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_chunked(200)

        Enum.reduce(opts[:events] ++ ["[DONE]"], conn, fn event, conn ->
          data = if is_map(event), do: Jason.encode!(event), else: event
          {:ok, conn} = Plug.Conn.chunk(conn, "data: #{data}\n\n")
          conn
        end)
      else
        Req.Test.json(Plug.Conn.put_status(conn, opts[:status] || 200), opts[:response])
      end
    end
  end

  setup do
    ReqLLM.Test.Env.isolate!(["LMSTUDIO_API_KEY", "OPENAI_API_KEY"])
    keys = [:lmstudio_api_key, :lmstudio]
    saved = Enum.map(keys, &{&1, Application.fetch_env(:req_llm, &1)})
    Enum.each(keys, &Application.delete_env(:req_llm, &1))

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:req_llm, key, value)
        {key, :error} -> Application.delete_env(:req_llm, key)
      end)
    end)

    :ok
  end

  test "discovers the provider and resolves uncataloged local model identifiers" do
    assert {:ok, LMStudio} = ReqLLM.provider(:lmstudio)

    warning =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, model} = ReqLLM.model("lmstudio:publisher/model:Q4_K_M")
        assert model.provider == :lmstudio
        assert model.id == "publisher/model:Q4_K_M"
      end)

    assert warning =~ "unverified model"
    assert LMStudio.default_base_url() == "http://127.0.0.1:1234/v1"
  end

  test "buffered chat works without credentials and retains reasoning, usage, and history" do
    System.put_env("OPENAI_API_KEY", "unrelated-cloud-key")

    base_url =
      server(response: completion(%{"content" => "Hello", "reasoning_content" => "Think"}))

    assert {:ok, response} =
             ReqLLM.generate_text(%{provider: :lmstudio, id: "local-model"}, "Hi",
               base_url: base_url,
               max_tokens: 32,
               max_retries: 0
             )

    assert Response.text(response) == "Hello"
    assert Response.thinking(response) == "Think"
    assert Response.finish_reason(response) == :stop
    assert response.usage.input_tokens == 3
    assert response.usage.output_tokens == 2
    assert length(response.context.messages) == 2
    assert_received {:request, "/v1/chat/completions", headers, body}
    refute List.keymember?(headers, "authorization", 0)
    assert body["model"] == "local-model"
    assert body["messages"] == [%{"role" => "user", "content" => "Hi"}]
    assert body["max_tokens"] == 32
  end

  test "optional authentication follows option, application, environment precedence" do
    System.put_env("LMSTUDIO_API_KEY", "env-token")
    assert_auth([], "env-token")
    Application.put_env(:req_llm, :lmstudio_api_key, "app-token")
    assert_auth([], "app-token")
    assert_auth([api_key: "request-token"], "request-token")
  end

  test "rejects an explicitly empty token instead of falling back" do
    System.put_env("LMSTUDIO_API_KEY", "fallback-token")

    assert_raise ReqLLM.Error.Invalid.Parameter, ~r/API key must be non-empty/, fn ->
      LMStudio.attach(Req.new(), model(), api_key: "")
    end

    assert {:error, error} =
             LMStudio.attach_stream(model(), context(), [api_key: ""], ReqLLM.Finch)

    assert Exception.message(error) =~ "API key must be non-empty"
    refute Exception.message(error) =~ "fallback-token"
  end

  test "authenticated buffered requests send the configured bearer token" do
    base_url = server(response: completion(%{"content" => "ok"}))

    assert {:ok, _} =
             ReqLLM.generate_text(model(), "Hi", base_url: base_url, api_key: "local-token")

    assert_received {:request, _, headers, _}
    assert {"authorization", "Bearer local-token"} in headers
  end

  test "endpoint overrides and provider model aliases agree between transports" do
    Application.put_env(:req_llm, :lmstudio, base_url: "http://app.test:1234/v1")
    assert_endpoints(model(), [], "app.test", "/v1/chat/completions")
    configured = %{model() | base_url: "http://model.test:1234/custom/v1"}
    assert_endpoints(configured, [], "model.test", "/custom/v1/chat/completions")

    assert_endpoints(
      configured,
      [base_url: "http://request.test:1234/proxy/v1/"],
      "request.test",
      "/proxy/v1/chat/completions"
    )

    {:ok, request} = LMStudio.prepare_request(:chat, configured, "Hi", [])
    assert body(request)["model"] == "publisher/model@q4:local"
    {:ok, stream} = LMStudio.attach_stream(configured, context(), [], ReqLLM.Finch)
    assert Jason.decode!(stream.body)["model"] == "publisher/model@q4:local"
  end

  test "provider controls and sampling options reach both wire formats" do
    opts = [
      temperature: 0.2,
      top_p: 0.9,
      top_k: 40,
      seed: 7,
      stop: ["END"],
      reasoning_effort: :none,
      provider_options: [lmstudio: [ttl: 120, repeat_penalty: 1.1]]
    ]

    {:ok, request} = LMStudio.prepare_request(:chat, model(), "Hi", opts)
    {:ok, stream} = LMStudio.attach_stream(model(), context(), opts, ReqLLM.Finch)

    for encoded <- [body(request), Jason.decode!(stream.body)] do
      assert encoded["ttl"] == 120
      assert encoded["repeat_penalty"] == 1.1
      assert encoded["reasoning_effort"] == "none"
      assert encoded["temperature"] == 0.2
      assert encoded["top_p"] == 0.9
      assert encoded["top_k"] == 40
      assert encoded["seed"] == 7
      assert encoded["stop"] == ["END"]
      refute Map.has_key?(encoded, "api_key")
    end

    assert Jason.decode!(stream.body)["stream_options"] == %{"include_usage" => true}
  end

  test "reasoning translation is idempotent and clamps only max" do
    for effort <- [:none, :minimal, :low, :medium, :high, :xhigh] do
      assert {opts, []} = LMStudio.translate_options(:chat, model(), reasoning_effort: effort)
      assert opts[:reasoning_effort] == effort
      assert {^opts, []} = LMStudio.translate_options(:chat, model(), opts)
    end

    assert {[], []} = LMStudio.translate_options(:chat, model(), reasoning_effort: :default)

    assert {[reasoning_effort: :xhigh], [_]} =
             LMStudio.translate_options(:chat, model(), reasoning_effort: :max)

    assert {[], [_]} = LMStudio.translate_options(:chat, model(), reasoning_effort: :unknown)
  end

  test "validates provider options" do
    for opts <- [[ttl: -1], [repeat_penalty: "invalid"]] do
      assert {:error, _} = LMStudio.prepare_request(:chat, model(), "Hi", provider_options: opts)
    end
  end

  test "object generation uses native JSON schema without a synthetic tool" do
    base_url = server(response: completion(%{"content" => ~s({"answer":"ok"})}))

    assert {:ok, response} =
             ReqLLM.generate_object(
               model(),
               "Return ok",
               [answer: [type: :string, required: true]],
               base_url: base_url,
               provider_options: %{lmstudio: %{ttl: 120}}
             )

    assert response.object == %{"answer" => "ok"}
    assert_received {:request, _, _, body}
    assert body["ttl"] == 120
    assert_schema(body)
  end

  test "object preparation accepts flat maps and namespaced options" do
    {:ok, compiled_schema} = ReqLLM.Schema.compile(answer: [type: :string, required: true])

    for provider_options <- [%{ttl: 60}, [lmstudio: [ttl: 60]], %{lmstudio: %{ttl: 60}}] do
      assert {:ok, request} =
               LMStudio.prepare_request(:object, model(), "Return ok",
                 compiled_schema: compiled_schema,
                 provider_options: provider_options
               )

      assert body(request)["ttl"] == 60
      assert_schema(body(request))
    end
  end

  @tag category: :streaming
  test "streamed objects use the same schema and assemble validated objects" do
    base_url = server(events: [delta(%{"content" => ~s({"answer":"ok"})}), finish()])

    assert {:ok, stream} =
             ReqLLM.stream_object(model(), "Return ok", [answer: [type: :string, required: true]],
               base_url: base_url,
               provider_options: [ttl: 120],
               reasoning_effort: :none
             )

    assert {:ok, response} = StreamResponse.to_response(stream)
    assert response.object == %{"answer" => "ok"}
    assert_received {:request, _, _, body}
    assert body["stream"]
    assert body["ttl"] == 120
    assert_schema(body)
  end

  @tag category: :tools
  test "tool responses can be sent back in a conversation" do
    tool_call = %{
      "id" => "call_local",
      "type" => "function",
      "function" => %{"name" => "weather", "arguments" => ~s({"city":"Paris"})}
    }

    base_url =
      server(response: completion(%{"content" => nil, "tool_calls" => [tool_call]}, "tool_calls"))

    assert {:ok, response} =
             ReqLLM.generate_text(model(), "Weather in Paris?",
               base_url: base_url,
               tools: [tool()]
             )

    assert [call] = Response.tool_calls(response)
    assert call.id == "call_local"
    assert_received {:request, _, _, body}
    assert hd(body["tools"])["function"]["name"] == "weather"

    conversation =
      Context.append(response.context, Context.tool_result(call.id, "weather", "Sunny"))

    {:ok, request} = LMStudio.prepare_request(:chat, model(), conversation, [])
    messages = body(request)["messages"]
    assert Enum.at(messages, 1)["tool_calls"] == [tool_call]
    assert List.last(messages)["tool_call_id"] == "call_local"
    assert List.last(messages)["content"] == "Sunny"
  end

  test "image content is preserved in buffered and streaming requests" do
    image_url = "data:image/png;base64,aGVsbG8="
    prompt = [Context.user([ContentPart.text("Describe"), ContentPart.image_url(image_url)])]
    {:ok, request} = LMStudio.prepare_request(:chat, model(), prompt, [])
    {:ok, normalized} = Context.normalize(prompt)
    {:ok, stream} = LMStudio.attach_stream(model(), normalized, [], ReqLLM.Finch)

    for encoded <- [body(request), Jason.decode!(stream.body)] do
      assert [
               %{"type" => "text"},
               %{"type" => "image_url", "image_url" => %{"url" => ^image_url}}
             ] =
               hd(encoded["messages"])["content"]
    end
  end

  @tag category: :streaming
  test "streaming preserves reasoning, custom headers, and trailing usage" do
    events = [
      delta(%{"reasoning" => "Think"}),
      delta(%{"content" => "Hello"}),
      finish(),
      %{
        "choices" => [],
        "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
      }
    ]

    base_url = server(events: events)

    assert {:ok, stream} =
             ReqLLM.stream_text(model(), "Hi",
               base_url: base_url,
               req_http_options: [headers: [{"x-local-test", "present"}]],
               reasoning_effort: :high
             )

    assert {:ok, response} = StreamResponse.to_response(stream)
    assert Response.text(response) == "Hello"
    assert Response.thinking(response) == "Think"
    assert response.usage.input_tokens == 3
    assert response.usage.total_tokens == 5
    assert_received {:request, _, headers, _}
    refute List.keymember?(headers, "authorization", 0)
    assert {"x-local-test", "present"} in headers
  end

  @tag category: :tools
  test "streaming assembles fragmented tool arguments" do
    first = %{
      "index" => 0,
      "id" => "call_local",
      "type" => "function",
      "function" => %{"name" => "weather", "arguments" => "{\"city\":"}
    }

    second = %{"index" => 0, "function" => %{"arguments" => "\"Paris\"}"}}

    base_url =
      server(
        events: [
          delta(%{"tool_calls" => [first]}),
          delta(%{"tool_calls" => [second]}),
          finish("tool_calls")
        ]
      )

    assert {:ok, stream} =
             ReqLLM.stream_text(model(), "Weather?", base_url: base_url, tools: [tool()])

    assert {:ok, response} = StreamResponse.to_response(stream)
    assert [call] = Response.tool_calls(response)
    assert call.id == "call_local"
    assert call.function.name == "weather"
    assert Jason.decode!(call.function.arguments) == %{"city" => "Paris"}
  end

  @tag category: :embedding
  test "single and batch embeddings use the embeddings endpoint" do
    for input <- ["hello", ["hello", "world"]] do
      data =
        Enum.with_index(List.wrap(input), fn _, index ->
          %{"index" => index, "embedding" => [0.1, 0.2]}
        end)

      base_url =
        server(
          response: %{"data" => data, "usage" => %{"prompt_tokens" => 2, "total_tokens" => 2}}
        )

      embedding_model = %{
        provider: :lmstudio,
        id: "local-embedding",
        capabilities: %{embeddings: true}
      }

      assert {:ok, result} =
               ReqLLM.embed(embedding_model, input,
                 base_url: base_url,
                 dimensions: 2,
                 return_usage: true
               )

      assert result.usage.input_tokens == 2
      assert_received {:request, "/v1/embeddings", _, body}
      assert body["input"] == input
      assert body["model"] == "local-embedding"
      assert body["dimensions"] == 2
      refute Map.has_key?(body, "messages")
    end
  end

  test "server errors preserve the HTTP status and message" do
    base_url = server(status: 400, response: %{"error" => %{"message" => "Model failed to load"}})

    assert {:error, error} =
             ReqLLM.generate_text(model(), "Hi", base_url: base_url, max_retries: 0)

    assert error.status == 400
    assert Exception.message(error) =~ "Model failed to load"
  end

  test "unsupported operations fail before issuing HTTP requests" do
    assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
             LMStudio.prepare_request(:speech, model(), "Hi", [])
  end

  defp model do
    ReqLLM.model!(%{
      provider: :lmstudio,
      id: "local-model",
      provider_model_id: "publisher/model@q4:local",
      capabilities: %{chat: true, tools: %{enabled: true}}
    })
  end

  defp context, do: Context.new([Context.user("Hi")])

  defp body(request) do
    request
    |> LMStudio.encode_body()
    |> Req.Steps.encode_body()
    |> Map.fetch!(:body)
    |> Jason.decode!()
  end

  defp server(opts) do
    server =
      start_supervised!(
        {Bandit, plug: {Server, Keyword.put(opts, :owner, self())}, port: 0, ip: {127, 0, 0, 1}},
        id: make_ref()
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}/v1"
  end

  defp completion(message, finish_reason \\ "stop") do
    %{
      "id" => "local-response",
      "model" => "local-model",
      "choices" => [
        %{
          "index" => 0,
          "message" => Map.put(message, "role", "assistant"),
          "finish_reason" => finish_reason
        }
      ],
      "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
    }
  end

  defp delta(content), do: %{"choices" => [%{"index" => 0, "delta" => content}]}

  defp finish(reason \\ "stop"),
    do: %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}]}

  defp tool do
    ReqLLM.tool(
      name: "weather",
      description: "Get weather",
      parameter_schema: [city: [type: :string, required: true]],
      callback: fn _ -> {:ok, "Sunny"} end
    )
  end

  defp assert_auth(opts, expected) do
    request = LMStudio.attach(Req.new(), model(), opts)
    assert Req.Request.get_header(request, "authorization") == ["Bearer " <> expected]
    {:ok, stream} = LMStudio.attach_stream(model(), context(), opts, ReqLLM.Finch)
    assert {"Authorization", "Bearer " <> expected} in stream.headers
  end

  defp assert_endpoints(model, opts, host, path) do
    {:ok, request} = LMStudio.prepare_request(:chat, model, "Hi", opts)
    url = Req.Steps.put_base_url(request).url
    assert url.host == host
    assert url.path == path
    {:ok, stream} = LMStudio.attach_stream(model, context(), opts, ReqLLM.Finch)
    assert stream.host == host
    assert stream.path == path
  end

  defp assert_schema(body) do
    assert body["response_format"]["type"] == "json_schema"
    schema = body["response_format"]["json_schema"]
    assert schema["name"] == "structured_output"
    assert schema["strict"]
    assert schema["schema"]["properties"]["answer"]["type"] == "string"
    refute Map.has_key?(body, "tools")
    refute Map.has_key?(body, "tool_choice")
  end
end

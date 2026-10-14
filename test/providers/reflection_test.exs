defmodule ReqLLM.Providers.ReflectionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import ReqLLM.Test.Helpers

  alias ReqLLM.{Context, Message, Response}
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Providers.Reflection

  defp model do
    ReqLLM.model!(%{provider: :reflection, id: "Beam-1.0-501B-A23B"})
  end

  defp prepare(opts \\ [], context \\ "Hello") do
    Reflection.prepare_request(:chat, model(), context, Keyword.put(opts, :api_key, "test-key"))
  end

  defp body(request), do: request |> Reflection.encode_body() |> json_body()

  test "registers with the Reflection endpoint and key" do
    assert {:ok, Reflection} = ReqLLM.provider(:reflection)
    assert Reflection.provider_id() == :reflection
    assert Reflection.display_name() == "Reflection AI"
    assert Reflection.default_base_url() == "https://api.reflection.ai/openai/v1"
    assert Reflection.default_env_key() == "REFLECTION_API_KEY"

    assert {:ok, request} = prepare()
    assert request.url.path == "/chat/completions"
    assert request.options.base_url == Reflection.default_base_url()
    assert request.options.receive_timeout == 300_000
    assert request.headers["authorization"] == ["Bearer test-key"]
    assert body(request)["model"] == "Beam-1.0-501B-A23B"
  end

  test "resolves model strings before catalog support and accepts explicit maps" do
    capture_io(:stderr, fn ->
      assert {:ok, %{provider: :reflection, id: "Beam-1.0-501B-A23B"}} =
               ReqLLM.model("reflection:Beam-1.0-501B-A23B")
    end)

    assert {:ok, request} =
             Reflection.prepare_request(
               :chat,
               %{provider: :reflection, id: "Beam-1.0-501B-A23B"},
               "Hello",
               api_key: "test-key"
             )

    assert body(request)["model"] == "Beam-1.0-501B-A23B"
  end

  test "maps the common token limit to max_completion_tokens" do
    assert {:ok, request} = prepare(max_tokens: 2048, receive_timeout: 90_000)
    assert request.options.receive_timeout == 90_000
    assert body(request)["max_completion_tokens"] == 2048
    refute Map.has_key?(body(request), "max_tokens")
  end

  test "keeps the native token limit when both limits are supplied" do
    assert {:ok, request} =
             prepare(
               max_tokens: 100,
               provider_options: [max_completion_tokens: 200],
               on_unsupported: :ignore
             )

    assert body(request)["max_completion_tokens"] == 200
  end

  test "encodes all supported reasoning efforts" do
    for effort <- [:low, :medium, :high, :xhigh, :max] do
      assert {:ok, request} = prepare(reasoning_effort: effort)
      assert body(request)["reasoning_effort"] == Atom.to_string(effort)
    end
  end

  test "leaves the organization's default effort unset" do
    for opts <- [[], [reasoning_effort: :default]] do
      assert {:ok, request} = prepare(opts)
      refute Map.has_key?(body(request), "reasoning_effort")
    end
  end

  test "rejects effort values that cannot disable Beam reasoning" do
    for effort <- [:none, :minimal] do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = error} =
               prepare(reasoning_effort: effort)

      assert Exception.message(error) =~ "reasoning_effort"
    end
  end

  test "removes unsupported options and respects on_unsupported" do
    options = [top_k: 5, reasoning_token_budget: 500, seed: 1, stop: ["END"]]
    assert {:ok, request} = prepare(options ++ [on_unsupported: :ignore])

    for key <- ~w(top_k reasoning_token_budget seed stop) do
      refute Map.has_key?(body(request), key)
    end

    assert {:error, %ReqLLM.Error.Validation.Error{}} =
             prepare(options ++ [on_unsupported: :error])
  end

  test "encodes tools, named choice, strict schema, and parallel call control" do
    tool =
      ReqLLM.Tool.new!(
        name: "weather",
        description: "Get the weather",
        parameter_schema: [city: [type: :string, required: true]],
        callback: fn _ -> {:ok, "sunny"} end,
        strict: true
      )

    choice = %{type: "function", function: %{name: "weather"}}

    assert {:ok, request} =
             prepare(tools: [tool], tool_choice: choice, parallel_tool_calls: false)

    encoded = body(request)
    assert encoded["tool_choice"] == %{"type" => "function", "function" => %{"name" => "weather"}}
    assert encoded["parallel_tool_calls"] == false
    assert get_in(encoded, ["tools", Access.at(0), "function", "strict"]) == true
  end

  test "omits parallel_tool_calls when no tools are supplied" do
    assert {:ok, request} = prepare(parallel_tool_calls: true)
    refute Map.has_key?(body(request), "parallel_tool_calls")
  end

  test "maps the common named tool choice" do
    tool =
      ReqLLM.Tool.new!(
        name: "weather",
        description: "Get the weather",
        parameter_schema: [],
        callback: fn _ -> {:ok, "sunny"} end
      )

    assert {:ok, request} =
             prepare(tools: [tool], tool_choice: %{type: "tool", name: "weather"})

    assert body(request)["tool_choice"] == %{
             "type" => "function",
             "function" => %{"name" => "weather"}
           }
  end

  test "keeps internal message metadata off the wire" do
    assistant = %Message{
      role: :assistant,
      content: [ContentPart.thinking("The answer is six."), ContentPart.text("6")],
      metadata: %{response_id: "chatcmpl-test"},
      reasoning_details: [
        %ReqLLM.Message.ReasoningDetails{
          format: "openai-reasoning-content-v1",
          text: "The answer is six."
        }
      ]
    }

    context = Context.new([Context.user("2 + 4?"), assistant, Context.user("Why?")])
    assert {:ok, request} = prepare([], context)
    encoded = Enum.at(body(request)["messages"], 1)
    assert encoded["reasoning_content"] == "The answer is six."
    refute Map.has_key?(encoded, "metadata")
    refute Map.has_key?(encoded, "reasoning_details")
  end

  test "preserves JSON text and reasoning when it builds a streamed response" do
    chunks = [
      ReqLLM.StreamChunk.thinking("I will return JSON."),
      ReqLLM.StreamChunk.text(~s({"greeting":"hello"}))
    ]

    builder = ReqLLM.Provider.ResponseBuilder.for_model(model())
    assert builder == ReqLLM.Providers.Reflection.ResponseBuilder
    context = Context.new([Context.user("Say hello in JSON.")])
    assert {:ok, response} = builder.build_response(chunks, %{}, model: model(), context: context)
    assert Response.object(response) == %{"greeting" => "hello"}
    assert Response.text(response) == ~s({"greeting":"hello"})
    assert List.last(response.context.messages) == response.message
    assert {:ok, request} = prepare([], response.context)
    assistant = List.last(body(request)["messages"])
    assert assistant["reasoning_content"] == "I will return JSON."
    assert assistant["content"] == ~s({"greeting":"hello"})
  end

  test "uses native JSON schema for object requests" do
    assert {:ok, compiled} = ReqLLM.Schema.compile(greeting: [type: :string, required: true])

    assert {:ok, request} =
             Reflection.prepare_request(:object, model(), "Say hello",
               compiled_schema: compiled,
               api_key: "test-key"
             )

    encoded = body(request)
    assert encoded["response_format"]["type"] == "json_schema"
    assert get_in(encoded, ["response_format", "json_schema", "schema", "properties", "greeting"])
    refute Map.has_key?(encoded, "tools")
  end

  test "encodes JSON mode and the safety identifier" do
    assert {:ok, request} =
             prepare(
               provider_options: %{
                 response_format: %{type: "json_object"},
                 safety_identifier: "user-hash"
               }
             )

    assert body(request)["response_format"] == %{"type" => "json_object"}
    assert body(request)["safety_identifier"] == "user-hash"
  end

  test "decodes reasoning, text, and reasoning usage and preserves a follow-up" do
    raw = %{
      "id" => "chatcmpl-reflection",
      "model" => model().id,
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{
            "role" => "assistant",
            "reasoning_content" => "The answer is six.",
            "content" => "6"
          }
        }
      ],
      "usage" => %{
        "prompt_tokens" => 10,
        "completion_tokens" => 15,
        "total_tokens" => 25,
        "completion_tokens_details" => %{"reasoning_tokens" => 14}
      }
    }

    assert {:ok, request} = prepare()
    {_, response} = Reflection.decode_response({request, %Req.Response{status: 200, body: raw}})
    assert %Response{} = response.body
    assert Response.text(response.body) == "6"
    assert response.body.usage.reasoning_tokens == 14

    assert {:ok, followup} =
             prepare([], Context.append(response.body.context, Context.user("Why?")))

    assistant = Enum.find(body(followup)["messages"], &(&1["role"] == "assistant"))
    assert assistant["reasoning_content"] == "The answer is six."
  end

  test "preserves reasoning and tool calls in a tool result request" do
    assistant = %Message{
      role: :assistant,
      content: [ContentPart.thinking("I need the weather.")],
      tool_calls: [
        %ReqLLM.ToolCall{
          id: "call_weather",
          type: "function",
          function: %{name: "weather", arguments: ~s({"city":"Paris"})}
        }
      ]
    }

    context =
      Context.new([
        Context.user("Weather in Paris?"),
        assistant,
        %Message{role: :tool, tool_call_id: "call_weather", content: [ContentPart.text("sunny")]}
      ])

    assert {:ok, request} = prepare([], context)
    [_, encoded_assistant, encoded_tool] = body(request)["messages"]
    assert encoded_assistant["reasoning_content"] == "I need the weather."
    assert hd(encoded_assistant["tool_calls"])["id"] == "call_weather"
    assert encoded_tool["tool_call_id"] == "call_weather"
  end

  test "rejects assistant history with missing or empty reasoning" do
    for content <- [
          [ContentPart.text("Hello")],
          [ContentPart.thinking(""), ContentPart.text("Hello")]
        ] do
      context = Context.new([Context.user("Hello"), %Message{role: :assistant, content: content}])
      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = error} = prepare([], context)
      assert Exception.message(error) =~ "reasoning_content"

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Reflection.attach_stream(model(), context, [api_key: "test-key"], ReqLLM.Finch)
    end
  end

  test "rejects image, video, and file input before encoding" do
    for part <- [
          ContentPart.image_url("https://example.com/image.png"),
          ContentPart.video_url("https://example.com/video.mp4"),
          ContentPart.file("hello", "hello.txt", "text/plain"),
          %ContentPart{type: :file}
        ] do
      context = Context.new([Context.user([part])])
      assert {:error, %ReqLLM.Error.Invalid.Parameter{} = error} = prepare([], context)
      assert Exception.message(error) =~ "text input only"
    end
  end

  test "rejects unsupported operations" do
    for operation <- [:embedding, :image, :speech, :transcription] do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Reflection.prepare_request(operation, model(), "Hello", [])

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} =
               Reflection.attach_stream(
                 model(),
                 context_fixture(),
                 [operation: operation],
                 ReqLLM.Finch
               )
    end
  end

  test "builds streams with the same token limit and effort" do
    assert {:ok, request} =
             Reflection.attach_stream(
               model(),
               context_fixture(),
               [api_key: "test-key", max_tokens: 2048, reasoning_effort: :low],
               ReqLLM.Finch
             )

    encoded = Jason.decode!(request.body)
    assert request.scheme == :https
    assert request.host == "api.reflection.ai"
    assert request.path == "/openai/v1/chat/completions"
    assert encoded["stream"] == true
    assert encoded["stream_options"] == %{"include_usage" => true}
    assert encoded["max_completion_tokens"] == 2048
    assert encoded["reasoning_effort"] == "low"
    refute Map.has_key?(encoded, "max_tokens")
  end
end

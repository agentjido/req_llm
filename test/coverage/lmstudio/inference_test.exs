defmodule ReqLLM.Coverage.LMStudio.InferenceTest do
  @moduledoc """
  Capability coverage for explicit local LM Studio models through public APIs.

  The shared fixture backend replays recordings by default. Set
  REQ_LLM_FIXTURES_MODE=record to capture live responses synchronously.
  Explicit model specs keep these tests independent of the catalog model matrix.
  """

  use ExUnit.Case, async: false

  alias ReqLLM.{Context, Response, StreamResponse}
  alias ReqLLM.Test.CompatibilityScenario

  @moduletag :coverage
  @moduletag :capture_log
  @moduletag provider: :lmstudio
  @moduletag timeout: 240_000

  @tag category: :core, model: "qwen3.8-27b-mlx"
  @tag CompatibilityScenario.tag!(:basic)
  test "chat retains usage and conversation history" do
    assert {:ok, response} = ReqLLM.generate_text(chat_model(), "Say hello.", opts("chat"))
    assert Response.text(response) =~ ~r/hello/i
    assert response.usage.input_tokens > 0
    assert response.usage.output_tokens > 0
    assert length(response.context.messages) == 2
  end

  @tag category: :streaming, model: "qwen3.8-27b-mlx"
  @tag CompatibilityScenario.tag!(:streaming)
  test "streaming assembles text and usage" do
    assert {:ok, stream} = ReqLLM.stream_text(chat_model(), "Say hello.", opts("streaming"))
    assert {:ok, response} = StreamResponse.to_response(stream)
    assert Response.text(response) =~ ~r/hello/i
    assert response.usage.input_tokens > 0
    assert response.usage.output_tokens > 0
  end

  @tag category: :core, model: "qwen2.5-0.5b-instruct"
  @tag CompatibilityScenario.tag!(:object_basic)
  test "structured output validates the requested schema" do
    assert {:ok, response} =
             ReqLLM.generate_object(
               structured_model(),
               "Return an object with answer set to ok.",
               schema(),
               opts("object")
             )

    assert response.object == %{"answer" => "ok"}
  end

  @tag category: :streaming, model: "qwen2.5-0.5b-instruct"
  @tag CompatibilityScenario.tag!(:object_streaming)
  test "streamed structured output validates the requested schema" do
    assert {:ok, stream} =
             ReqLLM.stream_object(
               structured_model(),
               "Return an object with answer set to ok.",
               schema(),
               opts("streaming_object")
             )

    assert {:ok, response} = StreamResponse.to_response(stream)
    assert response.object == %{"answer" => "ok"}
  end

  @tag category: :tools, model: "qwen3.8-27b-mlx"
  @tag CompatibilityScenario.tag!(:tool_round_trip)
  test "tool call round trip" do
    tool = weather_tool()

    assert {:ok, response} =
             ReqLLM.generate_text(
               chat_model(),
               "Call the weather tool for Paris.",
               opts("tool_call") ++ [tools: [tool], tool_choice: "auto"]
             )

    assert [call] = Response.tool_calls(response)
    assert call.function.name == "weather"
    assert Jason.decode!(call.function.arguments)["city"] == "Paris"

    context =
      Context.append(
        response.context,
        Context.tool_result(call.id, "weather", "Sunny, 22 Celsius")
      )

    assert {:ok, answer} =
             ReqLLM.generate_text(chat_model(), context, opts("tool_result") ++ [tools: [tool]])

    assert Response.text(answer) =~ ~r/sunny|22/i
  end

  @tag category: :tools, scenario: "tool_streaming", model: "qwen3.8-27b-mlx"
  test "streamed tool calls assemble arguments" do
    assert {:ok, stream} =
             ReqLLM.stream_text(
               chat_model(),
               "Call the weather tool for Paris.",
               opts("streaming_tool") ++ [tools: [weather_tool()]]
             )

    assert {:ok, response} = StreamResponse.to_response(stream)
    assert [call] = Response.tool_calls(response)
    assert call.function.name == "weather"
    assert Jason.decode!(call.function.arguments)["city"] == "Paris"
  end

  @tag category: :core, scenario: "vision", model: "qwen3.8-27b-mlx"
  test "vision understands an inline image" do
    image =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAb0lEQVR4nO3PAQkAAAyEwO9feoshgnABdLep8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3IPanc8OLDQitxAAAAAElFTkSuQmCC"
      )

    prompt = [
      Context.user([
        ReqLLM.Message.ContentPart.text(
          "What is the dominant color in this image? Answer with one word."
        ),
        ReqLLM.Message.ContentPart.image(image, "image/png")
      ])
    ]

    assert {:ok, response} = ReqLLM.generate_text(chat_model(), prompt, opts("vision"))
    assert Response.text(response) =~ ~r/red/i
  end

  describe "embeddings" do
    @describetag category: :embedding, model: "text-embedding-nomic-embed-text-v1.5"

    for {input, fixture, scenario} <- [
          {"Hello world", "embedding", :embed_basic},
          {["Hello world", "Goodbye world"], "embedding_batch", :embed_batch}
        ] do
      @embedding_input input
      @embedding_fixture fixture
      @tag CompatibilityScenario.tag!(scenario)
      test "#{scenario}" do
        assert {:ok, result} =
                 ReqLLM.embed(embedding_model(), @embedding_input,
                   fixture: @embedding_fixture,
                   req_http_options: [receive_timeout: 180_000],
                   return_usage: true
                 )

        vectors = embedding_vectors(@embedding_input, result.embedding)
        assert length(vectors) == length(List.wrap(@embedding_input))

        assert Enum.all?(
                 vectors,
                 &(is_list(&1) and &1 != [] and Enum.all?(&1, fn n -> is_float(n) end))
               )

        assert is_integer(result.usage.input_tokens)
        assert result.usage.input_tokens >= 0
      end
    end
  end

  defp embedding_vectors(input, vector) when is_binary(input), do: [vector]
  defp embedding_vectors(_input, vectors), do: vectors

  defp chat_model do
    ReqLLM.model!(%{
      provider: :lmstudio,
      id: "qwen3.8-27b-mlx",
      capabilities: %{chat: true, tools: %{enabled: true}}
    })
  end

  defp structured_model do
    ReqLLM.model!(%{provider: :lmstudio, id: "qwen2.5-0.5b-instruct"})
  end

  defp schema, do: [answer: [type: :string, required: true]]

  defp embedding_model do
    ReqLLM.model!(%{
      provider: :lmstudio,
      id: "text-embedding-nomic-embed-text-v1.5",
      capabilities: %{embeddings: true}
    })
  end

  defp opts(fixture) do
    [
      fixture: fixture,
      receive_timeout: 180_000,
      max_tokens: 512,
      temperature: 0.0,
      reasoning_effort: :none,
      max_retries: 0
    ]
  end

  defp weather_tool do
    ReqLLM.tool(
      name: "weather",
      description: "Get the current weather in a city",
      parameter_schema: [city: [type: :string, required: true]],
      callback: fn _ -> {:ok, "Sunny, 22 Celsius"} end
    )
  end
end

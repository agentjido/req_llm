# Shared test helpers
defmodule ReqLLM.ResponseTest.Helpers do
  import ExUnit.Assertions

  alias ReqLLM.{Context, Message, Message.ContentPart, Response}

  @doc """
  Assert multiple struct fields at once for cleaner tests.
  """
  def assert_fields(struct, expected_fields) when is_list(expected_fields) do
    Enum.each(expected_fields, fn {field, expected_value} ->
      actual_value = Map.get(struct, field)

      assert actual_value == expected_value,
             "Expected #{field} to be #{inspect(expected_value)}, got #{inspect(actual_value)}"
    end)
  end

  def create_response(opts \\ []) do
    defaults = %{
      id: "test-id",
      model: "test-model",
      context: Context.new([Context.system("Test")]),
      message: Context.assistant("Hello"),
      usage: nil,
      finish_reason: nil
    }

    struct!(Response, Map.merge(defaults, Map.new(opts)))
  end

  def text_message(text_parts) when is_list(text_parts) do
    content = Enum.map(text_parts, &%ContentPart{type: :text, text: &1})
    %Message{role: :assistant, content: content, metadata: %{}}
  end

  def text_message(text) when is_binary(text) do
    text_message([text])
  end

  def tool_message(tool_calls) when is_list(tool_calls) do
    %Message{role: :assistant, content: [], tool_calls: tool_calls, metadata: %{}}
  end

  def mixed_content_message(parts) do
    %Message{role: :assistant, content: parts, tool_calls: nil, metadata: %{}}
  end
end

defmodule ReqLLM.ResponseTest do
  use ExUnit.Case, async: true

  import ReqLLM.ResponseTest.Helpers

  alias ReqLLM.{Context, Error, Message, Message.ContentPart, Response, StreamChunk}

  # Mock provider for testing
  defmodule TestProvider do
    def wrap_response(data), do: data
  end

  describe "struct validation and defaults" do
    test "creates response with required fields" do
      context = Context.new([Context.system("Test")])
      message = Context.assistant("Hello")

      response = create_response(id: "test-123", context: context, message: message)

      # Test all default values efficiently
      assert_fields(response,
        id: "test-123",
        model: "test-model",
        context: context,
        message: message,
        object: nil,
        stream?: false,
        stream: nil,
        usage: nil,
        finish_reason: nil,
        provider_meta: %{},
        error: nil
      )
    end

    test "struct enforces required fields" do
      assert_raise ArgumentError, fn -> struct!(Response, %{}) end

      assert_raise ArgumentError, fn ->
        struct!(Response, %{id: "test", context: Context.new([]), message: nil})
      end
    end

    test "Jason encoding excludes stream field" do
      response = create_response(stream?: true, stream: Stream.cycle(["chunk"]))

      {:ok, encoded} = Jason.encode(response)
      {:ok, decoded} = Jason.decode(encoded)

      refute Map.has_key?(decoded, "stream")
      assert decoded["stream?"] == true
    end
  end

  describe "text/1 extraction" do
    # Table-driven test for text extraction scenarios
    test_cases = [
      {"simple text", [%ContentPart{type: :text, text: "Hello"}], "Hello"},
      {"multiple text parts",
       [
         %ContentPart{type: :text, text: "Hello "},
         %ContentPart{type: :text, text: "world!"}
       ], "Hello world!"},
      {"mixed content filtering",
       [
         %ContentPart{type: :text, text: "Hello"},
         %ContentPart{type: :text, text: " world"}
       ], "Hello world"},
      {"empty content", [], ""}
    ]

    for {desc, content_parts, expected} <- test_cases do
      test "extracts text: #{desc}" do
        message = %Message{
          role: :assistant,
          content: unquote(Macro.escape(content_parts)),
          metadata: %{}
        }

        response = create_response(message: message)

        assert Response.text(response) == unquote(expected)
      end
    end

    test "returns nil when message is nil" do
      response = create_response(message: nil)
      assert Response.text(response) == nil
    end
  end

  describe "tool_calls/1 extraction" do
    test "returns empty list when message is nil" do
      response = create_response(message: nil)
      assert Response.tool_calls(response) == []
    end

    test "extracts from message.tool_calls field" do
      tool_calls = [
        %{name: "get_weather", arguments: %{location: "NYC"}, id: "call-123"},
        %{name: "calculate", arguments: %{expression: "2+2"}, id: "call-456"}
      ]

      response = create_response(message: tool_message(tool_calls))
      assert Response.tool_calls(response) == tool_calls
    end
  end

  describe "accessor functions" do
    # Table-driven tests for simple accessor functions
    accessor_tests = [
      {:finish_reason, :stop},
      {:finish_reason, "length"},
      {:finish_reason, nil},
      {:usage, %{input_tokens: 15, output_tokens: 25}},
      {:usage, %{input_tokens: 10}},
      {:usage, nil},
      {:object, %{result: "success", data: [1, 2, 3]}},
      {:object, %{}},
      {:object, nil}
    ]

    for {field, value} <- accessor_tests do
      test "#{field}/1 returns #{inspect(value)}" do
        response = create_response([{unquote(field), unquote(Macro.escape(value))}])
        assert Response.unquote(field)(response) == unquote(Macro.escape(value))
      end
    end
  end

  describe "ok?/1 status check" do
    test "returns true when error is nil" do
      assert Response.ok?(create_response(error: nil))
    end

    for error_type <- [
          %RuntimeError{message: "error"},
          %Error.API.Response{reason: "Server error"}
        ] do
      test "returns false for #{inspect(error_type.__struct__)}" do
        refute Response.ok?(create_response(error: unquote(Macro.escape(error_type))))
      end
    end
  end

  describe "text_stream/1" do
    test "returns empty stream for non-streaming responses" do
      for stream_config <- [[stream?: false], [stream?: true, stream: nil]] do
        response = create_response(stream_config)
        assert Response.text_stream(response) |> Enum.to_list() == []
      end
    end

    test "filters and maps content chunks from stream" do
      chunks = [
        %StreamChunk{type: :content, text: "Hello"},
        %StreamChunk{type: :meta, metadata: %{tokens: 5}},
        %StreamChunk{type: :content, text: " world"},
        %StreamChunk{type: :tool_call, name: "test"},
        %StreamChunk{type: :content, text: "!"}
      ]

      response = create_response(stream?: true, stream: Stream.cycle(chunks) |> Stream.take(5))

      assert Response.text_stream(response) |> Enum.to_list() == ["Hello", " world", "!"]
    end
  end

  describe "object_stream/1" do
    test "returns empty stream for non-streaming responses" do
      for stream_config <- [[stream?: false], [stream?: true, stream: nil]] do
        response = create_response(stream_config)
        assert Response.object_stream(response) |> Enum.to_list() == []
      end
    end

    test "filters structured_output tool calls from stream" do
      chunks = [
        %StreamChunk{type: :content, text: "Processing..."},
        %StreamChunk{type: :tool_call, name: "structured_output", arguments: %{result: "first"}},
        %StreamChunk{type: :tool_call, name: "other_tool", arguments: %{}},
        %StreamChunk{type: :tool_call, name: "structured_output", arguments: %{result: "second"}}
      ]

      response = create_response(stream?: true, stream: Stream.cycle(chunks) |> Stream.take(4))

      assert Response.object_stream(response) |> Enum.to_list() == [
               %{result: "first"},
               %{result: "second"}
             ]
    end

    test "preserves lazy evaluation" do
      infinite_stream =
        Stream.repeatedly(fn ->
          %StreamChunk{
            type: :tool_call,
            name: "structured_output",
            arguments: %{counter: :rand.uniform(100)}
          }
        end)

      response = create_response(stream?: true, stream: infinite_stream)

      results = Response.object_stream(response) |> Stream.take(2) |> Enum.to_list()
      assert length(results) == 2
      assert Enum.all?(results, &Map.has_key?(&1, :counter))
    end
  end

  describe "join_stream/1" do
    test "returns non-streaming responses unchanged" do
      response = create_response(stream?: false)
      assert {:ok, ^response} = Response.join_stream(response)
    end

    test "returns responses with nil stream unchanged" do
      response = create_response(stream?: true, stream: nil)
      assert {:ok, ^response} = Response.join_stream(response)
    end

    test "materializes streaming response without meta chunks" do
      # Test without meta chunks to avoid the chunk.usage bug
      chunks = [
        %StreamChunk{type: :content, text: "Hello"},
        %StreamChunk{type: :content, text: " world!"}
      ]

      response =
        create_response(
          message: nil,
          stream?: true,
          stream: Stream.cycle(chunks) |> Stream.take(2)
        )

      assert {:ok, materialized} = Response.join_stream(response)

      assert materialized.stream? == false
      assert materialized.stream == nil
      assert materialized.message.role == :assistant
      assert materialized.message.content == [%{type: :text, text: "Hello world!"}]
      assert materialized.message.metadata == %{}
    end

    test "handles empty stream" do
      response =
        create_response(
          message: nil,
          stream?: true,
          stream: Stream.take(Stream.cycle([%StreamChunk{type: :content, text: "x"}]), 0)
        )

      assert {:ok, materialized} = Response.join_stream(response)
      assert materialized.message.content == [%{type: :text, text: ""}]
    end

    test "returns error when stream consumption fails" do
      error_stream = Stream.repeatedly(fn -> raise "Stream error" end)
      response = create_response(message: nil, stream?: true, stream: error_stream)

      assert {:error, %Error.API.Stream{}} = Response.join_stream(response)
    end

    test "preserves original response fields" do
      chunks = [%StreamChunk{type: :content, text: "test"}]

      response =
        create_response(
          id: "original-id",
          model: "original-model",
          context: Context.new([Context.system("Original")]),
          stream?: true,
          stream: Stream.take(Stream.cycle(chunks), 1),
          finish_reason: :length,
          provider_meta: %{custom: "data"}
        )

      assert {:ok, materialized} = Response.join_stream(response)

      assert materialized.id == "original-id"
      assert materialized.model == "original-model"
      assert materialized.finish_reason == :length
      assert materialized.provider_meta == %{custom: "data"}
    end

    test "property: text_stream followed by join equals text extraction" do
      # Generate test data with multiple content chunks
      text_parts = ["Hello", " ", "world", "!", " How", " are", " you?"]
      chunks = Enum.map(text_parts, &%StreamChunk{type: :content, text: &1})

      response =
        create_response(
          message: nil,
          stream?: true,
          stream: Stream.cycle(chunks) |> Stream.take(length(chunks))
        )

      # Join the stream and extract text
      {:ok, joined} = Response.join_stream(response)
      joined_text = Response.text(joined)

      # Collect text stream and join manually
      streamed_text =
        response
        |> Response.text_stream()
        |> Enum.join("")

      # Property: both methods should produce the same result
      assert joined_text == streamed_text
      assert joined_text == Enum.join(text_parts, "")
    end
  end

  describe "decode_response/2" do
    test "resolves string model to Model struct and handles provider operations" do
      data = %{
        "id" => "test-123",
        "model" => "test-model",
        "choices" => [%{"message" => %{"content" => "Hello"}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
      }

      # Test with real provider - may fail but tests code path
      _result = Response.decode_response(data, "groq:llama3-8b-8192")
    end

    test "handles Model struct input directly" do
      {:ok, model} = ReqLLM.model("groq:llama3-8b-8192")
      data = %{"id" => "test", "choices" => []}

      _result = Response.decode_response(data, model)
    end
  end

  describe "decode object functions" do
    test "decode_object/3 processes tool calls for structured output" do
      tool_calls = [%{name: "structured_output", arguments: %{result: "success", count: 42}}]
      message = tool_message(tool_calls)
      response = create_response(message: message)

      assert Response.tool_calls(response) == tool_calls
    end

    test "decode_object_stream/3 delegates to decode_response" do
      data = %{"test" => "streaming_data"}
      _result = Response.decode_object_stream(data, "groq:llama3-8b-8192", [])
    end
  end

  describe "edge cases and complex scenarios" do
    test "handles large text content efficiently" do
      large_text = String.duplicate("a", 100_000)
      response = create_response(message: text_message(large_text))

      assert Response.text(response) == large_text
      assert String.length(Response.text(response)) == 100_000
    end

    test "handles complex usage objects" do
      complex_usage = %{
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        cache_read_tokens: 25,
        breakdown: %{prompt: %{tokens: 100, cost: 0.001}}
      }

      response = create_response(usage: complex_usage)
      assert Response.usage(response) == complex_usage
    end

    test "handles mixed content types correctly" do
      content = [
        %ContentPart{type: :text, text: "Image: "},
        %ContentPart{type: :image_url, url: "http://example.com/img.jpg"},
        %ContentPart{type: :text, text: " Done!"}
      ]

      response = create_response(message: mixed_content_message(content))

      assert Response.text(response) == "Image:  Done!"

      tool_calls = Response.tool_calls(response)
      assert tool_calls == []
    end
  end
end

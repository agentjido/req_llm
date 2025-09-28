# Shared test helpers
defmodule ReqLLM.StreamResponseTest.Helpers do
  import ExUnit.Assertions

  alias ReqLLM.{Context, Model, StreamChunk, StreamResponse}

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

  def create_stream_response(opts \\ []) do
    defaults = %{
      stream: Stream.cycle([StreamChunk.text("hello")]) |> Stream.take(1),
      metadata_task:
        Task.async(fn ->
          %{usage: %{input_tokens: 5, output_tokens: 10}, finish_reason: :stop}
        end),
      cancel: fn -> :ok end,
      model: %Model{provider: :test, model: "test-model"},
      context: Context.new([Context.system("Test")])
    }

    struct!(StreamResponse, Map.merge(defaults, Map.new(opts)))
  end

  def create_metadata_task(data) do
    Task.async(fn -> data end)
  end

  def create_cancel_function(ref \\ make_ref()) do
    fn -> send(self(), {:canceled, ref}) end
  end

  def text_chunks(texts) when is_list(texts) do
    Enum.map(texts, &StreamChunk.text/1)
  end

  def mixed_chunks do
    [
      StreamChunk.text("Hello "),
      StreamChunk.meta(%{tokens: 3}),
      StreamChunk.text("world"),
      StreamChunk.tool_call("test_tool", %{arg: "value"}),
      StreamChunk.text("!")
    ]
  end
end

defmodule ReqLLM.StreamResponseTest do
  use ExUnit.Case, async: true

  import ReqLLM.StreamResponseTest.Helpers

  alias ReqLLM.{Context, Model, Response, StreamChunk, StreamResponse}

  describe "struct validation and defaults" do
    test "creates stream response with required fields" do
      context = Context.new([Context.system("Test")])
      model = %Model{provider: :test, model: "test-model"}
      metadata_task = create_metadata_task(%{usage: %{tokens: 10}, finish_reason: :stop})
      cancel_fn = create_cancel_function()
      stream = [StreamChunk.text("hello")]

      stream_response =
        create_stream_response(
          context: context,
          model: model,
          metadata_task: metadata_task,
          cancel: cancel_fn,
          stream: stream
        )

      assert_fields(stream_response,
        context: context,
        model: model,
        stream: stream
      )

      assert is_function(stream_response.cancel, 0)
      assert %Task{} = stream_response.metadata_task
    end

    test "struct enforces required fields" do
      assert_raise ArgumentError, fn -> struct!(StreamResponse, %{}) end

      assert_raise ArgumentError, fn ->
        struct!(StreamResponse, %{stream: [], model: nil})
      end
    end
  end

  describe "tokens/1 filtering" do
    test "filters tokens: simple content chunks" do
      chunks = [StreamChunk.text("Hello"), StreamChunk.text(" world")]
      expected = ["Hello", " world"]

      stream_response =
        create_stream_response(stream: Stream.cycle(chunks) |> Stream.take(length(chunks)))

      actual = StreamResponse.tokens(stream_response) |> Enum.to_list()
      assert actual == expected
    end

    test "filters tokens: mixed content filtering" do
      chunks = [
        StreamChunk.text("Hello"),
        StreamChunk.meta(%{tokens: 5}),
        StreamChunk.text(" world"),
        StreamChunk.tool_call("test", %{}),
        StreamChunk.text("!")
      ]

      expected = ["Hello", " world", "!"]

      stream_response =
        create_stream_response(stream: Stream.cycle(chunks) |> Stream.take(length(chunks)))

      actual = StreamResponse.tokens(stream_response) |> Enum.to_list()
      assert actual == expected
    end

    test "filters tokens: no content chunks" do
      chunks = [
        StreamChunk.meta(%{finish_reason: :stop}),
        StreamChunk.tool_call("test", %{arg: "value"})
      ]

      expected = []

      stream_response =
        create_stream_response(stream: Stream.cycle(chunks) |> Stream.take(length(chunks)))

      actual = StreamResponse.tokens(stream_response) |> Enum.to_list()
      assert actual == expected
    end

    test "filters tokens: empty stream" do
      stream_response = create_stream_response(stream: [])

      actual = StreamResponse.tokens(stream_response) |> Enum.to_list()
      assert actual == []
    end

    test "preserves lazy evaluation" do
      # Create infinite stream
      infinite_stream = Stream.repeatedly(fn -> StreamChunk.text("chunk") end)
      stream_response = create_stream_response(stream: infinite_stream)

      # Should only evaluate as many items as we take
      result = StreamResponse.tokens(stream_response) |> Stream.take(3) |> Enum.to_list()
      assert result == ["chunk", "chunk", "chunk"]
    end
  end

  describe "text/1 collection" do
    test "joins all content tokens into single string" do
      chunks = text_chunks(["Hello", " ", "world", "!"])
      stream_response = create_stream_response(stream: chunks)

      assert StreamResponse.text(stream_response) == "Hello world!"
    end

    test "filters out non-content chunks" do
      chunks = mixed_chunks()
      stream_response = create_stream_response(stream: chunks)

      assert StreamResponse.text(stream_response) == "Hello world!"
    end

    test "handles empty stream" do
      stream_response = create_stream_response(stream: [])

      assert StreamResponse.text(stream_response) == ""
    end

    test "handles stream with no content chunks" do
      chunks = [
        StreamChunk.meta(%{finish_reason: :stop}),
        StreamChunk.tool_call("test", %{arg: "value"})
      ]

      stream_response = create_stream_response(stream: chunks)

      assert StreamResponse.text(stream_response) == ""
    end

    test "handles large text efficiently" do
      large_chunks = List.duplicate("chunk ", 10_000)
      chunks = text_chunks(large_chunks)
      stream_response = create_stream_response(stream: chunks)

      result = StreamResponse.text(stream_response)
      assert String.starts_with?(result, "chunk chunk chunk")
      # 10,000 * "chunk " (6 chars each)
      assert String.length(result) == 60_000
    end
  end

  describe "usage/1 metadata extraction" do
    test "awaits task and extracts usage map" do
      usage = %{input_tokens: 15, output_tokens: 25, total_cost: 0.045}
      metadata_task = create_metadata_task(%{usage: usage, finish_reason: :stop})

      stream_response = create_stream_response(metadata_task: metadata_task)

      assert StreamResponse.usage(stream_response) == usage
    end

    test "returns nil when usage not available" do
      metadata_task = create_metadata_task(%{finish_reason: :stop})
      stream_response = create_stream_response(metadata_task: metadata_task)

      assert StreamResponse.usage(stream_response) == nil
    end

    test "returns nil when task returns non-map" do
      metadata_task = create_metadata_task("invalid")
      stream_response = create_stream_response(metadata_task: metadata_task)

      assert StreamResponse.usage(stream_response) == nil
    end

    test "handles complex usage structures" do
      usage = %{
        input_tokens: 100,
        output_tokens: 50,
        cache_read_tokens: 25,
        breakdown: %{
          prompt: %{tokens: 100, cost: 0.01},
          completion: %{tokens: 50, cost: 0.02}
        },
        total_cost: 0.03
      }

      metadata_task = create_metadata_task(%{usage: usage})
      stream_response = create_stream_response(metadata_task: metadata_task)

      assert StreamResponse.usage(stream_response) == usage
    end
  end

  describe "finish_reason/1 metadata extraction" do
    # Table-driven tests for finish reason scenarios
    finish_reason_tests = [
      {:stop, :stop},
      {:length, :length},
      {:tool_use, :tool_use},
      {"stop", :stop},
      {"length", :length},
      {"tool_use", :tool_use}
    ]

    for {input, expected} <- finish_reason_tests do
      test "extracts finish_reason: #{inspect(input)} -> #{inspect(expected)}" do
        metadata_task = create_metadata_task(%{finish_reason: unquote(input)})
        stream_response = create_stream_response(metadata_task: metadata_task)

        assert StreamResponse.finish_reason(stream_response) == unquote(expected)
      end
    end

    test "returns nil when finish_reason not available" do
      metadata_task = create_metadata_task(%{usage: %{tokens: 10}})
      stream_response = create_stream_response(metadata_task: metadata_task)

      assert StreamResponse.finish_reason(stream_response) == nil
    end

    test "returns nil when task returns non-map" do
      metadata_task = create_metadata_task(nil)
      stream_response = create_stream_response(metadata_task: metadata_task)

      assert StreamResponse.finish_reason(stream_response) == nil
    end
  end

  describe "to_response/1 backward compatibility" do
    test "converts simple streaming response to legacy Response" do
      chunks = text_chunks(["Hello", " world!"])
      usage = %{input_tokens: 8, output_tokens: 12, total_cost: 0.024}
      metadata_task = create_metadata_task(%{usage: usage, finish_reason: :stop})

      stream_response =
        create_stream_response(
          stream: chunks,
          metadata_task: metadata_task
        )

      {:ok, response} = StreamResponse.to_response(stream_response)

      # Verify Response struct structure
      assert %Response{} = response
      assert response.stream? == false
      assert response.stream == nil
      assert response.usage == usage
      assert response.finish_reason == :stop
      assert response.model == "test-model"
      assert response.error == nil

      # Verify message content
      assert response.message.role == :assistant
      assert Response.text(response) == "Hello world!"
      assert response.message.tool_calls == nil
    end

    test "handles tool calls in stream" do
      chunks = [
        StreamChunk.text("I'll help you with that."),
        StreamChunk.tool_call("get_weather", %{city: "NYC"}, %{tool_call_id: "call-123"}),
        StreamChunk.tool_call("calculate", %{expr: "2+2"}, %{tool_call_id: "call-456"})
      ]

      metadata_task = create_metadata_task(%{finish_reason: :tool_use})

      stream_response =
        create_stream_response(
          stream: chunks,
          metadata_task: metadata_task
        )

      {:ok, response} = StreamResponse.to_response(stream_response)

      # Verify message content
      assert Response.text(response) == "I'll help you with that."

      tool_calls = Response.tool_calls(response)
      assert length(tool_calls) == 2
      assert Enum.find(tool_calls, &(&1.name == "get_weather"))
      assert Enum.find(tool_calls, &(&1.name == "calculate"))
    end

    test "handles empty stream" do
      stream_response =
        create_stream_response(
          stream: [],
          metadata_task: create_metadata_task(%{finish_reason: :stop})
        )

      {:ok, response} = StreamResponse.to_response(stream_response)

      assert Response.text(response) == ""
      assert response.message.content == []
    end

    test "handles stream without text content" do
      chunks = [
        StreamChunk.meta(%{tokens: 5}),
        StreamChunk.tool_call("test", %{arg: "value"})
      ]

      stream_response =
        create_stream_response(
          stream: chunks,
          metadata_task: create_metadata_task(%{finish_reason: :tool_use})
        )

      {:ok, response} = StreamResponse.to_response(stream_response)

      assert Response.text(response) == ""
      assert length(Response.tool_calls(response)) == 1
    end

    test "preserves context and model information" do
      original_context =
        Context.new([
          Context.system("You are helpful"),
          Context.user("Hello!")
        ])

      original_model = %Model{provider: :anthropic, model: "claude-3-sonnet"}

      stream_response =
        create_stream_response(
          context: original_context,
          model: original_model,
          stream: [StreamChunk.text("Hi there!")]
        )

      {:ok, response} = StreamResponse.to_response(stream_response)

      assert response.context == original_context
      assert response.model == "claude-3-sonnet"
    end

    test "handles stream enumeration errors" do
      # Create stream that will fail during enumeration
      error_stream =
        Stream.map([StreamChunk.text("Hello")], fn chunk ->
          if chunk.text == "Hello" do
            raise "Stream processing failed"
          end

          chunk
        end)

      stream_response =
        create_stream_response(
          stream: error_stream,
          metadata_task: create_metadata_task(%{finish_reason: :stop})
        )

      # Enum.to_list will raise, which to_response should catch
      result = StreamResponse.to_response(stream_response)

      assert {:error, %RuntimeError{message: "Stream processing failed"}} = result
    end

    test "generates unique response IDs" do
      stream_response1 = create_stream_response(stream: [StreamChunk.text("test1")])
      stream_response2 = create_stream_response(stream: [StreamChunk.text("test2")])

      {:ok, response1} = StreamResponse.to_response(stream_response1)
      {:ok, response2} = StreamResponse.to_response(stream_response2)

      assert response1.id != response2.id
      assert String.starts_with?(response1.id, "stream_response_")
      assert String.starts_with?(response2.id, "stream_response_")
    end
  end

  describe "cancel function handling" do
    test "cancel function is called when invoked" do
      ref = make_ref()
      cancel_fn = create_cancel_function(ref)

      stream_response = create_stream_response(cancel: cancel_fn)

      stream_response.cancel.()

      assert_received {:canceled, ^ref}
    end

    test "cancel function can be arbitrary logic" do
      {:ok, agent} = Agent.start_link(fn -> :running end)

      cancel_fn = fn ->
        Agent.update(agent, fn _ -> :canceled end)
        :ok
      end

      stream_response = create_stream_response(cancel: cancel_fn)

      assert Agent.get(agent, & &1) == :running

      stream_response.cancel.()

      assert Agent.get(agent, & &1) == :canceled
    end
  end

  describe "integration and edge cases" do
    test "handles concurrent stream consumption and metadata collection" do
      chunks = text_chunks(Enum.map(1..100, &"chunk #{&1} "))

      # Simulate slow metadata collection
      metadata_task =
        Task.async(fn ->
          # Small delay to ensure concurrency
          Process.sleep(10)
          %{usage: %{tokens: 100}, finish_reason: :stop}
        end)

      stream_response =
        create_stream_response(
          stream: chunks,
          metadata_task: metadata_task
        )

      # Test text collection and usage from same process
      text = StreamResponse.text(stream_response)

      # Create fresh stream_response for usage test
      metadata_task2 = Task.async(fn -> %{usage: %{tokens: 100}, finish_reason: :stop} end)
      stream_response2 = create_stream_response(metadata_task: metadata_task2)
      usage = StreamResponse.usage(stream_response2)

      assert String.starts_with?(text, "chunk 1 chunk 2")
      assert usage == %{tokens: 100}
    end

    test "property: tokens stream followed by join equals text/1" do
      chunks = text_chunks(["Hello", " ", "world", "!", " How", " are", " you?"])

      stream_response = create_stream_response(stream: chunks)

      # Collect via text/1
      direct_text = StreamResponse.text(stream_response)

      # Collect via tokens/1 stream (need fresh stream_response)
      stream_response2 = create_stream_response(stream: chunks)
      streamed_text = StreamResponse.tokens(stream_response2) |> Enum.join("")

      # Property: both methods should produce same result
      assert direct_text == streamed_text
      assert direct_text == "Hello world! How are you?"
    end

    test "preserves stream laziness in tokens/1" do
      # Infinite stream with side effects
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      infinite_chunks =
        Stream.repeatedly(fn ->
          Agent.update(counter, &(&1 + 1))
          StreamChunk.text("chunk")
        end)

      stream_response = create_stream_response(stream: infinite_chunks)

      # Take only 3 items
      result = StreamResponse.tokens(stream_response) |> Stream.take(3) |> Enum.to_list()

      assert result == ["chunk", "chunk", "chunk"]
      # Should have only called the generator 3 times
      assert Agent.get(counter, & &1) == 3
    end
  end
end

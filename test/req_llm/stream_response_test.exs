# Shared test helpers
defmodule ReqLLM.StreamResponseTest.Helpers do
  import ExUnit.Assertions

  alias ReqLLM.{Context, StreamChunk, StreamResponse, StreamResponse.MetadataHandle, ToolCall}

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
      metadata_handle:
        create_metadata_handle(%{
          usage: %{input_tokens: 5, output_tokens: 10},
          finish_reason: :stop
        }),
      cancel: fn -> :ok end,
      model: %LLMDB.Model{provider: :test, id: "test-model"},
      context: Context.new([Context.system("Test")])
    }

    struct!(StreamResponse, Map.merge(defaults, Map.new(opts)))
  end

  def create_metadata_handle(data_or_fun) do
    fetch_fun =
      if is_function(data_or_fun, 0) do
        data_or_fun
      else
        fn -> data_or_fun end
      end

    {:ok, handle} = MetadataHandle.start_link(fetch_fun)
    handle
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

  alias ReqLLM.{Context, Response, StreamChunk, StreamResponse, ToolCall}

  describe "struct validation and defaults" do
    test "creates stream response with required fields" do
      context = Context.new([Context.system("Test")])
      model = %LLMDB.Model{provider: :test, id: "test-model"}
      metadata_handle = create_metadata_handle(%{usage: %{tokens: 10}, finish_reason: :stop})
      cancel_fn = create_cancel_function()
      stream = [StreamChunk.text("hello")]

      stream_response =
        create_stream_response(
          context: context,
          model: model,
          metadata_handle: metadata_handle,
          cancel: cancel_fn,
          stream: stream
        )

      assert_fields(stream_response,
        context: context,
        model: model,
        stream: stream
      )

      assert is_function(stream_response.cancel, 0)
      assert is_pid(stream_response.metadata_handle)
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
      metadata_handle = create_metadata_handle(%{usage: usage, finish_reason: :stop})

      stream_response = create_stream_response(metadata_handle: metadata_handle)

      assert StreamResponse.usage(stream_response) == usage
    end

    test "returns nil when usage not available" do
      metadata_handle = create_metadata_handle(%{finish_reason: :stop})
      stream_response = create_stream_response(metadata_handle: metadata_handle)

      assert StreamResponse.usage(stream_response) == nil
    end

    test "returns nil when task returns non-map" do
      metadata_handle = create_metadata_handle("invalid")
      stream_response = create_stream_response(metadata_handle: metadata_handle)

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

      metadata_handle = create_metadata_handle(%{usage: usage})
      stream_response = create_stream_response(metadata_handle: metadata_handle)

      assert StreamResponse.usage(stream_response) == usage
    end

    test "can be called multiple times safely" do
      usage = %{input_tokens: 5, output_tokens: 10}
      metadata_handle = create_metadata_handle(%{usage: usage})
      stream_response = create_stream_response(metadata_handle: metadata_handle)

      assert StreamResponse.usage(stream_response) == usage
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
        metadata_handle = create_metadata_handle(%{finish_reason: unquote(input)})
        stream_response = create_stream_response(metadata_handle: metadata_handle)

        assert StreamResponse.finish_reason(stream_response) == unquote(expected)
      end
    end

    test "returns nil when finish_reason not available" do
      metadata_handle = create_metadata_handle(%{usage: %{tokens: 10}})
      stream_response = create_stream_response(metadata_handle: metadata_handle)

      assert StreamResponse.finish_reason(stream_response) == nil
    end

    test "returns nil when task returns non-map" do
      metadata_handle = create_metadata_handle(nil)
      stream_response = create_stream_response(metadata_handle: metadata_handle)

      assert StreamResponse.finish_reason(stream_response) == nil
    end

    test "can be called multiple times safely" do
      metadata_handle = create_metadata_handle(%{finish_reason: :stop})
      stream_response = create_stream_response(metadata_handle: metadata_handle)

      assert StreamResponse.finish_reason(stream_response) == :stop
      assert StreamResponse.finish_reason(stream_response) == :stop
    end
  end

  describe "to_response/1 backward compatibility" do
    test "converts simple streaming response to legacy Response" do
      chunks = text_chunks(["Hello", " world!"])
      usage = %{input_tokens: 8, output_tokens: 12, total_cost: 0.024}
      metadata_handle = create_metadata_handle(%{usage: usage, finish_reason: :stop})

      stream_response =
        create_stream_response(
          stream: chunks,
          metadata_handle: metadata_handle
        )

      {:ok, response} = StreamResponse.to_response(stream_response)

      # Verify Response struct structure
      assert %Response{} = response
      assert response.stream? == false
      assert response.stream == nil

      # Usage may have normalized fields added (reasoning_tokens, cached_tokens)
      assert response.usage.input_tokens == 8
      assert response.usage.output_tokens == 12
      assert response.usage.total_cost == 0.024
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

      metadata_handle = create_metadata_handle(%{finish_reason: :tool_use})

      stream_response =
        create_stream_response(
          stream: chunks,
          metadata_handle: metadata_handle
        )

      {:ok, response} = StreamResponse.to_response(stream_response)

      # Verify message content
      assert Response.text(response) == "I'll help you with that."

      tool_calls = Response.tool_calls(response)
      assert length(tool_calls) == 2
      assert Enum.find(tool_calls, &ToolCall.matches_name?(&1, "get_weather"))
      assert Enum.find(tool_calls, &ToolCall.matches_name?(&1, "calculate"))
    end

    test "handles empty stream" do
      stream_response =
        create_stream_response(
          stream: [],
          metadata_handle: create_metadata_handle(%{finish_reason: :stop})
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
          metadata_handle: create_metadata_handle(%{finish_reason: :tool_use})
        )

      {:ok, response} = StreamResponse.to_response(stream_response)

      assert Response.text(response) == ""
      assert length(Response.tool_calls(response)) == 1
    end

    test "preserves context advancement and model information" do
      original_context =
        Context.new([
          Context.system("You are helpful"),
          Context.user("Hello!")
        ])

      {:ok, original_model} = ReqLLM.model("anthropic:claude-sonnet-4-5-20250929")

      stream_response =
        create_stream_response(
          context: original_context,
          model: original_model,
          stream: [StreamChunk.text("Hi there!")]
        )

      {:ok, response} = StreamResponse.to_response(stream_response)

      assert response.context == Context.append(original_context, response.message)
      assert response.model == "claude-sonnet-4-5-20250929"
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
          metadata_handle: create_metadata_handle(%{finish_reason: :stop})
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
      assert String.starts_with?(response1.id, "resp_")
      assert String.starts_with?(response2.id, "resp_")
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

  describe "process_stream/2 real-time callbacks" do
    test "calls on_result callback immediately for content chunks" do
      chunks = text_chunks(["Hello", " ", "world"])
      stream_response = create_stream_response(stream: chunks)

      # Collect results via message passing
      parent = self()

      {:ok, response} =
        StreamResponse.process_stream(stream_response,
          on_result: fn text -> send(parent, {:content, text}) end
        )

      # Verify callbacks were called in order
      assert_received {:content, "Hello"}
      assert_received {:content, " "}
      assert_received {:content, "world"}

      # Verify response contains accumulated text
      assert Response.text(response) == "Hello world"
      assert %Response{} = response
    end

    test "calls on_thinking callback immediately for thinking chunks" do
      chunks = [
        StreamChunk.thinking("Let me think..."),
        StreamChunk.thinking(" about this"),
        StreamChunk.text("The answer is 42")
      ]

      stream_response = create_stream_response(stream: chunks)
      parent = self()

      {:ok, response} =
        StreamResponse.process_stream(stream_response,
          on_thinking: fn text -> send(parent, {:thinking, text}) end,
          on_result: fn text -> send(parent, {:content, text}) end
        )

      # Verify thinking callbacks fired
      assert_received {:thinking, "Let me think..."}
      assert_received {:thinking, " about this"}
      assert_received {:content, "The answer is 42"}

      # Verify response contains both thinking and text
      assert Response.text(response) == "The answer is 42"
      # Check that thinking content is in message
      thinking_parts = Enum.filter(response.message.content, &(&1.type == :thinking))
      assert length(thinking_parts) == 1
      assert hd(thinking_parts).text == "Let me think... about this"
    end

    test "reconstructs tool calls with fragmented arguments in response" do
      chunks = [
        StreamChunk.text("I'll help with that."),
        StreamChunk.tool_call("get_weather", %{city: "NYC"}, %{
          id: "call-123",
          index: 0
        }),
        StreamChunk.tool_call("calculator", %{}, %{
          id: "call-456",
          index: 1
        }),
        # Simulate fragmented arguments
        StreamChunk.meta(%{
          tool_call_args: %{index: 1, fragment: ~s({"operation":"add",)}
        }),
        StreamChunk.meta(%{
          tool_call_args: %{index: 1, fragment: ~s("operands":[2,2]})}
        })
      ]

      stream_response = create_stream_response(stream: chunks)
      parent = self()

      {:ok, response} =
        StreamResponse.process_stream(stream_response,
          on_result: fn text -> send(parent, {:content, text}) end
        )

      # Content callback fires immediately
      assert_received {:content, "I'll help with that."}

      # Verify response contains reconstructed tool calls
      assert Response.text(response) == "I'll help with that."
      assert length(Response.tool_calls(response)) == 2

      weather_tool =
        Enum.find(Response.tool_calls(response), fn
          %ReqLLM.ToolCall{function: %{name: "get_weather"}} -> true
          _ -> false
        end)

      assert %ReqLLM.ToolCall{id: "call-123", function: %{arguments: weather_args}} = weather_tool
      assert Jason.decode!(weather_args) == %{"city" => "NYC"}

      calc_tool =
        Enum.find(Response.tool_calls(response), fn
          %ReqLLM.ToolCall{function: %{name: "calculator"}} -> true
          _ -> false
        end)

      assert %ReqLLM.ToolCall{id: "call-456", function: %{arguments: calc_args}} = calc_tool
      assert Jason.decode!(calc_args) == %{"operation" => "add", "operands" => [2, 2]}
    end

    test "handles mixed content, thinking, and tool calls" do
      chunks = [
        StreamChunk.text("Let me help. "),
        StreamChunk.thinking("I need to fetch the weather"),
        StreamChunk.tool_call("get_weather", %{city: "SF"}, %{id: "call-1", index: 0}),
        StreamChunk.text(" The result is ready!")
      ]

      stream_response = create_stream_response(stream: chunks)
      parent = self()

      {:ok, response} =
        StreamResponse.process_stream(stream_response,
          on_result: fn text -> send(parent, {:content, text}) end,
          on_thinking: fn text -> send(parent, {:thinking, text}) end
        )

      # Callbacks fire for content and thinking
      assert_received {:content, "Let me help. "}
      assert_received {:thinking, "I need to fetch the weather"}
      assert_received {:content, " The result is ready!"}

      # Verify response has everything including tool calls
      assert Response.text(response) == "Let me help.  The result is ready!"
      assert length(Response.tool_calls(response)) == 1

      assert %ReqLLM.ToolCall{function: %{name: "get_weather", arguments: args_json}} =
               hd(Response.tool_calls(response))

      assert Jason.decode!(args_json) == %{"city" => "SF"}
    end

    test "handles empty stream gracefully" do
      stream_response = create_stream_response(stream: [])
      parent = self()

      # Should complete without errors and no callbacks
      {:ok, response} =
        StreamResponse.process_stream(stream_response,
          on_result: fn text -> send(parent, {:content, text}) end,
          on_thinking: fn text -> send(parent, {:thinking, text}) end
        )

      refute_received _
      assert Response.text(response) == ""
      assert response.message.tool_calls == nil
    end

    test "works with no callbacks provided" do
      chunks = text_chunks(["Hello", " world"])
      stream_response = create_stream_response(stream: chunks)

      # Should complete without errors even with no callbacks
      {:ok, response} = StreamResponse.process_stream(stream_response)

      assert Response.text(response) == "Hello world"
    end

    test "works with only some callbacks provided" do
      chunks = [
        StreamChunk.text("Hello"),
        StreamChunk.thinking("Processing..."),
        StreamChunk.tool_call("test", %{}, %{id: "call-1", index: 0})
      ]

      stream_response = create_stream_response(stream: chunks)
      parent = self()

      # Only provide on_result callback
      {:ok, response} =
        StreamResponse.process_stream(stream_response,
          on_result: fn text -> send(parent, {:content, text}) end
        )

      # Only content callback should fire
      assert_received {:content, "Hello"}
      refute_received {:thinking, _}

      # But response should still have everything
      assert Response.text(response) == "Hello"
      assert length(Response.tool_calls(response)) == 1
    end

    test "handles tool calls with no argument fragments" do
      chunks = [
        StreamChunk.tool_call("simple_tool", %{arg: "value"}, %{id: "call-1", index: 0})
      ]

      stream_response = create_stream_response(stream: chunks)

      {:ok, response} = StreamResponse.process_stream(stream_response)

      # Response should have the tool call with original arguments
      assert length(Response.tool_calls(response)) == 1

      assert %ReqLLM.ToolCall{
               id: "call-1",
               function: %{name: "simple_tool", arguments: args_json}
             } = hd(Response.tool_calls(response))

      assert Jason.decode!(args_json) == %{"arg" => "value"}
    end

    test "handles invalid JSON in argument fragments gracefully" do
      chunks = [
        StreamChunk.tool_call("broken_tool", %{}, %{id: "call-1", index: 0}),
        StreamChunk.meta(%{tool_call_args: %{index: 0, fragment: "{invalid json}"}}),
        StreamChunk.meta(%{tool_call_args: %{index: 0, fragment: " more invalid}"}})
      ]

      stream_response = create_stream_response(stream: chunks)

      {:ok, response} = StreamResponse.process_stream(stream_response)

      # Should fall back to empty arguments on invalid JSON
      assert length(Response.tool_calls(response)) == 1
      tool_call = hd(Response.tool_calls(response))

      assert %ReqLLM.ToolCall{
               id: "call-1",
               function: %{name: "broken_tool", arguments: args_json}
             } =
               tool_call

      assert Jason.decode!(args_json) == %{}
    end

    test "handles multiple tool calls with different fragments" do
      chunks = [
        StreamChunk.tool_call("tool1", %{}, %{id: "call-1", index: 0}),
        StreamChunk.tool_call("tool2", %{}, %{id: "call-2", index: 1}),
        StreamChunk.meta(%{tool_call_args: %{index: 0, fragment: "{\"key\":"}}),
        StreamChunk.meta(%{tool_call_args: %{index: 0, fragment: "\"value1\"}"}}),
        StreamChunk.meta(%{tool_call_args: %{index: 1, fragment: "{\"key\":"}}),
        StreamChunk.meta(%{tool_call_args: %{index: 1, fragment: "\"value2\"}"}})
      ]

      stream_response = create_stream_response(stream: chunks)

      {:ok, response} = StreamResponse.process_stream(stream_response)

      # Response should have both tool calls with correct arguments
      assert length(Response.tool_calls(response)) == 2

      tool1 =
        Enum.find(Response.tool_calls(response), fn
          %ReqLLM.ToolCall{function: %{name: "tool1"}} -> true
          _ -> false
        end)

      assert %ReqLLM.ToolCall{id: "call-1", function: %{arguments: args1}} = tool1
      assert Jason.decode!(args1) == %{"key" => "value1"}

      tool2 =
        Enum.find(Response.tool_calls(response), fn
          %ReqLLM.ToolCall{function: %{name: "tool2"}} -> true
          _ -> false
        end)

      assert %ReqLLM.ToolCall{id: "call-2", function: %{arguments: args2}} = tool2
      assert Jason.decode!(args2) == %{"key" => "value2"}
    end

    test "processes stream only once (no double consumption)" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      chunks =
        Stream.map(text_chunks(["a", "b", "c"]), fn chunk ->
          Agent.update(counter, &(&1 + 1))
          chunk
        end)

      stream_response = create_stream_response(stream: chunks)
      parent = self()

      {:ok, response} =
        StreamResponse.process_stream(stream_response,
          on_result: fn text -> send(parent, {:content, text}) end
        )

      # Stream should be consumed exactly once (3 chunks)
      assert Agent.get(counter, & &1) == 3
      assert_received {:content, "a"}
      assert_received {:content, "b"}
      assert_received {:content, "c"}

      # Response should have accumulated text
      assert Response.text(response) == "abc"
    end

    test "returns {:ok, response} after completing all processing" do
      chunks = [
        StreamChunk.text("Hello"),
        StreamChunk.thinking("thinking"),
        StreamChunk.tool_call("test", %{}, %{id: "call-1", index: 0})
      ]

      stream_response = create_stream_response(stream: chunks)

      {:ok, response} =
        StreamResponse.process_stream(stream_response,
          on_result: fn _ -> :ok end,
          on_thinking: fn _ -> :ok end
        )

      assert %Response{} = response
      assert Response.text(response) == "Hello"
      assert length(Response.tool_calls(response)) == 1
    end

    test "handles nil text in chunks gracefully" do
      # Create chunks with nil text (though this shouldn't happen in practice)
      chunks = [
        %StreamChunk{type: :content, text: nil, metadata: %{}},
        StreamChunk.text("actual text")
      ]

      stream_response = create_stream_response(stream: chunks)
      parent = self()

      {:ok, response} =
        StreamResponse.process_stream(stream_response,
          on_result: fn text -> send(parent, {:content, text}) end
        )

      # Should only receive callback for non-nil text
      assert_received {:content, "actual text"}
      refute_received {:content, nil}

      # Response should have the actual text
      assert Response.text(response) == "actual text"
    end

    test "response context includes assistant message" do
      user_context = Context.new([Context.user("Hello, how are you?")])

      stream_response =
        create_stream_response(
          stream: text_chunks(["Doing well!"]),
          context: user_context
        )

      {:ok, response} = StreamResponse.process_stream(stream_response)

      assert response.context == Context.append(user_context, response.message)
    end

    test "preserves tool call order" do
      chunks = [
        StreamChunk.tool_call("first", %{}, %{id: "call-1", index: 0}),
        StreamChunk.tool_call("second", %{}, %{id: "call-2", index: 1}),
        StreamChunk.tool_call("third", %{}, %{id: "call-3", index: 2})
      ]

      stream_response = create_stream_response(stream: chunks)

      {:ok, response} = StreamResponse.process_stream(stream_response)

      # Response should preserve tool call order
      tool_names =
        Enum.map(Response.tool_calls(response), fn %ReqLLM.ToolCall{function: %{name: name}} ->
          name
        end)

      assert tool_names == ["first", "second", "third"]
    end

    test "response contains metadata from metadata_handle" do
      chunks = text_chunks(["test"])
      usage = %{input_tokens: 10, output_tokens: 20, total_cost: 0.03}
      metadata_handle = create_metadata_handle(%{usage: usage, finish_reason: :stop})

      stream_response = create_stream_response(stream: chunks, metadata_handle: metadata_handle)

      {:ok, response} = StreamResponse.process_stream(stream_response)

      assert response.usage.input_tokens == 10
      assert response.usage.output_tokens == 20
      assert response.finish_reason == :stop
    end
  end

  describe "integration and edge cases" do
    test "handles concurrent stream consumption and metadata collection" do
      chunks = text_chunks(Enum.map(1..100, &"chunk #{&1} "))

      # Simulate slow metadata collection
      metadata_handle =
        create_metadata_handle(fn ->
          Process.sleep(10)
          %{usage: %{tokens: 100}, finish_reason: :stop}
        end)

      stream_response =
        create_stream_response(
          stream: chunks,
          metadata_handle: metadata_handle
        )

      # Test text collection and usage from same process
      text = StreamResponse.text(stream_response)

      # Create fresh stream_response for usage test
      metadata_handle2 = create_metadata_handle(%{usage: %{tokens: 100}, finish_reason: :stop})
      stream_response2 = create_stream_response(metadata_handle: metadata_handle2)
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

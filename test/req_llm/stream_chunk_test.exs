defmodule ReqLLM.StreamChunkTest do
  use ExUnit.Case, async: true

  alias ReqLLM.StreamChunk

  # Shared test helpers
  defp assert_chunk_fields(chunk, expected_fields) do
    Enum.each(expected_fields, fn {field, value} ->
      assert Map.get(chunk, field) == value
    end)
  end

  defp assert_nil_fields(chunk, fields) do
    Enum.each(fields, fn field ->
      assert is_nil(Map.get(chunk, field))
    end)
  end

  describe "constructor functions" do
    test "text/2 creates content chunks" do
      basic_chunk = StreamChunk.text("Hello")
      with_meta = StreamChunk.text("Hello", %{token_count: 5})

      assert_chunk_fields(basic_chunk, type: :content, text: "Hello", metadata: %{})
      assert_nil_fields(basic_chunk, [:name, :arguments])

      assert_chunk_fields(with_meta, type: :content, text: "Hello", metadata: %{token_count: 5})
    end

    test "thinking/2 creates thinking chunks" do
      basic_chunk = StreamChunk.thinking("Consider this...")
      with_meta = StreamChunk.thinking("Step 1...", %{step: 1})

      assert_chunk_fields(basic_chunk, type: :thinking, text: "Consider this...", metadata: %{})
      assert_nil_fields(basic_chunk, [:name, :arguments])

      assert_chunk_fields(with_meta, type: :thinking, text: "Step 1...", metadata: %{step: 1})
    end

    test "tool_call/3 creates tool call chunks" do
      args = %{city: "NYC", unit: "celsius"}
      basic_chunk = StreamChunk.tool_call("get_weather", args)
      with_meta = StreamChunk.tool_call("search", %{q: "test"}, %{call_id: "123"})

      assert_chunk_fields(basic_chunk,
        type: :tool_call,
        name: "get_weather",
        arguments: args,
        metadata: %{}
      )

      assert is_nil(basic_chunk.text)

      assert_chunk_fields(with_meta,
        type: :tool_call,
        name: "search",
        arguments: %{q: "test"},
        metadata: %{call_id: "123"}
      )
    end

    test "meta/2 creates metadata chunks" do
      data = %{finish_reason: "stop", id: "claude-3"}
      basic_chunk = StreamChunk.meta(data)
      merged_chunk = StreamChunk.meta(%{status: "ok"}, %{tokens: 42})

      assert_chunk_fields(basic_chunk, type: :meta, metadata: data)
      assert_nil_fields(basic_chunk, [:text, :name, :arguments])

      assert_chunk_fields(merged_chunk, type: :meta, metadata: %{status: "ok", tokens: 42})
    end
  end

  describe "validation" do
    @valid_cases [
      {:content, StreamChunk.text("valid")},
      {:thinking, StreamChunk.thinking("valid reasoning")},
      {:tool_call, StreamChunk.tool_call("func", %{arg: "value"})},
      {:meta, StreamChunk.meta(%{key: "value"})},
      {:empty_text, StreamChunk.text("")},
      {:empty_thinking, StreamChunk.thinking("")},
      {:empty_args, StreamChunk.tool_call("", %{})},
      {:empty_meta, StreamChunk.meta(%{})}
    ]

    @invalid_cases [
      {:content_nil_text, %StreamChunk{type: :content, text: nil},
       "Content chunks must have non-nil text"},
      {:thinking_nil_text, %StreamChunk{type: :thinking, text: nil},
       "Thinking chunks must have non-nil text"},
      {:tool_call_nil_name, %StreamChunk{type: :tool_call, name: nil, arguments: %{}},
       "Tool call chunks must have non-nil name and arguments"},
      {:tool_call_nil_args, %StreamChunk{type: :tool_call, name: "func", arguments: nil},
       "Tool call chunks must have non-nil name and arguments"},
      {:meta_nil_metadata, %StreamChunk{type: :meta, metadata: nil},
       "Meta chunks must have metadata map"},
      {:unknown_type, %StreamChunk{type: :unknown}, "Unknown chunk type: :unknown"}
    ]

    test "validates valid chunks" do
      for {_name, chunk} <- @valid_cases do
        assert {:ok, ^chunk} = StreamChunk.validate(chunk)
      end
    end

    test "rejects invalid chunks" do
      for {_name, chunk, expected_error} <- @invalid_cases do
        assert {:error, ^expected_error} = StreamChunk.validate(chunk)
      end
    end

    test "validate!/1 bang version" do
      valid_chunk = StreamChunk.text("Hello")
      assert ^valid_chunk = StreamChunk.validate!(valid_chunk)

      invalid_chunk = %StreamChunk{type: :content, text: nil}

      assert_raise ArgumentError, "Content chunks must have non-nil text", fn ->
        StreamChunk.validate!(invalid_chunk)
      end
    end
  end

  describe "content handling" do
    test "handles various text content types" do
      test_cases = [
        {"empty", ""},
        {"unicode", "🚀 émojis and ñ chars"},
        {"whitespace", "   \n\t  "},
        {"multiline", "Line 1\nLine 2\nLine 3"},
        {"long", String.duplicate("a", 1000)}
      ]

      for {_description, content} <- test_cases do
        content_chunk = StreamChunk.text(content)
        thinking_chunk = StreamChunk.thinking(content)

        assert content_chunk.text == content
        assert thinking_chunk.text == content
        assert {:ok, _} = StreamChunk.validate(content_chunk)
        assert {:ok, _} = StreamChunk.validate(thinking_chunk)
      end
    end

    test "handles complex data structures" do
      complex_args = %{
        nested: %{deep: %{value: "test"}},
        list: [1, 2, %{inner: true}],
        mixed_types: %{
          string: "test",
          integer: 42,
          float: 3.14,
          boolean: true,
          atom: :key,
          nil_value: nil
        }
      }

      chunk = StreamChunk.tool_call("complex_tool", complex_args)
      assert chunk.arguments == complex_args
      assert {:ok, _} = StreamChunk.validate(chunk)

      # Test metadata merging preserves complex structures
      complex_meta = %{usage: %{input: 10, output: 25}, metrics: [1, 2, 3]}
      meta_chunk = StreamChunk.meta(complex_meta, %{extra: true})
      assert meta_chunk.metadata.usage == %{input: 10, output: 25}
      assert meta_chunk.metadata.extra == true
    end
  end

  describe "struct behavior" do
    test "enforces required type field" do
      assert_raise ArgumentError, fn ->
        struct!(StreamChunk, %{text: "missing type"})
      end
    end

    test "provides default metadata and pattern matching" do
      chunk = struct!(StreamChunk, %{type: :content, text: "test"})
      assert chunk.metadata == %{}

      # Test pattern matching works
      assert %StreamChunk{type: :content, text: "test", metadata: %{}} = chunk
    end
  end

  describe "constructor guard clauses" do
    test "enforces parameter type guards" do
      # text/2 guards
      assert_raise FunctionClauseError, fn -> StreamChunk.text(123) end
      assert_raise FunctionClauseError, fn -> StreamChunk.text("hello", "not a map") end

      # thinking/2 guards
      assert_raise FunctionClauseError, fn -> StreamChunk.thinking(:not_binary) end
      assert_raise FunctionClauseError, fn -> StreamChunk.thinking("thinking", :not_map) end

      # tool_call/3 guards
      assert_raise FunctionClauseError, fn -> StreamChunk.tool_call(:not_binary, %{}) end
      assert_raise FunctionClauseError, fn -> StreamChunk.tool_call("name", :not_map) end
      assert_raise FunctionClauseError, fn -> StreamChunk.tool_call("name", %{}, :not_map) end

      # meta/2 guards
      assert_raise FunctionClauseError, fn -> StreamChunk.meta(:not_map) end
      assert_raise FunctionClauseError, fn -> StreamChunk.meta(%{}, :not_map) end
    end
  end

  describe "inspect protocol" do
    test "formats chunks with appropriate previews" do
      # Content and thinking chunks show text preview
      content_chunk = StreamChunk.text("Hello world")
      thinking_chunk = StreamChunk.thinking("Let me consider this carefully")

      content_inspect = inspect(content_chunk)
      thinking_inspect = inspect(thinking_chunk)

      assert content_inspect =~ "#StreamChunk<:content \"Hello world\">"
      assert thinking_inspect =~ "#StreamChunk<:thinking thinking: \"Let me consider this...\">"

      # Tool call chunks show function signature
      tool_chunk = StreamChunk.tool_call("get_weather", %{city: "NYC"})
      empty_args_chunk = StreamChunk.tool_call("no_args", %{})

      tool_inspect = inspect(tool_chunk)
      empty_inspect = inspect(empty_args_chunk)

      assert tool_inspect =~ "#StreamChunk<:tool_call get_weather(...)>"
      assert empty_inspect =~ "#StreamChunk<:tool_call no_args()>"

      # Meta chunks show keys
      meta_chunk = StreamChunk.meta(%{finish_reason: "stop", tokens: 42})
      single_key_chunk = StreamChunk.meta(%{status: "complete"})

      meta_inspect = inspect(meta_chunk)
      single_inspect = inspect(single_key_chunk)

      assert meta_inspect =~ "#StreamChunk<:meta meta:"
      assert meta_inspect =~ "finish_reason" or meta_inspect =~ "tokens"
      assert single_inspect =~ "#StreamChunk<:meta meta: status>"
    end

    test "handles text truncation at 20 characters" do
      long_text = "This text is definitely longer than twenty characters"
      exactly_20 = "12345678901234567890"
      short_text = "Short"

      long_chunk = StreamChunk.text(long_text)
      exact_chunk = StreamChunk.text(exactly_20)
      short_chunk = StreamChunk.text(short_text)

      long_inspect = inspect(long_chunk)
      exact_inspect = inspect(exact_chunk)
      short_inspect = inspect(short_chunk)

      # Long text gets truncated with ellipsis
      assert long_inspect =~ "\"This text is definit...\""
      refute long_inspect =~ long_text

      # Exactly 20 chars shows fully without ellipsis
      assert exact_inspect =~ "\"12345678901234567890\""
      refute exact_inspect =~ "..."

      # Short text shows fully
      assert short_inspect =~ "\"Short\""
      refute short_inspect =~ "..."
    end

    test "handles special cases in inspect" do
      # Test nil text handling
      invalid_chunk = %StreamChunk{type: :content, text: nil}
      assert inspect(invalid_chunk) =~ "nil"

      # Test empty string
      empty_chunk = StreamChunk.text("")
      assert inspect(empty_chunk) =~ "\"\""

      # Test unicode truncation
      unicode_text = "Hello 🚀🌍🎉🔥💎✨⭐️🌟🎨🎯🎪🎭🎮🎲🎸 more text here"
      unicode_chunk = StreamChunk.text(unicode_text)
      unicode_inspect = inspect(unicode_chunk)
      assert unicode_inspect =~ "..."
      refute unicode_inspect =~ unicode_text

      # Test multiple metadata keys formatting
      many_keys = %{a: 1, b: 2, c: 3, d: 4, e: 5}
      multi_chunk = StreamChunk.meta(many_keys)
      multi_inspect = inspect(multi_chunk)
      comma_count = multi_inspect |> String.graphemes() |> Enum.count(&(&1 == ","))
      # 5 keys = 4 commas
      assert comma_count == 4
    end
  end
end

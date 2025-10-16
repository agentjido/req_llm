defmodule ReqLLM.StreamChunk do
  @moduledoc """
  Represents a single chunk in a streaming response.

  StreamChunk provides a unified format for streaming responses across different providers,
  supporting text content, tool calls, thinking tokens, and metadata. This structure enables
  consistent handling of streaming data regardless of the underlying provider's format.

  ## Chunk Types

  - `:content` - Text content chunks (the main response text)
  - `:thinking` - Reasoning/thinking tokens (e.g., Claude's `<thinking>` tags)
  - `:tool_call` - Function/tool call chunks with name and arguments
  - `:meta` - Metadata chunks (usage, finish reasons, etc.)

  ## Usage Examples

      # Simple text content
      chunk = ReqLLM.StreamChunk.text("Hello world")
      chunk.type   #=> :content
      chunk.text   #=> "Hello world"

      # Thinking/reasoning content
      chunk = ReqLLM.StreamChunk.thinking("Let me think about this...")
      chunk.type   #=> :thinking
      chunk.text   #=> "Let me think about this..."

      # Tool call chunk
      chunk = ReqLLM.StreamChunk.tool_call("get_weather", %{location: "NYC"})
      chunk.type      #=> :tool_call
      chunk.name      #=> "get_weather"
      chunk.arguments #=> %{location: "NYC"}

      # Metadata chunk
      chunk = ReqLLM.StreamChunk.meta(%{finish_reason: "stop", tokens_used: 42})
      chunk.type     #=> :meta
      chunk.metadata #=> %{finish_reason: "stop", tokens_used: 42}

  ## Streaming Pattern

  StreamChunk is designed to work with Elixir's Stream module:

      {:ok, stream} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Tell a story")

      stream
      |> Stream.filter(&(&1.type == :content))
      |> Stream.map(&(&1.text))
      |> Stream.each(&IO.write/1)
      |> Stream.run()

  ## Provider Integration

  Providers can use the constructor helpers to create consistent chunks:

      # In provider's parse_stream_chunk function
      case event_type do
        "content_block_delta" ->
          ReqLLM.StreamChunk.text(event_data["text"])

        "content_block_start" when event_data["type"] == "tool_use" ->
          ReqLLM.StreamChunk.tool_call(event_data["name"], %{})

        "thinking_block_delta" ->
          ReqLLM.StreamChunk.thinking(event_data["text"])

        "message_stop" ->
          ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})
      end

  """

  use TypedStruct

  @typedoc """
  Chunk type indicating the kind of content in this chunk.
  """
  @type chunk_type :: :content | :thinking | :tool_call | :meta

  typedstruct do
    @typedoc "A single chunk of streaming response data"

    field(:type, chunk_type(), enforce: true, doc: "Type of chunk content")
    field(:text, String.t() | nil, doc: "Text content for :content and :thinking chunks")
    field(:name, String.t() | nil, doc: "Tool/function name for :tool_call chunks")
    field(:arguments, map() | nil, doc: "Tool arguments for :tool_call chunks")
    field(:metadata, map(), default: %{}, doc: "Additional metadata for any chunk type")
  end

  @doc """
  Creates a content chunk containing text.

  ## Parameters

    * `text` - The text content for this chunk
    * `metadata` - Optional additional metadata (default: empty map)

  ## Examples

      chunk = ReqLLM.StreamChunk.text("Hello")
      chunk.type #=> :content
      chunk.text #=> "Hello"

      # With metadata
      chunk = ReqLLM.StreamChunk.text("Hello", %{token_count: 1})
      chunk.metadata #=> %{token_count: 1}

  """
  @spec text(String.t(), map()) :: t()
  def text(content, metadata \\ %{}) when is_binary(content) and is_map(metadata) do
    %__MODULE__{
      type: :content,
      text: content,
      metadata: metadata
    }
  end

  @doc """
  Creates a thinking chunk containing reasoning text.

  Used for providers that support reasoning/thinking tokens (like Claude's `<thinking>` tags).

  ## Parameters

    * `content` - The thinking/reasoning text
    * `metadata` - Optional additional metadata (default: empty map)

  ## Examples

      chunk = ReqLLM.StreamChunk.thinking("Let me consider...")
      chunk.type #=> :thinking
      chunk.text #=> "Let me consider..."

  """
  @spec thinking(String.t(), map()) :: t()
  def thinking(content, metadata \\ %{}) when is_binary(content) and is_map(metadata) do
    %__MODULE__{
      type: :thinking,
      text: content,
      metadata: metadata
    }
  end

  @doc """
  Creates a tool call chunk with function name and arguments.

  ## Parameters

    * `name` - The tool/function name being called
    * `arguments` - The arguments map for the tool call
    * `metadata` - Optional additional metadata (default: empty map)

  ## Examples

      chunk = ReqLLM.StreamChunk.tool_call("get_weather", %{city: "NYC"})
      chunk.type      #=> :tool_call
      chunk.name      #=> "get_weather"
      chunk.arguments #=> %{city: "NYC"}

      # Partial tool call (streaming arguments)
      chunk = ReqLLM.StreamChunk.tool_call("search", %{query: "par"})
      chunk.arguments #=> %{query: "par"}

  """
  @spec tool_call(String.t(), map(), map()) :: t()
  def tool_call(name, arguments, metadata \\ %{})
      when is_binary(name) and is_map(arguments) and is_map(metadata) do
    %__MODULE__{
      type: :tool_call,
      name: name,
      arguments: arguments,
      metadata: metadata
    }
  end

  @doc """
  Creates a metadata chunk containing response metadata.

  Used for finish reasons, usage statistics, and other non-content information.

  ## Warning

  The `metadata` field contains provider-specific keys that may be merged or transformed
  when chunks are processed by `ReqLLM.Response.join_stream/1`. Provider-specific keys
  should not be relied upon for application logic.

  ## Parameters

    * `data` - The metadata map
    * `extra_metadata` - Optional additional metadata to merge (default: empty map)

  ## Examples

      chunk = ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})
      chunk.type     #=> :meta
      chunk.metadata #=> %{finish_reason: "stop"}

      # Usage information
      chunk = ReqLLM.StreamChunk.meta(%{
        usage: %{input_tokens: 10, output_tokens: 25}
      })

      # Multiple metadata fields
      chunk = ReqLLM.StreamChunk.meta(%{
        finish_reason: "tool_use",
        model: "claude-3-sonnet"
      })

  """
  @spec meta(map(), map()) :: t()
  def meta(data, extra_metadata \\ %{}) when is_map(data) and is_map(extra_metadata) do
    %__MODULE__{
      type: :meta,
      metadata: Map.merge(data, extra_metadata)
    }
  end

  @doc """
  Validates a StreamChunk struct according to its type.

  Ensures that required fields are present based on the chunk type:
  - `:content` and `:thinking` chunks must have non-nil text
  - `:tool_call` chunks must have non-nil name and arguments
  - `:meta` chunks must have a non-empty metadata map

  ## Parameters

    * `chunk` - The StreamChunk struct to validate

  ## Returns

    * `{:ok, chunk}` - Valid chunk
    * `{:error, reason}` - Validation error with description

  ## Examples

      chunk = ReqLLM.StreamChunk.text("Hello")
      ReqLLM.StreamChunk.validate(chunk)
      #=> {:ok, %ReqLLM.StreamChunk{...}}

      invalid_chunk = %ReqLLM.StreamChunk{type: :content, text: nil}
      ReqLLM.StreamChunk.validate(invalid_chunk)
      #=> {:error, "Content chunks must have non-nil text"}

  """
  @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{} = chunk) do
    case validate_by_type(chunk) do
      :ok -> {:ok, chunk}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Bang version of validate/1; raises on invalid chunk.

  ## Parameters

    * `chunk` - The StreamChunk struct to validate

  ## Returns

    * Returns the chunk if valid
    * Raises `ArgumentError` if invalid

  ## Examples

      chunk = ReqLLM.StreamChunk.text("Hello")
      ReqLLM.StreamChunk.validate!(chunk)
      #=> %ReqLLM.StreamChunk{...}

      invalid_chunk = %ReqLLM.StreamChunk{type: :content, text: nil}
      ReqLLM.StreamChunk.validate!(invalid_chunk)
      #=> ** (ArgumentError) Content chunks must have non-nil text

  """
  @spec validate!(t()) :: t()
  def validate!(chunk) do
    case validate(chunk) do
      {:ok, chunk} -> chunk
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  # Private validation helpers

  defp validate_by_type(%{type: :content, text: text}) when is_binary(text), do: :ok
  defp validate_by_type(%{type: :content}), do: {:error, "Content chunks must have non-nil text"}

  defp validate_by_type(%{type: :thinking, text: text}) when is_binary(text), do: :ok

  defp validate_by_type(%{type: :thinking}),
    do: {:error, "Thinking chunks must have non-nil text"}

  defp validate_by_type(%{type: :tool_call, name: name, arguments: args})
       when is_binary(name) and is_map(args) do
    :ok
  end

  defp validate_by_type(%{type: :tool_call}),
    do: {:error, "Tool call chunks must have non-nil name and arguments"}

  defp validate_by_type(%{type: :meta, metadata: meta}) when is_map(meta), do: :ok
  defp validate_by_type(%{type: :meta}), do: {:error, "Meta chunks must have metadata map"}

  defp validate_by_type(%{type: unknown_type}),
    do: {:error, "Unknown chunk type: #{inspect(unknown_type)}"}

  defimpl Inspect do
    def inspect(%{type: type} = chunk, opts) do
      content_desc =
        case type do
          :content ->
            inspect_text(chunk.text, 20)

          :thinking ->
            text_preview = inspect_text(chunk.text, 20)
            "thinking: " <> text_preview

          :tool_call ->
            args_preview =
              if map_size(chunk.arguments || %{}) > 0 do
                "(...)"
              else
                "()"
              end

            chunk.name <> args_preview

          :meta ->
            meta_keys = chunk.metadata |> Map.keys() |> Enum.join(",")
            "meta: " <> meta_keys
        end

      Inspect.Algebra.concat([
        "#StreamChunk<",
        Inspect.Algebra.to_doc(type, opts),
        " ",
        content_desc,
        ">"
      ])
    end

    defp inspect_text(nil, _), do: "nil"

    defp inspect_text(text, max_length) when is_binary(text) do
      if String.length(text) > max_length do
        truncated = String.slice(text, 0, max_length)
        "\"" <> truncated <> "...\""
      else
        "\"" <> text <> "\""
      end
    end
  end
end

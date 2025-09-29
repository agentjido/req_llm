defmodule ReqLLM.StreamResponse do
  @moduledoc """
  A streaming response container that provides both real-time streaming and asynchronous metadata.

  `StreamResponse` is the new return type for streaming operations in ReqLLM, designed to provide
  efficient access to streaming data while maintaining backward compatibility with the legacy
  Response format.

  ## Structure

  - `stream` - Lazy enumerable of `ReqLLM.StreamChunk` structs for real-time consumption
  - `metadata_task` - Concurrent Task for metadata collection (usage, finish_reason)
  - `cancel` - Function to terminate streaming and cleanup resources
  - `model` - Model specification that generated this response
  - `context` - Conversation context for multi-turn workflows

  ## Usage Patterns

  ### Real-time streaming
  ```elixir
  {:ok, stream_response} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Tell a story")

  stream_response
  |> ReqLLM.StreamResponse.tokens()
  |> Stream.each(&IO.write/1)
  |> Stream.run()
  ```

  ### Collecting complete text
  ```elixir
  {:ok, stream_response} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Hello!")

  text = ReqLLM.StreamResponse.text(stream_response)
  usage = ReqLLM.StreamResponse.usage(stream_response)
  ```

  ### Backward compatibility
  ```elixir
  {:ok, stream_response} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Hello!")
  {:ok, legacy_response} = ReqLLM.StreamResponse.to_response(stream_response)

  # Now works with existing Response-based code
  text = ReqLLM.Response.text(legacy_response)
  ```

  ### Early cancellation
  ```elixir
  {:ok, stream_response} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Long story...")

  stream_response.stream
  |> Stream.take(5)  # Take only first 5 chunks
  |> Stream.each(&IO.write/1)
  |> Stream.run()

  # Cancel remaining work
  stream_response.cancel.()
  ```

  ## Design Philosophy

  This struct separates concerns between streaming data (available immediately) and
  metadata (available after completion). This allows for:

  - Zero-latency streaming of content
  - Concurrent metadata processing
  - Resource cleanup via cancellation
  - Seamless backward compatibility
  """

  use TypedStruct

  alias ReqLLM.{Context, Model, Response}

  typedstruct enforce: true do
    @typedoc """
    A streaming response with concurrent metadata processing.

    Contains a stream of chunks, a task for metadata collection, cancellation function,
    and contextual information for multi-turn conversations.
    """

    field(:stream, Enumerable.t(), doc: "Lazy stream of StreamChunk structs")
    field(:metadata_task, Task.t(), doc: "Async task collecting usage and finish_reason")
    field(:cancel, (-> :ok), doc: "Function to cancel streaming and cleanup resources")
    field(:model, Model.t(), doc: "Model specification that generated this response")
    field(:context, Context.t(), doc: "Conversation context including new messages")
  end

  @doc """
  Extract text tokens from the stream, filtering out metadata chunks.

  Returns a stream that yields only the text content from `:content` type chunks,
  suitable for real-time display or processing.

  ## Parameters

    * `stream_response` - The StreamResponse struct

  ## Returns

  A lazy stream of text strings from content chunks.

  ## Examples

      {:ok, stream_response} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Hello!")
      
      stream_response
      |> ReqLLM.StreamResponse.tokens()
      |> Stream.each(&IO.write/1)
      |> Stream.run()

  """
  @spec tokens(t()) :: Enumerable.t()
  def tokens(%__MODULE__{stream: stream}) do
    stream
    |> Stream.filter(&(&1.type == :content))
    |> Stream.map(& &1.text)
  end

  @doc """
  Collect all text tokens into a single binary string.

  Consumes the entire stream to build the complete text response. This is a
  convenience function for cases where you want the full text but still benefit
  from streaming's concurrent metadata collection.

  ## Parameters

    * `stream_response` - The StreamResponse struct

  ## Returns

  The complete text content as a binary string.

  ## Examples

      {:ok, stream_response} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Hello!")
      
      text = ReqLLM.StreamResponse.text(stream_response)
      #=> "Hello! How can I help you today?"

  ## Performance

  This function will consume the entire stream. If you need both streaming display
  and final text, consider using `Stream.tee/2` to split the stream.
  """
  @spec text(t()) :: String.t()
  def text(%__MODULE__{} = stream_response) do
    stream_response
    |> tokens()
    |> Enum.join("")
  end

  @doc """
  Extract tool call chunks from the stream.

  Returns a stream that yields only `:tool_call` type chunks, suitable for
  processing function calls made by the assistant.

  ## Parameters

    * `stream_response` - The StreamResponse struct

  ## Returns

  A lazy stream of tool call chunks.

  ## Examples

      {:ok, stream_response} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Call get_time tool")
      
      stream_response
      |> ReqLLM.StreamResponse.tool_calls()
      |> Stream.each(fn tool_call -> IO.inspect(tool_call.name) end)
      |> Stream.run()

  """
  @spec tool_calls(t()) :: Enumerable.t()
  def tool_calls(%__MODULE__{stream: stream}) do
    stream
    |> Stream.filter(&(&1.type == :tool_call))
  end

  @doc """
  Collect all tool calls from the stream into a list.

  Consumes the stream chunks and extracts all tool call information into
  a structured format suitable for execution.

  ## Parameters

    * `stream_response` - The StreamResponse struct

  ## Returns

  A list of maps with tool call details including `:id`, `:name`, and `:arguments`.

  ## Examples

      {:ok, stream_response} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Call calculator")
      
      tool_calls = ReqLLM.StreamResponse.extract_tool_calls(stream_response)
      #=> [%{id: "call_123", name: "calculator", arguments: %{"operation" => "add", "a" => 2, "b" => 3}}]

  """
  @spec extract_tool_calls(t()) :: [map()]
  def extract_tool_calls(%__MODULE__{stream: stream}) do
    chunks = Enum.to_list(stream)

    # Extract base tool calls
    tool_calls =
      chunks
      |> Enum.filter(&(&1.type == :tool_call))
      |> Enum.map(fn chunk ->
        %{
          id: Map.get(chunk.metadata, :id) || "call_#{:erlang.unique_integer()}",
          name: chunk.name,
          arguments: chunk.arguments || %{},
          index: Map.get(chunk.metadata, :index, 0)
        }
      end)

    # Collect argument fragments from meta chunks
    arg_fragments =
      chunks
      |> Enum.filter(&(&1.type == :meta))
      |> Enum.filter(fn chunk ->
        Map.has_key?(chunk.metadata, :tool_call_args)
      end)
      |> Enum.group_by(fn chunk ->
        chunk.metadata.tool_call_args.index
      end)
      |> Map.new(fn {index, fragments} ->
        accumulated_json =
          fragments
          |> Enum.map_join("", & &1.metadata.tool_call_args.fragment)

        {index, accumulated_json}
      end)

    # Merge accumulated arguments back into tool calls
    tool_calls
    |> Enum.map(fn tool_call ->
      case Map.get(arg_fragments, tool_call.index) do
        nil ->
          # No accumulated arguments, keep as is
          Map.delete(tool_call, :index)

        json_str ->
          # Parse accumulated JSON arguments
          case Jason.decode(json_str) do
            {:ok, args} ->
              tool_call
              |> Map.put(:arguments, args)
              |> Map.delete(:index)

            {:error, _} ->
              # Invalid JSON, keep empty arguments
              Map.delete(tool_call, :index)
          end
      end
    end)
  end

  @doc """
  Await the metadata task and return usage statistics.

  Blocks until the metadata collection task completes and returns the usage map
  containing token counts and cost information.

  ## Parameters

    * `stream_response` - The StreamResponse struct

  ## Returns

  A usage map with token counts and costs, or nil if no usage data available.

  ## Examples

      {:ok, stream_response} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Hello!")
      
      usage = ReqLLM.StreamResponse.usage(stream_response)
      #=> %{input_tokens: 8, output_tokens: 12, total_cost: 0.024}

  ## Timeout

  This function will block until metadata collection completes. The timeout is
  determined by the provider's streaming implementation.
  """
  @spec usage(t()) :: map() | nil
  def usage(%__MODULE__{metadata_task: task}) do
    case Task.await(task) do
      %{usage: usage} -> usage
      %{} -> nil
      _ -> nil
    end
  end

  @doc """
  Await the metadata task and return the finish reason.

  Blocks until the metadata collection task completes and returns the finish reason
  indicating why the generation stopped.

  ## Parameters

    * `stream_response` - The StreamResponse struct

  ## Returns

  An atom indicating the finish reason (`:stop`, `:length`, `:tool_use`, etc.) or nil.

  ## Examples

      {:ok, stream_response} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Hello!")
      
      reason = ReqLLM.StreamResponse.finish_reason(stream_response)
      #=> :stop

  ## Timeout

  This function will block until metadata collection completes. The timeout is
  determined by the provider's streaming implementation.
  """
  @spec finish_reason(t()) :: atom() | nil
  def finish_reason(%__MODULE__{metadata_task: task}) do
    case Task.await(task) do
      %{finish_reason: finish_reason} when is_atom(finish_reason) ->
        finish_reason

      %{finish_reason: finish_reason} when is_binary(finish_reason) ->
        String.to_atom(finish_reason)

      %{} ->
        nil

      _ ->
        nil
    end
  end

  @doc """
  Convert a StreamResponse to a legacy Response struct for backward compatibility.

  Consumes the entire stream to build a complete Response struct that's compatible
  with existing ReqLLM.Response-based code. This function handles both stream
  consumption and metadata collection concurrently.

  ## Parameters

    * `stream_response` - The StreamResponse struct to convert

  ## Returns

    * `{:ok, response}` - Successfully converted Response struct
    * `{:error, reason}` - Stream consumption or metadata collection failed

  ## Examples

      {:ok, stream_response} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Hello!")
      {:ok, response} = ReqLLM.StreamResponse.to_response(stream_response)
      
      # Now compatible with existing Response-based code
      text = ReqLLM.Response.text(response)
      usage = ReqLLM.Response.usage(response)

  ## Implementation Note

  This function materializes the entire stream and awaits metadata collection,
  so it negates the streaming benefits. Use this only when backward compatibility
  is required.
  """
  @spec to_response(t()) :: {:ok, Response.t()} | {:error, term()}
  def to_response(%__MODULE__{} = stream_response) do
    # Consume stream and build message concurrently with metadata collection
    stream_chunks = Enum.to_list(stream_response.stream)
    metadata = Task.await(stream_response.metadata_task)

    # Build message from stream chunks
    message = build_message_from_chunks(stream_chunks)

    # Create Response struct
    response = %Response{
      id: generate_response_id(),
      model: stream_response.model.model,
      context: stream_response.context,
      message: message,
      object: nil,
      stream?: false,
      stream: nil,
      usage: Map.get(metadata, :usage),
      finish_reason: Map.get(metadata, :finish_reason),
      provider_meta: Map.get(metadata, :provider_meta, %{}),
      error: nil
    }

    {:ok, response}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  # Private helper to build a Message from StreamChunk list
  defp build_message_from_chunks(chunks) do
    # Collect all text content
    text_content =
      chunks
      |> Enum.filter(&(&1.type == :content))
      |> Enum.map_join("", & &1.text)

    # Build tool calls from tool_call chunks
    tool_calls =
      chunks
      |> Enum.filter(&(&1.type == :tool_call))
      |> Enum.map(fn chunk ->
        %{
          name: chunk.name,
          arguments: chunk.arguments,
          id: Map.get(chunk.metadata, :tool_call_id)
        }
      end)

    # Create content parts
    content_parts =
      if text_content == "" do
        []
      else
        [%{type: :text, text: text_content}]
      end

    %ReqLLM.Message{
      role: :assistant,
      content: content_parts,
      tool_calls: if(tool_calls != [], do: tool_calls),
      metadata: %{}
    }
  end

  # Generate a unique response ID
  defp generate_response_id do
    "stream_response_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end

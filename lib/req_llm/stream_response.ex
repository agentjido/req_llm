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
  and final text, consider splitting the stream with an intermediate collection step.
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
      |> Enum.filter(fn
        %{type: :meta, metadata: %{tool_call_args: _}} -> true
        _ -> false
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
  Process a stream with real-time callbacks for content and thinking.

  Unlike `to_response/1`, this function processes the stream incrementally and invokes
  callbacks as chunks arrive, enabling real-time streaming to UIs or other consumers.
  After processing completes, returns a complete Response struct with all accumulated
  data and metadata, including reconstructed tool calls.

  ## Parameters

    * `stream_response` - The StreamResponse struct to process
    * `opts` - Keyword list of options:
      * `:on_result` - Callback invoked immediately for each `:content` chunk.
                       Signature: `(String.t() -> any())`
      * `:on_thinking` - Callback invoked immediately for each `:thinking` chunk.
                        Signature: `(String.t() -> any())`

  ## Returns

  `{:ok, Response.t()}` with complete response data including:
    - All accumulated text content in `message.content`
    - All accumulated thinking content in `message.content`
    - All reconstructed tool calls in `message.tool_calls`
    - Usage metadata in `usage`
    - Finish reason in `finish_reason`

  Returns `{:error, reason}` if stream processing or metadata collection fails.

  ## Examples

      # Stream text to console and get final response
      {:ok, stream_response} = ReqLLM.stream_text("anthropic:claude-3-sonnet", "Tell a story")

      {:ok, response} = ReqLLM.StreamResponse.process_stream(stream_response,
        on_result: &IO.write/1,
        on_thinking: fn thinking -> IO.puts("[Thinking: \#{thinking}]") end
      )

      # Response contains all accumulated data
      IO.inspect(response.message)  # Complete message with text and thinking
      IO.inspect(response.usage)    # Token usage metadata

      # Stream to Phoenix LiveView
      {:ok, response} = ReqLLM.StreamResponse.process_stream(stream_response,
        on_result: fn text ->
          Phoenix.PubSub.broadcast!(MyApp.PubSub, "chat:\#{id}", {:chunk, text})
        end
      )

      # Tool calls are available in the response
      tool_calls = response.message.tool_calls || []
      Enum.each(tool_calls, &execute_tool/1)

  ## Implementation Notes

  - Content and thinking callbacks fire immediately as chunks arrive (real-time streaming)
  - Tool calls are reconstructed from stream chunks and available in the returned Response
  - The stream is consumed exactly once (no double-consumption bugs)
  - All callbacks are optional - omitted callbacks are simply not invoked
  - The returned Response struct contains all accumulated data plus metadata
  """
  @spec process_stream(t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def process_stream(%__MODULE__{} = stream_response, opts \\ []) do
    callbacks = extract_callbacks(opts)

    # Process stream and accumulate data
    acc_data = process_stream_chunks(stream_response.stream, callbacks)

    # Reconstruct tool calls from accumulated data
    reconstructed_tool_calls = reconstruct_tool_calls(acc_data)

    # Build final response
    response =
      build_response_from_accumulated_data(
        acc_data,
        reconstructed_tool_calls,
        stream_response
      )

    {:ok, response}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  # Extract callbacks from options
  defp extract_callbacks(opts) do
    %{
      on_result: Keyword.get(opts, :on_result),
      on_thinking: Keyword.get(opts, :on_thinking)
    }
  end

  # Process stream chunks and accumulate data
  defp process_stream_chunks(stream, callbacks) do
    Enum.reduce(
      stream,
      %{text_content: [], thinking_content: [], tool_calls: [], arg_fragments: %{}},
      fn chunk, acc -> process_chunk(chunk, acc, callbacks) end
    )
  end

  # Process a single chunk
  defp process_chunk(chunk, acc, callbacks) do
    case chunk.type do
      :content -> process_content_chunk(chunk, acc, callbacks.on_result)
      :thinking -> process_thinking_chunk(chunk, acc, callbacks.on_thinking)
      :tool_call -> process_tool_call_chunk(chunk, acc)
      :meta -> process_meta_chunk(chunk, acc)
    end
  end

  defp process_content_chunk(chunk, acc, on_result) do
    if on_result && chunk.text, do: on_result.(chunk.text)
    %{acc | text_content: [chunk.text | acc.text_content]}
  end

  defp process_thinking_chunk(chunk, acc, on_thinking) do
    if on_thinking && chunk.text, do: on_thinking.(chunk.text)
    %{acc | thinking_content: [chunk.text | acc.thinking_content]}
  end

  defp process_tool_call_chunk(chunk, acc) do
    tool_call = %{
      id: Map.get(chunk.metadata, :id) || "call_#{:erlang.unique_integer()}",
      name: chunk.name,
      arguments: chunk.arguments || %{},
      index: Map.get(chunk.metadata, :index, 0)
    }

    %{acc | tool_calls: [tool_call | acc.tool_calls]}
  end

  defp process_meta_chunk(chunk, acc) do
    if Map.has_key?(chunk.metadata, :tool_call_args) do
      index = chunk.metadata.tool_call_args.index
      fragment = chunk.metadata.tool_call_args.fragment
      existing = Map.get(acc.arg_fragments, index, "")
      %{acc | arg_fragments: Map.put(acc.arg_fragments, index, existing <> fragment)}
    else
      acc
    end
  end

  # Reconstruct tool calls with merged arguments
  defp reconstruct_tool_calls(%{tool_calls: []}), do: []

  defp reconstruct_tool_calls(acc_data) do
    acc_data.tool_calls
    |> Enum.reverse()
    |> Enum.map(&merge_tool_call_arguments(&1, acc_data.arg_fragments))
  end

  defp merge_tool_call_arguments(tool_call, arg_fragments) do
    case Map.get(arg_fragments, tool_call.index) do
      nil -> Map.delete(tool_call, :index)
      json_str -> parse_and_merge_arguments(tool_call, json_str)
    end
  end

  defp parse_and_merge_arguments(tool_call, json_str) do
    case Jason.decode(json_str) do
      {:ok, args} ->
        tool_call
        |> Map.put(:arguments, args)
        |> Map.delete(:index)

      {:error, _} ->
        Map.delete(tool_call, :index)
    end
  end

  # Build final Response from accumulated data
  defp build_response_from_accumulated_data(acc_data, reconstructed_tool_calls, stream_response) do
    text_content = acc_data.text_content |> Enum.reverse() |> Enum.join("")
    thinking_content = acc_data.thinking_content |> Enum.reverse() |> Enum.join("")

    content_parts = build_content_parts(text_content, thinking_content, reconstructed_tool_calls)

    message = %ReqLLM.Message{
      role: :assistant,
      content: content_parts,
      tool_calls: if(reconstructed_tool_calls != [], do: reconstructed_tool_calls),
      metadata: %{}
    }

    object = extract_object_from_message(message)
    metadata = Task.await(stream_response.metadata_task)
    usage = normalize_usage_fields(Map.get(metadata, :usage))

    %Response{
      id: generate_response_id(),
      model: stream_response.model.model,
      context: stream_response.context,
      message: message,
      object: object,
      stream?: false,
      stream: nil,
      usage: usage,
      finish_reason: Map.get(metadata, :finish_reason),
      provider_meta: Map.get(metadata, :provider_meta, %{}),
      error: nil
    }
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
        String.to_existing_atom(finish_reason)

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

    # Check if this is a Responses API model
    if responses_api_model?(stream_response.model) do
      # Reconstruct JSON and decode using Responses API logic
      reconstruct_responses_api_response(stream_chunks, stream_response, metadata)
    else
      # Original logic for Chat API models
      # Build message from stream chunks
      message = build_message_from_chunks(stream_chunks)

      # Extract object from tool calls if present (for structured output)
      object = extract_object_from_message(message)

      # Normalize usage to match non-streaming format
      usage = normalize_usage_fields(Map.get(metadata, :usage))

      # Create Response struct
      response = %Response{
        id: generate_response_id(),
        model: stream_response.model.model,
        context: stream_response.context,
        message: message,
        object: object,
        stream?: false,
        stream: nil,
        usage: usage,
        finish_reason: Map.get(metadata, :finish_reason),
        provider_meta: Map.get(metadata, :provider_meta, %{}),
        error: nil
      }

      {:ok, response}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp responses_api_model?(%ReqLLM.Model{} = model) do
    get_in(model, [Access.key(:_metadata, %{}), "api"]) == "responses"
  end

  defp responses_api_model?(_), do: false

  defp reconstruct_responses_api_response(chunks, stream_response, metadata) do
    # Build canonical OpenAI JSON from chunks
    body =
      ReqLLM.Providers.OpenAI.ResponsesAPI.build_responses_body_from_chunks(
        chunks,
        stream_response.model.model
      )

    # Create fake req/resp to pass through existing decode logic
    req = %{options: %{model: stream_response.model.model, context: stream_response.context}}
    resp = %{status: 200, body: body}

    # Reuse Responses API decode logic - guarantees format parity!
    case ReqLLM.Providers.OpenAI.ResponsesAPI.decode_response({req, resp}) do
      {_req, %{body: %ReqLLM.Response{} = response}} ->
        # Merge in metadata from stream
        response = %{
          response
          | usage: Map.get(metadata, :usage, response.usage),
            finish_reason: Map.get(metadata, :finish_reason, response.finish_reason)
        }

        {:ok, response}

      {_req, error} when is_exception(error) ->
        {:error, error}
    end
  end

  # Private helper to build a Message from StreamChunk list
  defp build_message_from_chunks(chunks) do
    # Collect all text content
    text_content =
      chunks
      |> Enum.filter(&(&1.type == :content))
      |> Enum.map_join("", & &1.text)

    # Collect all thinking/reasoning content
    thinking_content =
      chunks
      |> Enum.filter(&(&1.type == :thinking))
      |> Enum.map_join("", & &1.text)

    # Accumulate JSON fragments from meta chunks
    json_fragments_by_index =
      chunks
      |> Enum.filter(fn
        %{type: :meta, metadata: %{tool_call_args: %{index: _, fragment: _}}} -> true
        _ -> false
      end)
      |> Enum.group_by(fn chunk -> chunk.metadata.tool_call_args.index end)
      |> Map.new(fn {index, meta_chunks} ->
        json =
          meta_chunks
          |> Enum.map_join("", & &1.metadata.tool_call_args.fragment)

        {index, json}
      end)

    # Build tool calls from tool_call chunks, merging accumulated JSON
    tool_calls =
      chunks
      |> Enum.filter(&(&1.type == :tool_call))
      |> Enum.map(fn chunk ->
        index = Map.get(chunk.metadata, :index)
        json_string = Map.get(json_fragments_by_index, index, "")

        arguments =
          if json_string == "" do
            chunk.arguments
          else
            case Jason.decode(json_string) do
              {:ok, decoded} -> decoded
              {:error, _} -> chunk.arguments
            end
          end

        %{
          name: chunk.name,
          arguments: arguments,
          id: Map.get(chunk.metadata, :id) || Map.get(chunk.metadata, :tool_call_id)
        }
      end)

    # Create content parts - if text is valid JSON and no tool calls, create object part
    content_parts = build_content_parts(text_content, thinking_content, tool_calls)

    %ReqLLM.Message{
      role: :assistant,
      content: content_parts,
      tool_calls: if(tool_calls != [], do: tool_calls),
      metadata: %{}
    }
  end

  defp build_content_parts(text_content, thinking_content, tool_calls) do
    parts =
      if tool_calls == [] and text_content != "" and looks_like_json?(text_content) do
        case Jason.decode(text_content) do
          {:ok, parsed_json} when is_map(parsed_json) ->
            [%{type: :object, object: parsed_json}]

          _ ->
            []
            |> maybe_add_text_part(text_content)
            |> maybe_add_thinking_part(thinking_content)
        end
      else
        []
        |> maybe_add_text_part(text_content)
        |> maybe_add_thinking_part(thinking_content)
      end

    parts
  end

  defp looks_like_json?(text) do
    trimmed = String.trim(text)
    String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}")
  end

  defp maybe_add_text_part(parts, ""), do: parts
  defp maybe_add_text_part(parts, text), do: parts ++ [%{type: :text, text: text}]

  defp maybe_add_thinking_part(parts, ""), do: parts
  defp maybe_add_thinking_part(parts, thinking), do: parts ++ [%{type: :thinking, text: thinking}]

  # Extract object from message (for structured output)
  defp extract_object_from_message(%ReqLLM.Message{content: content, tool_calls: tool_calls}) do
    with nil <- extract_from_tool_calls(tool_calls) do
      extract_from_content(content)
    end
  end

  defp extract_from_tool_calls(tool_calls) when is_list(tool_calls) do
    case Enum.find(tool_calls, fn tc -> tc.name == "structured_output" end) do
      %{arguments: args} when is_map(args) -> args
      _ -> nil
    end
  end

  defp extract_from_tool_calls(_), do: nil

  defp extract_from_content(content) do
    case Enum.find(content, fn part -> is_map(part) and part[:type] == :object end) do
      %{object: obj} when is_map(obj) -> obj
      _ -> nil
    end
  end

  # Generate a unique response ID
  defp generate_response_id do
    "stream_response_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  # Normalize streaming usage field names to match non-streaming format
  defp normalize_usage_fields(nil), do: nil

  defp normalize_usage_fields(usage) when is_map(usage) do
    usage
    |> Map.put_new(:cached_tokens, Map.get(usage, :cached_input, 0))
    |> Map.put_new(:reasoning_tokens, Map.get(usage, :reasoning, 0))
  end
end

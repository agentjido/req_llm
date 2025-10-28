defmodule ReqLLM.Providers.AmazonBedrock.Converse do
  @moduledoc """
  AWS Bedrock Converse API support for unified tool calling across models.

  The Converse API provides a standardized interface for tool calling that works
  across all Bedrock models (Anthropic, OpenAI, Meta, etc.) with consistent
  request/response formats.

  ## Advantages

  - Unified tool calling across all Bedrock models
  - Simpler, cleaner API compared to model-specific endpoints
  - Better multi-turn conversation handling

  ## Disadvantages

  - May lag behind model-specific endpoints for cutting-edge features
  - Adds small translation overhead (typically low milliseconds)

  ## API Format

  Request:
  ```json
  {
    "messages": [
      {"role": "user", "content": [{"text": "Hello"}]}
    ],
    "system": [{"text": "You are a helpful assistant"}],
    "inferenceConfig": {
      "maxTokens": 1000,
      "temperature": 0.7
    },
    "toolConfig": {
      "tools": [
        {
          "toolSpec": {
            "name": "get_weather",
            "description": "Get weather",
            "inputSchema": {
              "json": {
                "type": "object",
                "properties": {...},
                "required": [...]
              }
            }
          }
        }
      ]
    }
  }
  ```

  Response:
  ```json
  {
    "output": {
      "message": {
        "role": "assistant",
        "content": [
          {"text": "Let me check the weather"},
          {
            "toolUse": {
              "toolUseId": "id123",
              "name": "get_weather",
              "input": {"location": "SF"}
            }
          }
        ]
      }
    },
    "stopReason": "tool_use",
    "usage": {
      "inputTokens": 100,
      "outputTokens": 50,
      "totalTokens": 150
    }
  }
  ```
  """

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall

  @doc """
  Format a ReqLLM context into Bedrock Converse API format.

  Converts ReqLLM messages and tools into the Converse API request structure.

  For :object operations, creates a synthetic "structured_output" tool to
  leverage unified tool calling for structured JSON output across all models.
  """
  def format_request(_model_id, context, opts) do
    operation = opts[:operation]

    # For :object operation, inject the structured_output tool
    {context, opts} =
      if operation == :object do
        prepare_structured_output_context(context, opts)
      else
        {context, opts}
      end

    request = %{}

    # Add messages
    request = add_messages(request, context.messages)

    # Add tools if present (tools are in opts, not context)
    request =
      if tools = opts[:tools] do
        add_tools(request, tools)
      else
        request
      end

    # Add tool choice if specified
    # Note: Only some model families support toolChoice in Converse API
    request =
      if tool_choice = opts[:tool_choice] do
        add_tool_choice(request, tool_choice, opts[:model_family], opts[:formatter_module])
      else
        request
      end

    # Add inference config
    request = add_inference_config(request, opts)

    # Add additionalModelRequestFields for model-specific features (e.g., Claude extended thinking)
    request = add_additional_fields(request, opts)

    request
  end

  # Create the synthetic structured_output tool for :object operations
  defp prepare_structured_output_context(context, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    # Create the structured_output tool (same as native Anthropic provider)
    structured_output_tool =
      ReqLLM.Tool.new!(
        name: "structured_output",
        description: "Generate structured output matching the provided schema",
        parameter_schema: compiled_schema.schema,
        callback: fn _args -> {:ok, "structured output generated"} end
      )

    # Add tool to context - Context may or may not have a tools field
    existing_tools = Map.get(context, :tools, [])
    updated_context = Map.put(context, :tools, [structured_output_tool | existing_tools])

    # Update opts to force tool choice
    updated_opts =
      opts
      |> Keyword.put(:tools, [structured_output_tool | Keyword.get(opts, :tools, [])])
      |> Keyword.put(:tool_choice, %{type: "tool", name: "structured_output"})

    {updated_context, updated_opts}
  end

  @doc """
  Parse a Converse API response into ReqLLM format.

  Converts Converse API response structure back to ReqLLM.Response with
  proper Message and ContentPart structures.

  For :object operations, extracts the structured output from the tool call.
  """
  def parse_response(response_body, opts) do
    message_data = get_in(response_body, ["output", "message"])
    stop_reason = response_body["stopReason"]
    usage = response_body["usage"]

    # Parse message (includes reasoning content if present)
    message = parse_message(message_data)

    # Build context with message
    context = %ReqLLM.Context{
      messages: if(message, do: [message], else: [])
    }

    # Build response
    response = %ReqLLM.Response{
      id: get_in(response_body, ["output", "messageId"]) || "unknown",
      model: opts[:model] || "bedrock-converse",
      context: context,
      message: message,
      finish_reason: map_stop_reason(stop_reason),
      usage: parse_usage(usage),
      stream?: false
    }

    # For :object operation, extract structured output from tool call
    final_response =
      if opts[:operation] == :object do
        extract_and_set_object(response)
      else
        response
      end

    {:ok, final_response}
  end

  # Extract structured output from tool call (same logic as native Anthropic provider)
  defp extract_and_set_object(response) do
    extracted_object =
      response
      |> ReqLLM.Response.tool_calls()
      |> ReqLLM.ToolCall.find_args("structured_output")

    %{response | object: extracted_object}
  end

  @doc """
  Parse a Converse API streaming chunk.

  Handles different event types from the Converse stream.
  """
  def parse_stream_chunk(chunk, _model_id) do
    case chunk do
      %{"contentBlockStart" => _data} ->
        # Start of a new content block
        {:ok, nil}

      %{"contentBlockDelta" => delta_data} ->
        # Handle both text and reasoning deltas
        cond do
          delta = get_in(delta_data, ["delta", "text"]) ->
            {:ok, %{type: :text, text: delta}}

          reasoning_delta = get_in(delta_data, ["delta", "reasoningContent"]) ->
            # Claude extended thinking reasoning delta
            {:ok, %{type: :thinking, text: reasoning_delta}}

          true ->
            {:ok, nil}
        end

      %{"contentBlockStop" => _data} ->
        # End of content block
        {:ok, nil}

      %{"messageStart" => _data} ->
        # Start of message
        {:ok, nil}

      %{"messageStop" => stop_data} ->
        # End of message with stop reason
        stop_reason = stop_data["stopReason"]
        {:ok, %{type: :done, finish_reason: map_stop_reason(stop_reason)}}

      %{"metadata" => metadata} ->
        # Usage metadata
        if usage = metadata["usage"] do
          {:ok, %{type: :usage, usage: parse_usage(usage)}}
        else
          {:ok, nil}
        end

      _ ->
        {:error, :unknown_chunk_type}
    end
  end

  # Private functions

  defp add_messages(request, messages) do
    {system_messages, non_system_messages} =
      Enum.split_with(messages, fn %Message{role: role} -> role == :system end)

    # Add system messages
    request =
      case system_messages do
        [] ->
          request

        [%Message{content: content} | _] ->
          # Converse API accepts system as array of content blocks
          Map.put(request, "system", encode_content_for_system(content))
      end

    # Add regular messages
    encoded_messages = Enum.map(non_system_messages, &encode_message/1)
    Map.put(request, "messages", encoded_messages)
  end

  defp add_tools(request, tools) do
    tool_specs =
      Enum.map(tools, fn tool ->
        ReqLLM.Schema.to_bedrock_converse_format(tool)
      end)

    Map.put(request, "toolConfig", %{
      "tools" => tool_specs
    })
  end

  # Add tool choice configuration to force specific tool usage
  # Only supported by some model families - check with the formatter module
  defp add_tool_choice(request, tool_choice, _model_family, formatter_module) do
    # Ask the model family formatter if it supports toolChoice in Converse API
    supports_tool_choice =
      formatter_module &&
        function_exported?(formatter_module, :supports_converse_tool_choice?, 0) &&
        formatter_module.supports_converse_tool_choice?()

    if supports_tool_choice do
      # Converse API uses toolChoice in toolConfig
      existing_tool_config = Map.get(request, "toolConfig", %{})

      # Convert from Anthropic format to Converse format
      tool_choice_config =
        case tool_choice do
          %{type: "tool", name: name} ->
            # Force specific tool
            %{"tool" => %{"name" => name}}

          %{type: "any"} ->
            # Force any tool (must use a tool)
            %{"any" => %{}}

          %{type: "auto"} ->
            # Auto decide (default)
            %{"auto" => %{}}

          _ ->
            # Unknown format, use auto
            %{"auto" => %{}}
        end

      updated_tool_config = Map.put(existing_tool_config, "toolChoice", tool_choice_config)
      Map.put(request, "toolConfig", updated_tool_config)
    else
      # For non-Anthropic models, skip toolChoice entirely
      request
    end
  end

  defp add_inference_config(request, opts) do
    config = %{}

    config =
      if max_tokens = opts[:max_tokens] do
        Map.put(config, "maxTokens", max_tokens)
      else
        config
      end

    config =
      if temperature = opts[:temperature] do
        Map.put(config, "temperature", temperature)
      else
        config
      end

    config =
      if top_p = opts[:top_p] do
        Map.put(config, "topP", top_p)
      else
        config
      end

    config =
      if stop_sequences = opts[:stop_sequences] do
        Map.put(config, "stopSequences", stop_sequences)
      else
        config
      end

    if config == %{} do
      request
    else
      Map.put(request, "inferenceConfig", config)
    end
  end

  defp add_additional_fields(request, opts) do
    case opts[:additional_model_request_fields] do
      nil -> request
      fields when is_map(fields) -> Map.put(request, "additionalModelRequestFields", fields)
      _ -> request
    end
  end

  # Assistant message with tool calls (new ToolCall pattern)
  defp encode_message(%Message{role: :assistant, tool_calls: tool_calls, content: content})
       when is_list(tool_calls) and tool_calls != [] do
    text_content = encode_content(content)
    tool_blocks = Enum.map(tool_calls, &encode_tool_call_to_tool_use/1)

    content_blocks =
      case text_content do
        [] -> tool_blocks
        blocks when is_list(blocks) -> blocks ++ tool_blocks
      end

    %{
      "role" => "assistant",
      "content" => content_blocks
    }
  end

  # Tool result message (new ToolCall pattern)
  defp encode_message(%Message{role: :tool, tool_call_id: id, content: content}) do
    %{
      "role" => "user",
      "content" => [
        %{
          "toolResult" => %{
            "toolUseId" => id,
            "content" => [%{"text" => extract_text_content(content)}]
          }
        }
      ]
    }
  end

  # Regular message (user, assistant, system)
  defp encode_message(%Message{role: role, content: content}) do
    # Converse API only accepts "user" or "assistant" roles
    # Tool results must be wrapped in a "user" message
    normalized_role = if role == :tool, do: :user, else: role

    %{
      "role" => Atom.to_string(normalized_role),
      "content" => encode_content(content)
    }
  end

  defp encode_content_for_system(content) when is_binary(content) do
    [%{"text" => content}]
  end

  defp encode_content_for_system(content) when is_list(content) do
    Enum.map(content, &encode_content_part/1)
  end

  defp encode_content(content) when is_binary(content) do
    [%{"text" => content}]
  end

  defp encode_content(content) when is_list(content) do
    Enum.map(content, &encode_content_part/1)
  end

  defp encode_content_part(%ContentPart{type: :text, text: text}) do
    %{"text" => text}
  end

  defp encode_content_part(%ContentPart{type: :image, data: data, media_type: media_type}) do
    %{
      "image" => %{
        "format" => image_format_from_media_type(media_type),
        "source" => %{
          "bytes" => Base.encode64(data)
        }
      }
    }
  end

  defp encode_content_part(_), do: nil

  # Helper to encode ToolCall struct to Converse API toolUse format
  defp encode_tool_call_to_tool_use(%ToolCall{id: id, function: %{name: name, arguments: args}}) do
    %{
      "toolUse" => %{
        "toolUseId" => id,
        "name" => name,
        "input" => Jason.decode!(args)
      }
    }
  end

  # Helper to extract text content from content parts
  defp extract_text_content(content) when is_binary(content), do: content

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.find_value(fn
      %ContentPart{type: :text, text: text} -> text
      _ -> nil
    end)
    |> case do
      nil -> ""
      text -> text
    end
  end

  defp extract_text_content(_), do: ""

  defp image_format_from_media_type("image/png"), do: "png"
  defp image_format_from_media_type("image/jpeg"), do: "jpeg"
  defp image_format_from_media_type("image/jpg"), do: "jpeg"
  defp image_format_from_media_type("image/gif"), do: "gif"
  defp image_format_from_media_type("image/webp"), do: "webp"
  defp image_format_from_media_type(_), do: "png"

  defp parse_message(nil), do: nil

  defp parse_message(message_data) do
    role = String.to_atom(message_data["role"])
    content_blocks = message_data["content"] || []

    # Separate tool calls from regular content
    {tool_calls, content_parts} = parse_content_with_tool_calls(content_blocks)

    # Build message with tool_calls field if present
    message = %Message{role: role, content: content_parts}

    if tool_calls == [] do
      message
    else
      %{message | tool_calls: tool_calls}
    end
  end

  # Parse content and separate tool calls from regular content
  defp parse_content_with_tool_calls(content_blocks) when is_list(content_blocks) do
    Enum.reduce(content_blocks, {[], []}, fn block, {tool_calls, content_parts} ->
      case block do
        %{"toolUse" => tool_use} ->
          # Convert to ToolCall struct
          tool_call =
            ToolCall.new(
              tool_use["toolUseId"],
              tool_use["name"],
              Jason.encode!(tool_use["input"])
            )

          {[tool_call | tool_calls], content_parts}

        _ ->
          # Parse as regular content part
          if part = parse_content_block(block) do
            {tool_calls, [part | content_parts]}
          else
            {tool_calls, content_parts}
          end
      end
    end)
    |> then(fn {tool_calls, content_parts} ->
      {Enum.reverse(tool_calls), Enum.reverse(content_parts)}
    end)
  end

  defp parse_content_with_tool_calls(_), do: {[], []}

  # Parse individual content blocks (excluding tool calls which are handled separately)
  defp parse_content_block(%{"text" => text}) do
    ContentPart.text(text)
  end

  defp parse_content_block(%{"reasoningText" => reasoning_text}) do
    # Claude extended thinking reasoning content
    %ContentPart{type: :thinking, text: reasoning_text}
  end

  defp parse_content_block(%{"image" => _image}) do
    # Image in response - for now skip
    nil
  end

  defp parse_content_block(_), do: nil

  defp parse_usage(nil), do: nil

  defp parse_usage(usage) do
    %{
      input_tokens: usage["inputTokens"],
      output_tokens: usage["outputTokens"]
    }
  end

  defp map_stop_reason("end_turn"), do: :stop
  defp map_stop_reason("tool_use"), do: :tool_calls
  defp map_stop_reason("max_tokens"), do: :length
  defp map_stop_reason("stop_sequence"), do: :stop
  defp map_stop_reason("content_filtered"), do: :content_filter
  defp map_stop_reason(_), do: :stop
end

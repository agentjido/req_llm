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

  @doc """
  Format a ReqLLM context into Bedrock Converse API format.

  Converts ReqLLM messages and tools into the Converse API request structure.
  """
  def format_request(_model_id, context, opts) do
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

    # Add inference config
    request = add_inference_config(request, opts)

    request
  end

  @doc """
  Parse a Converse API response into ReqLLM format.

  Converts Converse API response structure back to ReqLLM.Response with
  proper Message and ContentPart structures.
  """
  def parse_response(response_body, opts) do
    message_data = get_in(response_body, ["output", "message"])
    stop_reason = response_body["stopReason"]
    usage = response_body["usage"]

    # Parse message
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

    {:ok, response}
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
        # Text delta
        if delta = get_in(delta_data, ["delta", "text"]) do
          {:ok, %{type: :text, text: delta}}
        else
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

  defp encode_message(%Message{role: role, content: content}) do
    %{
      "role" => Atom.to_string(role),
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

  defp encode_content_part(%ContentPart{type: :tool_call} = part) do
    %{
      "toolUse" => %{
        "toolUseId" => part.tool_call_id,
        "name" => part.tool_name,
        "input" => part.input
      }
    }
  end

  defp encode_content_part(%ContentPart{type: :tool_result} = part) do
    %{
      "toolResult" => %{
        "toolUseId" => part.tool_call_id,
        "content" => [%{"text" => encode_tool_output(part.output)}]
      }
    }
  end

  defp encode_content_part(_), do: nil

  defp encode_tool_output(output) when is_binary(output), do: output
  defp encode_tool_output(output), do: Jason.encode!(output)

  defp image_format_from_media_type("image/png"), do: "png"
  defp image_format_from_media_type("image/jpeg"), do: "jpeg"
  defp image_format_from_media_type("image/jpg"), do: "jpeg"
  defp image_format_from_media_type("image/gif"), do: "gif"
  defp image_format_from_media_type("image/webp"), do: "webp"
  defp image_format_from_media_type(_), do: "png"

  defp parse_message(nil), do: nil

  defp parse_message(message_data) do
    role = String.to_atom(message_data["role"])
    content = parse_content(message_data["content"])

    %Message{role: role, content: content}
  end

  defp parse_content(nil), do: []
  defp parse_content([]), do: []

  defp parse_content(content_blocks) when is_list(content_blocks) do
    content_blocks
    |> Enum.map(&parse_content_block/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_content_block(%{"text" => text}) do
    ContentPart.text(text)
  end

  defp parse_content_block(%{"toolUse" => tool_use}) do
    ContentPart.tool_call(
      tool_use["toolUseId"],
      tool_use["name"],
      tool_use["input"]
    )
  end

  defp parse_content_block(%{"toolResult" => tool_result}) do
    # Extract text from content array
    output =
      case tool_result["content"] do
        [%{"text" => text} | _] -> text
        _ -> nil
      end

    ContentPart.tool_result(tool_result["toolUseId"], output)
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

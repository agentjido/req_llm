defmodule ReqLLM.Providers.AmazonBedrock.Anthropic do
  @moduledoc """
  Anthropic model family support for AWS Bedrock.

  Handles Claude models (Claude 3 Sonnet, Haiku, Opus, etc.) on AWS Bedrock.
  """

  alias ReqLLM.StreamChunk

  @doc """
  Formats a ReqLLM context into Anthropic-specific request format for Bedrock.
  """
  def format_request(_model_id, context, opts) do
    # Extract system message if present
    {system_message, other_messages} =
      case context.messages do
        [%{role: :system, content: content} | rest] ->
          {format_content_as_text(content), rest}

        messages ->
          {nil, messages}
      end

    # Convert remaining messages to Anthropic format
    messages = Enum.map(other_messages, &convert_message/1)

    # Build Anthropic request body
    body = %{
      messages: messages,
      max_tokens: opts[:max_tokens] || 1024
    }

    # Add system message if present
    body = if system_message, do: Map.put(body, :system, system_message), else: body

    # Add optional parameters
    body
    |> maybe_add_param(:temperature, opts[:temperature])
    |> maybe_add_param(:top_p, opts[:top_p])
    |> maybe_add_param(:top_k, opts[:top_k])
    |> maybe_add_param(:stop_sequences, opts[:stop_sequences])
    |> maybe_add_param(:anthropic_version, "bedrock-2023-05-31")
  end

  defp format_content_as_text(content) when is_list(content) do
    content
    |> Enum.map_join(" ", fn
      %{text: text} -> text
      _ -> ""
    end)
  end

  defp format_content_as_text(text) when is_binary(text), do: text

  defp convert_message(message) do
    %{
      role: convert_role(message.role),
      content: convert_content(message.content)
    }
  end

  defp convert_role(:user), do: "user"
  defp convert_role(:assistant), do: "assistant"
  # Bedrock Anthropic doesn't support system role directly
  defp convert_role(:system), do: "user"
  defp convert_role(_), do: "user"

  defp convert_content([%{type: :text, text: text}]), do: text
  defp convert_content(text) when is_binary(text), do: text

  defp convert_content(parts) when is_list(parts) do
    # Convert complex content parts
    parts
    |> Enum.map(fn
      %{type: :text, text: text} -> %{"type" => "text", "text" => text}
      part -> part
    end)
  end

  defp maybe_add_param(body, _key, nil), do: body
  defp maybe_add_param(body, key, value), do: Map.put(body, key, value)

  @doc """
  Parses Anthropic response from Bedrock into ReqLLM format.
  """
  def parse_response(body, _opts) when is_map(body) do
    # Extract content
    content_text = extract_content(body)

    # Create an assistant message
    message = %ReqLLM.Message{
      role: :assistant,
      content: [%ReqLLM.Message.ContentPart{type: :text, text: content_text}]
    }

    # Create a simple context with just the assistant response
    context = ReqLLM.Context.new([message])

    # Convert Anthropic response to ReqLLM.Response format
    response = %ReqLLM.Response{
      id: Map.get(body, "id", "bedrock-#{System.unique_integer([:positive])}"),
      model: Map.get(body, "model", "bedrock"),
      context: context,
      message: message,
      object: nil,
      stream?: false,
      stream: nil,
      usage: extract_usage_from_response(body),
      finish_reason: Map.get(body, "stop_reason"),
      provider_meta: %{
        stop_sequence: Map.get(body, "stop_sequence"),
        type: Map.get(body, "type", "message")
      },
      error: nil
    }

    {:ok, response}
  rescue
    e -> {:error, "Failed to parse Anthropic response: #{inspect(e)}"}
  end

  defp extract_content(%{"content" => content}) when is_list(content) do
    # Extract text from content array
    content
    |> Enum.map_join("", fn
      %{"text" => text} -> text
      _ -> ""
    end)
  end

  defp extract_content(%{"content" => content}) when is_binary(content), do: content
  defp extract_content(_), do: ""

  defp extract_usage_from_response(%{"usage" => usage}) when is_map(usage) do
    %{
      input_tokens: Map.get(usage, "input_tokens", 0),
      output_tokens: Map.get(usage, "output_tokens", 0),
      total_tokens: Map.get(usage, "input_tokens", 0) + Map.get(usage, "output_tokens", 0)
    }
  end

  defp extract_usage_from_response(_), do: nil

  @doc """
  Parses a streaming chunk for Anthropic models.
  """
  def parse_stream_chunk(chunk, _opts) when is_map(chunk) do
    # Check if this is a wrapped chunk or direct JSON
    parsed =
      case chunk do
        %{"chunk" => %{"bytes" => encoded}} ->
          # AWS SDK format: chunk wrapper with base64-encoded content
          decoded = Base.decode64!(encoded)
          Jason.decode!(decoded)

        %{"bytes" => encoded} ->
          # Direct bytes format: base64-encoded Anthropic events
          decoded = Base.decode64!(encoded)
          Jason.decode!(decoded)

        %{"type" => _} = event ->
          # Direct JSON event (already decoded by AWS event stream parser)
          event

        _ ->
          # Unknown format
          {:error, "Unknown chunk format"}
      end

    case parsed do
      {:error, _} = error ->
        error

      event ->
        # Convert Anthropic streaming events to ReqLLM stream chunks
        convert_stream_event(event)
    end
  rescue
    e -> {:error, "Failed to parse stream chunk: #{inspect(e)}"}
  end

  defp convert_stream_event(%{"type" => "message_start", "message" => msg}) do
    {:ok,
     %StreamChunk{
       type: :meta,
       metadata: %{
         type: :start,
         id: msg["id"],
         model: msg["model"]
       }
     }}
  end

  defp convert_stream_event(%{"type" => "content_block_start", "content_block" => block}) do
    {:ok,
     %StreamChunk{
       type: :meta,
       metadata: %{
         type: :content_start,
         index: block["index"]
       }
     }}
  end

  defp convert_stream_event(%{"type" => "content_block_delta", "delta" => delta}) do
    text =
      case delta do
        %{"text" => t} -> t
        %{"partial_json" => json} -> json
        _ -> ""
      end

    {:ok,
     %StreamChunk{
       type: :content,
       text: text,
       metadata: %{index: Map.get(delta, "index", 0)}
     }}
  end

  defp convert_stream_event(%{"type" => "content_block_stop"}) do
    {:ok,
     %StreamChunk{
       type: :meta,
       metadata: %{type: :content_stop}
     }}
  end

  defp convert_stream_event(%{"type" => "message_delta", "delta" => delta, "usage" => usage}) do
    {:ok,
     %StreamChunk{
       type: :meta,
       metadata: %{
         type: :delta,
         finish_reason: delta["stop_reason"],
         stop_reason: delta["stop_reason"],
         stop_sequence: delta["stop_sequence"],
         usage: %{
           "output_tokens" => usage["output_tokens"]
         }
       }
     }}
  end

  defp convert_stream_event(%{"type" => "message_stop"} = stop) do
    {:ok,
     %StreamChunk{
       type: :meta,
       metadata: %{
         type: :stop,
         stop_reason: stop["stop_reason"],
         stop_sequence: stop["stop_sequence"],
         finish_reason: stop["stop_reason"]
       }
     }}
  end

  defp convert_stream_event(_) do
    # Unknown event type
    {:ok, nil}
  end

  @doc """
  Extracts usage metadata from the response body.
  """
  def extract_usage(body, _model) when is_map(body) do
    case Map.get(body, "usage") do
      %{"input_tokens" => input, "output_tokens" => output} ->
        {:ok,
         %{
           input_tokens: input,
           output_tokens: output,
           total_tokens: input + output
         }}

      _ ->
        {:error, :no_usage}
    end
  end

  def extract_usage(_, _), do: {:error, :no_usage}
end

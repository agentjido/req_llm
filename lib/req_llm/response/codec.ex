defprotocol ReqLLM.Response.Codec do
  @moduledoc """
  Protocol for decoding provider responses and SSE events to canonical ReqLLM structures.

  This protocol handles both non-streaming response decoding and streaming SSE event processing,
  converting provider-specific formats to canonical ReqLLM structures.

  ## Default Implementation

  The `Map` implementation provides baseline OpenAI-compatible decoding for common providers
  that use the ChatCompletions API format (OpenAI, Groq, OpenRouter, xAI):

      # Non-streaming response decoding
      ReqLLM.Response.Codec.decode_response(response_json, model)
      #=> {:ok, %ReqLLM.Response{message: %ReqLLM.Message{...}, usage: %{...}}}

      # Streaming SSE event decoding
      ReqLLM.Response.Codec.decode_sse_event(sse_event, model) 
      #=> [%ReqLLM.StreamChunk{type: :content, text: "Hello"}]

  ## Provider-Specific Overrides

  Providers with unique response formats implement their own protocol:

      defimpl ReqLLM.Response.Codec, for: MyProvider.Response do
        def decode_response(data, model) do
          # Custom decoding logic for provider-specific format
        end

        def decode_sse_event(event, model) do
          # Custom SSE event processing
        end
      end

  ## Response Pipeline

  1. **Raw provider response** → `decode_response/2` → **ReqLLM.Response struct**
  2. **SSE event** → `decode_sse_event/2` → **List of StreamChunk structs**

  """

  @fallback_to_any true

  @doc """
  Decode provider response data with model context.
  """
  @spec decode_response(t(), ReqLLM.Model.t()) :: {:ok, ReqLLM.Response.t()} | {:error, term()}
  def decode_response(data, model)

  @doc """
  Decode SSE event data into StreamChunks with model context for streaming responses.
  """
  @spec decode_sse_event(t(), ReqLLM.Model.t()) :: [ReqLLM.StreamChunk.t()]
  def decode_sse_event(sse_event, model)
end

defimpl ReqLLM.Response.Codec, for: ReqLLM.Response do
  def decode_response(%ReqLLM.Response{} = response, _model), do: {:ok, response}
  def decode_sse_event(_sse_event, _model), do: []
end

defimpl ReqLLM.Response.Codec, for: Map do
  def decode_response(data, model) when is_map(data) do
    decode_response_data(data, model.model || "unknown")
  end

  def decode_response(_data, _model) do
    {:error, :not_implemented}
  end

  def decode_sse_event(%{data: data}, _model) when is_map(data) do
    case data do
      %{"choices" => [%{"delta" => delta} | _]} -> decode_delta(delta)
      _ -> []
    end
  end

  def decode_sse_event(_, _model), do: []

  defp decode_delta(%{"content" => content}) when is_binary(content) and content != "" do
    [ReqLLM.StreamChunk.text(content)]
  end

  defp decode_delta(%{"tool_calls" => tool_calls}) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(&decode_tool_call_delta/1)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_delta(_), do: []

  defp decode_tool_call_delta(%{
         "id" => id,
         "type" => "function",
         "function" => %{"name" => name, "arguments" => args_json}
       }) do
    case Jason.decode(args_json || "{}") do
      {:ok, args} -> ReqLLM.StreamChunk.tool_call(name, args, %{id: id})
      {:error, _} -> ReqLLM.StreamChunk.tool_call(name, %{}, %{id: id})
    end
  end

  defp decode_tool_call_delta(_), do: nil

  defp decode_response_data(data, model) when is_map(data) do
    id = Map.get(data, "id", "unknown")
    model_name = Map.get(data, "model", model || "unknown")
    usage = parse_usage(Map.get(data, "usage"))

    choices = Map.get(data, "choices", [])
    first_choice = Enum.at(choices, 0, %{})

    finish_reason = parse_finish_reason(Map.get(first_choice, "finish_reason"))

    content_chunks =
      case first_choice do
        %{"message" => message} -> decode_message(message)
        %{"delta" => delta} -> decode_delta(delta)
        _ -> []
      end

    message = build_message_from_chunks(content_chunks)

    context = %ReqLLM.Context{
      messages: if(message, do: [message], else: [])
    }

    response = %ReqLLM.Response{
      id: id,
      model: model_name,
      context: context,
      message: message,
      stream?: false,
      stream: nil,
      usage: usage,
      finish_reason: finish_reason,
      provider_meta: Map.drop(data, ["id", "model", "choices", "usage"])
    }

    {:ok, response}
  end

  defp decode_message(%{"content" => content}) when is_binary(content) and content != "" do
    [ReqLLM.StreamChunk.text(content)]
  end

  defp decode_message(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(&decode_content_part/1)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp decode_message(%{"tool_calls" => tool_calls}) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(&decode_tool_call/1)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_message(_), do: []

  defp decode_content_part(%{"type" => "text", "text" => text}) do
    [ReqLLM.StreamChunk.text(text)]
  end

  defp decode_content_part(_), do: []

  defp decode_tool_call(%{
         "id" => id,
         "type" => "function",
         "function" => %{"name" => name, "arguments" => args_json}
       }) do
    case Jason.decode(args_json || "{}") do
      {:ok, args} -> ReqLLM.StreamChunk.tool_call(name, args, %{id: id})
      {:error, _} -> nil
    end
  end

  defp decode_tool_call(_), do: nil

  defp build_message_from_chunks([]), do: nil

  defp build_message_from_chunks(chunks) do
    content_parts =
      chunks
      |> Enum.map(&chunk_to_content_part/1)
      |> Enum.reject(&is_nil/1)

    if content_parts != [] do
      %ReqLLM.Message{
        role: :assistant,
        content: content_parts,
        metadata: %{}
      }
    end
  end

  defp chunk_to_content_part(%ReqLLM.StreamChunk{type: :content, text: text}) do
    %ReqLLM.Message.ContentPart{type: :text, text: text}
  end

  defp chunk_to_content_part(%ReqLLM.StreamChunk{
         type: :tool_call,
         name: name,
         arguments: args,
         metadata: meta
       }) do
    %ReqLLM.Message.ContentPart{
      type: :tool_call,
      tool_name: name,
      input: args,
      tool_call_id: Map.get(meta, :id)
    }
  end

  defp chunk_to_content_part(_), do: nil

  defp parse_usage(%{
         "prompt_tokens" => input,
         "completion_tokens" => output,
         "total_tokens" => total
       }) do
    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: total
    }
  end

  defp parse_usage(_), do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  defp parse_finish_reason("stop"), do: :stop
  defp parse_finish_reason("length"), do: :length
  defp parse_finish_reason("tool_calls"), do: :tool_calls
  defp parse_finish_reason("content_filter"), do: :content_filter
  defp parse_finish_reason(reason) when is_binary(reason), do: reason
  defp parse_finish_reason(_), do: nil
end

defimpl ReqLLM.Response.Codec, for: Any do
  def decode_response(_, _), do: {:error, :not_implemented}
  def decode_sse_event(_sse_event, _model), do: []
end

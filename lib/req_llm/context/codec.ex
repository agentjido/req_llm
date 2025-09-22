defprotocol ReqLLM.Context.Codec do
  @moduledoc """
  Protocol for encoding canonical ReqLLM.Context structures to provider-specific request JSON.

  This protocol handles the request encoding phase, converting ReqLLM contexts and models
  into the JSON format expected by each provider's API.

  ## Default Implementation

  The `Map` implementation provides a baseline OpenAI-compatible request format that works
  for most providers including OpenAI, Groq, OpenRouter, and xAI:

      ReqLLM.Context.Codec.encode_request(context, model)
      #=> %{
      #     model: "gpt-4",
      #     messages: [%{role: "user", content: "Hello"}],
      #     stream: true,
      #     max_tokens: 1000,
      #     temperature: 0.7,
      #     tools: [%{type: "function", function: %{name: "...", ...}}]
      #   }

  ## Provider-Specific Overrides

  Providers that require different formats can implement their own protocol:

      defimpl ReqLLM.Context.Codec, for: MyProvider.Context do
        def encode_request(context, model) do
          # Custom encoding logic for provider-specific format
        end
      end

  ## Tool Encoding

  Tools are automatically converted to OpenAI function format using `ReqLLM.Schema.to_openai_format/1`,
  which handles parameter schema conversion from keyword lists to JSON Schema.

  ## Tool Calls in Messages

  When assistant messages contain `tool_calls`, they are encoded at the message level (not in content):

      message = %ReqLLM.Message{
        role: :assistant,
        content: [],
        tool_calls: [
          %{
            id: "call_123",
            type: "function",
            function: %{
              name: "get_weather",
              arguments: ~s({"location": "Paris"})
            }
          }
        ]
      }

      # Encodes to:
      %{
        role: "assistant",
        content: [],
        tool_calls: [...]  # At message level, not in content
      }

  """

  @fallback_to_any true

  @doc """
  Encode context and model to provider-specific request JSON.
  """
  @spec encode_request(ReqLLM.Context.t(), ReqLLM.Model.t()) :: term()
  def encode_request(context, model)
end

defimpl ReqLLM.Context.Codec, for: Map do
  def encode_request(context, model) do
    %{
      model: extract_model_name(model),
      messages: encode_messages(context.messages)
    }
    |> add_tools(Map.get(context, :tools, []))
    |> filter_nil_values()
  end

  defp extract_model_name(%{model: model_name}), do: model_name
  defp extract_model_name(model) when is_binary(model), do: model
  defp extract_model_name(_), do: "unknown"

  defp encode_messages(messages) do
    Enum.map(messages, &encode_message/1)
  end

  defp encode_message(%ReqLLM.Message{role: role, content: content, tool_calls: tool_calls}) do
    base_message = %{
      role: to_string(role),
      content: encode_content(content)
    }

    # Add tool_calls if present and not nil
    case tool_calls do
      nil -> base_message
      [] -> base_message
      calls -> Map.put(base_message, :tool_calls, calls)
    end
  end

  defp encode_content(content) when is_binary(content), do: content

  defp encode_content(content) when is_list(content) do
    content
    |> Enum.map(&encode_content_part/1)
    |> maybe_flatten_single_text()
  end

  # Flatten single text content to a string for cleaner wire format
  defp maybe_flatten_single_text([%{type: "text", text: text}]), do: text

  defp maybe_flatten_single_text(content) do
    # Filter out nil values first
    filtered = Enum.reject(content, &is_nil/1)

    case filtered do
      [%{type: "text", text: text}] -> text
      _ -> filtered
    end
  end

  defp encode_content_part(%ReqLLM.Message.ContentPart{type: :text, text: text}) do
    %{type: "text", text: text}
  end

  defp encode_content_part(%ReqLLM.Message.ContentPart{
         type: :tool_call,
         tool_name: name,
         input: input,
         tool_call_id: id
       }) do
    %{
      id: id,
      type: "function",
      function: %{
        name: name,
        arguments: Jason.encode!(input)
      }
    }
  end

  defp encode_content_part(_), do: nil

  defp add_tools(request, []), do: request

  defp add_tools(request, tools) when is_list(tools) do
    Map.put(request, :tools, encode_tools(tools))
  end

  defp encode_tools(tools) do
    Enum.map(tools, &encode_tool/1)
  end

  defp encode_tool(tool) do
    ReqLLM.Schema.to_openai_format(tool)
  end

  defp filter_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end

defimpl ReqLLM.Context.Codec, for: ReqLLM.Context do
  def encode_request(context, model) do
    ReqLLM.Context.Codec.Map.encode_request(context, model)
  end
end

defimpl ReqLLM.Context.Codec, for: Any do
  def encode_request(_, _), do: {:error, :not_implemented}
end

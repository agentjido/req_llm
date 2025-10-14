defmodule ReqLLM.Providers.AmazonBedrock.OpenAI do
  @moduledoc """
  OpenAI model family support for AWS Bedrock.

  Handles OpenAI's OSS models (gpt-oss-120b, gpt-oss-20b) on AWS Bedrock.

  This module acts as a thin adapter between Bedrock's AWS-specific wrapping
  and OpenAI's native Chat Completions format.
  """

  alias ReqLLM.Provider.Defaults
  alias ReqLLM.Providers.AmazonBedrock

  @doc """
  Formats a ReqLLM context into OpenAI request format for Bedrock.

  Uses standard OpenAI Chat Completions format - no modifications needed
  unlike Anthropic which rejects the model field.
  """
  def format_request(model_id, context, opts) do
    # Get tools from context if available
    tools = Map.get(context, :tools, [])

    # Create a minimal request struct to use default OpenAI encoding
    temp_request = %Req.Request{
      method: :post,
      url: URI.parse("https://example.com/temp"),
      headers: %{},
      body: {:json, %{}},
      options:
        Map.new(
          [
            model: model_id,
            context: context,
            operation: :chat,
            tools: tools
          ] ++ Keyword.drop(opts, [:model, :tools])
        )
    }

    # Use standard OpenAI encoding
    encoded_request = Defaults.default_encode_body(temp_request)

    # Return the parsed body as a map
    Jason.decode!(encoded_request.body)
  end

  @doc """
  Parses OpenAI response from Bedrock into ReqLLM format.

  Manually decodes the OpenAI Chat Completions format.
  """
  def parse_response(body, opts) when is_map(body) do
    # OpenAI response format has choices array with message object
    with {:ok, choices} <- Map.fetch(body, "choices"),
         [choice | _] <- choices,
         {:ok, message_data} <- Map.fetch(choice, "message") do
      # Parse the message content
      message = parse_message(message_data)

      # Extract usage if present
      usage = Map.get(body, "usage", %{})

      # Extract finish reason
      finish_reason = parse_finish_reason(Map.get(choice, "finish_reason"))

      response = %ReqLLM.Response{
        id: Map.get(body, "id", "unknown"),
        model: Map.get(body, "model", opts[:model] || "openai.gpt-oss-20b-1:0"),
        context: %ReqLLM.Context{messages: [message]},
        message: message,
        stream?: false,
        stream: nil,
        usage: parse_usage(usage),
        finish_reason: finish_reason,
        provider_meta: Map.drop(body, ["choices", "usage", "id", "model"])
      }

      {:ok, response}
    else
      :error -> {:error, "Invalid OpenAI response format"}
      [] -> {:error, "Empty choices array"}
    end
  end

  defp parse_message(%{"role" => role, "content" => content} = data) do
    # Handle tool calls if present (new ToolCall pattern)
    tool_calls =
      if tc_data = Map.get(data, "tool_calls") do
        Enum.map(tc_data, fn tc ->
          ReqLLM.ToolCall.new(
            tc["id"],
            get_in(tc, ["function", "name"]),
            get_in(tc, ["function", "arguments"]) || "{}"
          )
        end)
      end

    # Build content parts
    content_parts =
      if content && content != "" do
        [%ReqLLM.Message.ContentPart{type: :text, text: content}]
      else
        []
      end

    # Build message with tool_calls if present
    message = %ReqLLM.Message{
      role: String.to_existing_atom(role),
      content: content_parts
    }

    if tool_calls do
      %{message | tool_calls: tool_calls}
    else
      message
    end
  end

  defp parse_usage(%{"prompt_tokens" => input, "completion_tokens" => output}) do
    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: input + output
    }
  end

  defp parse_usage(_), do: nil

  defp parse_finish_reason("stop"), do: :stop
  defp parse_finish_reason("length"), do: :length
  defp parse_finish_reason("tool_calls"), do: :tool_calls
  defp parse_finish_reason(_), do: :stop

  @doc """
  Parses a streaming chunk for OpenAI models.

  Unwraps the Bedrock-specific encoding then delegates to standard OpenAI
  SSE event parsing.
  """
  def parse_stream_chunk(chunk, opts) when is_map(chunk) do
    # First, unwrap the Bedrock AWS event stream encoding
    with {:ok, event} <- AmazonBedrock.Response.unwrap_stream_chunk(chunk) do
      # Create a model struct for SSE decoding
      model = %ReqLLM.Model{
        provider: :openai,
        model: opts[:model] || "bedrock-openai"
      }

      # Delegate to standard OpenAI SSE event parsing
      # Event is already parsed JSON, wrap in SSE format expected by decoder
      sse_event = %{data: event}

      chunks = Defaults.default_decode_sse_event(sse_event, model)

      # Return first chunk if any, or nil
      case chunks do
        [chunk | _] -> {:ok, chunk}
        [] -> {:ok, nil}
      end
    end
  rescue
    e -> {:error, "Failed to parse stream chunk: #{inspect(e)}"}
  end

  @doc """
  Extracts usage metadata from the response body.

  Delegates to standard OpenAI usage extraction.
  """
  def extract_usage(body, _model) when is_map(body) do
    case Map.get(body, "usage") do
      %{"prompt_tokens" => input, "completion_tokens" => output} = usage ->
        {:ok,
         %{
           input_tokens: input,
           output_tokens: output,
           total_tokens: Map.get(usage, "total_tokens", input + output)
         }}

      _ ->
        {:error, :no_usage}
    end
  end

  def extract_usage(_, _), do: {:error, :no_usage}
end

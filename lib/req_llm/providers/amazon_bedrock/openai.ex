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
  Returns whether this model family supports toolChoice in Bedrock Converse API.
  """
  def supports_converse_tool_choice?, do: false

  @doc """
  Formats a ReqLLM context into OpenAI request format for Bedrock.

  Uses standard OpenAI Chat Completions format with Bedrock-specific restrictions:
  - Tool response messages must NOT include the "name" field (Bedrock limitation)

  For :object operations, creates a synthetic "structured_output" tool to
  leverage tool calling for structured JSON output.
  """
  def format_request(model_id, context, opts) do
    operation = opts[:operation]

    # For :object operation, inject the structured_output tool
    {context, opts} =
      if operation == :object do
        prepare_structured_output_context(context, opts)
      else
        {context, opts}
      end

    # Get tools from context if available
    tools = Map.get(context, :tools, [])

    # Create a minimal request struct to use default OpenAI encoding
    temp_request =
      Req.new(method: :post, url: URI.parse("https://example.com/temp"))
      |> Map.put(:body, {:json, %{}})
      |> Map.put(
        :options,
        Map.new(
          [
            model: model_id,
            context: context,
            operation: operation || :chat,
            tools: tools
          ] ++ Keyword.drop(opts, [:model, :tools, :operation])
        )
      )

    encoded_request = Defaults.default_encode_body(temp_request)

    # Parse the body and remove "name" field from tool messages
    # Bedrock OpenAI models don't support the "name" field in tool responses
    body = Jason.decode!(encoded_request.body)

    updated_body =
      if messages = body["messages"] do
        Map.put(body, "messages", strip_name_from_tool_messages(messages))
      else
        body
      end

    updated_body
  end

  # Strip the "name" field from tool role messages (Bedrock OpenAI limitation)
  defp strip_name_from_tool_messages(messages) when is_list(messages) do
    Enum.map(messages, fn message ->
      if message["role"] == "tool" do
        Map.delete(message, "name")
      else
        message
      end
    end)
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

    # Update opts to force tool choice (OpenAI format)
    updated_opts =
      opts
      |> Keyword.put(:tools, [structured_output_tool | Keyword.get(opts, :tools, [])])
      |> Keyword.put(
        :tool_choice,
        %{type: "function", function: %{name: "structured_output"}}
      )

    {updated_context, updated_opts}
  end

  @doc """
  Parses OpenAI response from Bedrock into ReqLLM format.

  Manually decodes the OpenAI Chat Completions format.

  For :object operations, extracts the structured output from the tool call.
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

      # For :object operation, extract structured output from tool call
      final_response =
        if opts[:operation] == :object do
          extract_and_set_object(response)
        else
          response
        end

      {:ok, final_response}
    else
      :error -> {:error, "Invalid OpenAI response format"}
      [] -> {:error, "Empty choices array"}
    end
  end

  # Extract structured output from tool call (same logic as native Anthropic provider)
  defp extract_and_set_object(response) do
    extracted_object =
      response
      |> ReqLLM.Response.tool_calls()
      |> ReqLLM.ToolCall.find_args("structured_output")

    %{response | object: extracted_object}
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

  defp parse_usage(%{"prompt_tokens" => input, "completion_tokens" => output} = usage) do
    cached = get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0

    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: input + output,
      cached_tokens: cached,
      reasoning_tokens: 0
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
  SSE event parsing. Handles Bedrock-specific usage metrics.
  """
  def parse_stream_chunk(chunk, opts) when is_map(chunk) do
    # First, unwrap the Bedrock AWS event stream encoding
    with {:ok, event} <- AmazonBedrock.Response.unwrap_stream_chunk(chunk) do
      # Check for Bedrock-specific usage metrics first
      case event do
        %{"amazon-bedrock-invocationMetrics" => metrics} ->
          usage = %{
            input_tokens: Map.get(metrics, "inputTokenCount", 0),
            output_tokens: Map.get(metrics, "outputTokenCount", 0),
            cached_tokens: 0,
            reasoning_tokens: 0
          }

          {:ok, ReqLLM.StreamChunk.meta(%{usage: usage})}

        _ ->
          # Create a model struct for SSE decoding
          model_id = opts[:model] || "bedrock-openai"

          model = %LLMDB.Model{
            id: model_id,
            provider: :openai
          }

          # Delegate to standard OpenAI SSE event parsing
          # Event is already parsed JSON, wrap in SSE format expected by decoder
          sse_event = %{data: event}

          chunks = Defaults.default_decode_stream_event(sse_event, model)

          # Return first chunk if any, or nil
          case chunks do
            [chunk | _] -> {:ok, chunk}
            [] -> {:ok, nil}
          end
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
        cached = get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0

        {:ok,
         %{
           input_tokens: input,
           output_tokens: output,
           total_tokens: Map.get(usage, "total_tokens", input + output),
           cached_tokens: cached,
           reasoning_tokens: 0
         }}

      _ ->
        {:error, :no_usage}
    end
  end

  def extract_usage(_, _), do: {:error, :no_usage}
end

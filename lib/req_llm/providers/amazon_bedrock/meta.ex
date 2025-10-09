defmodule ReqLLM.Providers.AmazonBedrock.Meta do
  @moduledoc """
  Meta Llama model family support for AWS Bedrock.

  Handles Meta's Llama models (Llama 3, 3.1, 3.2, 3.3, 4) on AWS Bedrock.

  Unlike OpenAI and Anthropic which have canonical APIs, Meta doesn't provide
  a commercial API. This implementation handles Bedrock's native Llama format
  which uses a prompt-based interface rather than messages.
  """

  alias ReqLLM.Providers.AmazonBedrock

  @doc """
  Formats a ReqLLM context into Meta Llama request format for Bedrock.

  Converts structured messages into Llama 3's prompt format:
  - System messages use <|start_header_id|>system<|end_header_id|>
  - User messages use <|start_header_id|>user<|end_header_id|>
  - Assistant messages use <|start_header_id|>assistant<|end_header_id|>
  """
  def format_request(_model_id, context, opts) do
    prompt = format_llama_prompt(context.messages)

    %{
      "prompt" => prompt
    }
    |> maybe_add_param("max_gen_len", opts[:max_tokens])
    |> maybe_add_param("temperature", opts[:temperature])
    |> maybe_add_param("top_p", opts[:top_p])
  end

  defp maybe_add_param(map, _key, nil), do: map
  defp maybe_add_param(map, key, value), do: Map.put(map, key, value)

  @doc """
  Formats messages into Llama 3 prompt format.

  Format: <|begin_of_text|><|start_header_id|>role<|end_header_id|>
  content<|eot_id|>
  """
  def format_llama_prompt(messages) do
    formatted =
      messages
      |> Enum.map_join("", &format_message/1)

    # Start with begin token and end with assistant header
    "<|begin_of_text|>#{formatted}<|start_header_id|>assistant<|end_header_id|>\n\n"
  end

  defp format_message(%{role: role, content: content}) when is_binary(content) do
    "<|start_header_id|>#{role}<|end_header_id|>\n\n#{content}<|eot_id|>"
  end

  defp format_message(%{role: role, content: content}) when is_list(content) do
    # Handle content blocks (text, images, etc.)
    text =
      content
      |> Enum.filter(&(&1.type == :text))
      |> Enum.map_join("\n", & &1.text)

    "<|start_header_id|>#{role}<|end_header_id|>\n\n#{text}<|eot_id|>"
  end

  @doc """
  Parses Meta Llama response from Bedrock into ReqLLM format.
  """
  def parse_response(body, opts) when is_map(body) do
    with {:ok, generation} <- Map.fetch(body, "generation"),
         {:ok, usage} <- extract_usage(body, nil) do
      # Create assistant message with text content
      message = %ReqLLM.Message{
        role: :assistant,
        content: [
          %ReqLLM.Message.ContentPart{
            type: :text,
            text: generation
          }
        ]
      }

      # Create context with the new message
      context = %ReqLLM.Context{
        messages: [message]
      }

      response = %ReqLLM.Response{
        id: generate_id(),
        model: opts[:model] || "meta.llama",
        context: context,
        message: message,
        stream?: false,
        stream: nil,
        usage: usage,
        finish_reason: parse_stop_reason(body["stop_reason"]),
        provider_meta:
          Map.drop(body, [
            "generation",
            "prompt_token_count",
            "generation_token_count",
            "stop_reason"
          ])
      }

      {:ok, response}
    else
      :error -> {:error, "Invalid response format"}
      {:error, _} -> {:error, "Invalid response format"}
    end
  end

  defp parse_stop_reason("stop"), do: :stop
  defp parse_stop_reason("length"), do: :length
  defp parse_stop_reason(_), do: :stop

  defp generate_id do
    "llama-#{:erlang.system_time(:millisecond)}-#{:rand.uniform(1000)}"
  end

  @doc """
  Parses a streaming chunk for Meta Llama models.

  Each chunk contains a "generation" field with the next text segment.
  """
  def parse_stream_chunk(chunk, _opts) when is_map(chunk) do
    # First, unwrap the Bedrock AWS event stream encoding
    with {:ok, event} <- AmazonBedrock.Response.unwrap_stream_chunk(chunk) do
      case event do
        %{"generation" => text} when is_binary(text) and text != "" ->
          {:ok, ReqLLM.StreamChunk.text(text)}

        %{"stop_reason" => reason} ->
          normalized_reason = parse_stop_reason(reason)
          {:ok, ReqLLM.StreamChunk.meta(%{finish_reason: normalized_reason, terminal?: true})}

        %{"amazon-bedrock-invocationMetrics" => metrics} ->
          usage = %{
            input_tokens: Map.get(metrics, "inputTokenCount", 0),
            output_tokens: Map.get(metrics, "outputTokenCount", 0)
          }

          {:ok, ReqLLM.StreamChunk.meta(%{usage: usage})}

        _ ->
          {:ok, nil}
      end
    end
  rescue
    e -> {:error, "Failed to parse stream chunk: #{inspect(e)}"}
  end

  @doc """
  Extracts usage metadata from the response body.
  """
  def extract_usage(body, _model) when is_map(body) do
    case {Map.get(body, "prompt_token_count"), Map.get(body, "generation_token_count")} do
      {input, output} when is_integer(input) and is_integer(output) ->
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

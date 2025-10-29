defmodule ReqLLM.Providers.AmazonBedrock.Meta do
  @moduledoc """
  Meta Llama model family support for AWS Bedrock.

  Handles Meta's Llama models (Llama 3, 3.1, 3.2, 3.3, 4) on AWS Bedrock.

  This module acts as a thin adapter between Bedrock's AWS-specific wrapping
  and Meta's native Llama format. It delegates to `ReqLLM.Providers.Meta` for
  all format conversion and response parsing.

  ## Native Format vs OpenAI-Compatible

  Unlike most cloud providers (Azure, Google Cloud Vertex AI) and self-hosted
  deployments (vLLM, Ollama) which wrap Llama in OpenAI-compatible APIs,
  **AWS Bedrock uses Meta's native format** with `prompt`, `max_gen_len`,
  and `generation` fields.

  This is why this module delegates to the generic `ReqLLM.Providers.Meta`
  rather than `ReqLLM.Providers.OpenAI`.
  """

  alias ReqLLM.Providers.AmazonBedrock
  alias ReqLLM.Providers.Meta

  @doc """
  Returns whether this model family supports toolChoice in Bedrock Converse API.
  """
  def supports_converse_tool_choice?, do: false

  @doc """
  Formats a ReqLLM context into Meta Llama request format for Bedrock.

  Delegates to the generic Meta provider and returns the formatted request.
  """
  def format_request(_model_id, context, opts) do
    Meta.format_request(context, opts)
  end

  @doc """
  Formats messages into Llama 3 prompt format.

  Delegates to the generic Meta provider. Exposed for testing.
  """
  def format_llama_prompt(messages) do
    Meta.format_llama_prompt(messages)
  end

  @doc """
  Parses Meta Llama response from Bedrock into ReqLLM format.

  Delegates to the generic Meta provider for parsing.
  """
  def parse_response(body, opts) when is_map(body) do
    Meta.parse_response(body, opts)
  end

  @doc """
  Parses a streaming chunk for Meta Llama models.

  Each chunk contains a "generation" field with the next text segment.
  Unwraps Bedrock's AWS Event Stream encoding before processing.
  """
  def parse_stream_chunk(chunk, _opts) when is_map(chunk) do
    # First, unwrap the Bedrock AWS event stream encoding
    with {:ok, event} <- AmazonBedrock.Response.unwrap_stream_chunk(chunk) do
      case event do
        %{"generation" => text} when is_binary(text) and text != "" ->
          {:ok, ReqLLM.StreamChunk.text(text)}

        %{"stop_reason" => reason} ->
          normalized_reason = Meta.parse_stop_reason(reason)
          {:ok, ReqLLM.StreamChunk.meta(%{finish_reason: normalized_reason, terminal?: true})}

        %{"amazon-bedrock-invocationMetrics" => metrics} ->
          input = Map.get(metrics, "inputTokenCount", 0)
          output = Map.get(metrics, "outputTokenCount", 0)

          usage = %{
            input_tokens: input,
            output_tokens: output,
            total_tokens: input + output,
            cached_tokens: 0,
            reasoning_tokens: 0
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

  Delegates to the generic Meta provider for usage extraction.
  """
  def extract_usage(body, _model) when is_map(body) do
    Meta.extract_usage(body)
  end

  def extract_usage(_, _), do: {:error, :no_usage}
end

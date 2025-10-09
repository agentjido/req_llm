defmodule ReqLLM.Providers.AmazonBedrock.OpenAI do
  @moduledoc """
  OpenAI model family support for AWS Bedrock.

  Handles OpenAI's OSS models (gpt-oss-120b, gpt-oss-20b) on AWS Bedrock.

  This module acts as a thin adapter between Bedrock's AWS-specific wrapping
  and OpenAI's native Chat Completions format. Unlike Anthropic, OpenAI on
  Bedrock uses the exact same format as native OpenAI, so this mostly delegates
  to Provider.Defaults.
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

  Delegates to the standard OpenAI response decoder.
  """
  def parse_response(body, opts) when is_map(body) do
    # Create a minimal request with required options for decoder
    fake_req = %Req.Request{
      options:
        Map.new(
          model: opts[:model] || "openai.gpt-oss-20b-1:0",
          context: opts[:context] || %ReqLLM.Context{messages: []},
          stream: false,
          operation: :chat
        )
    }

    # Create a fake response struct for default decoder
    fake_resp = %{
      status: 200,
      body: body
    }

    # Use standard OpenAI response decoding
    # Returns {req, %{resp | body: merged_response}} where merged_response is the ReqLLM.Response
    case Defaults.default_decode_response({fake_req, fake_resp}) do
      {_req, %{body: %ReqLLM.Response{} = response}} -> {:ok, response}
      {_req, other} -> {:error, other}
    end
  end

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

defmodule ReqLLM.Providers.AmazonBedrock.Anthropic do
  @moduledoc """
  Anthropic model family support for AWS Bedrock.

  Handles Claude models (Claude 3 Sonnet, Haiku, Opus, etc.) on AWS Bedrock.

  This module acts as a thin adapter between Bedrock's AWS-specific wrapping
  and Anthropic's native message format. It delegates to the native Anthropic
  modules for all format conversion.
  """

  alias ReqLLM.Providers.AmazonBedrock
  alias ReqLLM.Providers.Anthropic

  @doc """
  Formats a ReqLLM context into Anthropic request format for Bedrock.

  Delegates to the native Anthropic.Context module and adds Bedrock-specific
  version parameter.

  For :object operations, creates a synthetic "structured_output" tool to
  leverage Claude's tool-calling for structured JSON output.
  """
  def format_request(_model_id, context, opts) do
    operation = opts[:operation]

    # For :object operation, we need to inject the structured_output tool
    {context, opts} =
      if operation == :object do
        prepare_structured_output_context(context, opts)
      else
        {context, opts}
      end

    # Create a fake model struct for Anthropic.Context.encode_request
    model = %{model: opts[:model] || "claude-3-sonnet"}

    # Delegate to native Anthropic context encoding
    body = Anthropic.Context.encode_request(context, model)

    # Remove model field - Bedrock specifies model in URL, not body
    body = Map.delete(body, :model)

    # Add Bedrock-specific parameters
    # Use 4096 for :object operations (need more tokens for structured output), 1024 otherwise
    default_max_tokens = if operation == :object, do: 4096, else: 1024

    body
    |> Map.put(:anthropic_version, "bedrock-2023-05-31")
    |> maybe_add_param(:max_tokens, opts[:max_tokens] || default_max_tokens)
    |> maybe_add_param(:temperature, opts[:temperature])
    |> maybe_add_param(:top_p, opts[:top_p])
    |> maybe_add_param(:top_k, opts[:top_k])
    |> maybe_add_param(:stop_sequences, opts[:stop_sequences])
    |> maybe_add_thinking(opts)
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

  defp maybe_add_param(body, _key, nil), do: body
  defp maybe_add_param(body, key, value), do: Map.put(body, key, value)

  # Add extended thinking configuration for native Anthropic endpoint
  # Note: pre_validate_options already extracted reasoning params and added to additional_model_request_fields
  # For Converse API, but native endpoint uses different format
  defp maybe_add_thinking(body, opts) do
    # Check if additional_model_request_fields has reasoning_config (from pre_validate_options)
    case get_in(opts, [:additional_model_request_fields, :reasoning_config]) do
      %{type: "enabled", budget_tokens: budget} ->
        Map.put(body, :thinking, %{type: "enabled", budget_tokens: budget})

      _ ->
        body
    end
  end

  @doc """
  Parses Anthropic response from Bedrock into ReqLLM format.

  Delegates to the native Anthropic.Response module.

  For :object operations, extracts the structured output from the tool call.
  """
  def parse_response(body, opts) when is_map(body) do
    # Create a model struct for Anthropic.Response.decode_response
    model = %ReqLLM.Model{
      provider: :anthropic,
      model: Map.get(body, "model", opts[:model] || "bedrock-anthropic")
    }

    # Delegate to native Anthropic response decoding
    case Anthropic.Response.decode_response(body, model) do
      {:ok, response} ->
        # For :object operation, extract structured output from tool call
        final_response =
          if opts[:operation] == :object do
            extract_and_set_object(response)
          else
            response
          end

        {:ok, final_response}

      error ->
        error
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

  @doc """
  Parses a streaming chunk for Anthropic models.

  Unwraps the Bedrock-specific encoding then delegates to native Anthropic
  SSE event parsing.
  """
  def parse_stream_chunk(chunk, opts) when is_map(chunk) do
    # First, unwrap the Bedrock AWS event stream encoding
    with {:ok, event} <- AmazonBedrock.Response.unwrap_stream_chunk(chunk) do
      # Create a model struct for Anthropic.Response.decode_sse_event
      model = %ReqLLM.Model{
        provider: :anthropic,
        model: opts[:model] || "bedrock-anthropic"
      }

      # Delegate to native Anthropic SSE event parsing
      # decode_sse_event expects %{data: event_data} format
      chunks = Anthropic.Response.decode_sse_event(%{data: event}, model)

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

  Delegates to the native Anthropic provider.
  """
  def extract_usage(body, model) do
    # Delegate to native Anthropic extract_usage
    Anthropic.extract_usage(body, model)
  end
end

defmodule ReqLLM.Providers.GoogleVertex.OpenAICompat do
  @moduledoc """
  OpenAI-compatible model family support for Google Vertex AI.

  Handles third-party MaaS (Model-as-a-Service) models on Vertex AI that use
  the OpenAI Chat Completions API format.

  Currently supports:
  - GLM models (zai-org/glm-4.7-maas)
  - OpenAI OSS models (openai/gpt-oss-120b-maas, openai/gpt-oss-20b-maas)
  - Other future MaaS models using OpenAI-compatible format

  These models are accessed via Vertex AI's `endpoints/openapi/chat/completions`
  endpoint and use standard OpenAI Chat Completions request/response format.
  The model ID (e.g., `zai-org/glm-4.7-maas`) is included in the request body.
  """

  alias ReqLLM.Provider.Defaults

  @doc """
  Formats a ReqLLM context into OpenAI Chat Completions request format.

  Uses the standard OpenAI-compatible body builder from Provider.Defaults.
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

    # Build OpenAI-compatible request body using Defaults helper
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

    Defaults.default_build_body(temp_request)
  end

  @doc """
  Parses OpenAI Chat Completions response from Vertex AI into ReqLLM format.

  Delegates to Provider.Defaults for standard OpenAI response decoding.
  """
  def parse_response(body, %LLMDB.Model{} = model, opts) when is_map(body) do
    {:ok, response} = Defaults.decode_response_body_openai_format(body, model)

    # Merge with input context to preserve conversation history
    input_context = opts[:context] || %ReqLLM.Context{messages: []}
    merged_response = ReqLLM.Context.merge_response(input_context, response)

    # For :object operation, extract structured output from tool call
    final_response =
      if opts[:operation] == :object do
        extract_and_set_object(merged_response)
      else
        merged_response
      end

    {:ok, final_response}
  end

  @doc """
  Extracts usage metadata from the response body.

  OpenAI-compatible format has standard usage field.
  """
  def extract_usage(body, model) do
    Defaults.default_extract_usage(body, model)
  end

  @doc """
  Decodes Server-Sent Events for streaming responses.

  Uses the standard OpenAI SSE format decoder from Provider.Defaults.
  """
  def decode_stream_event(event, model) do
    Defaults.default_decode_stream_event(event, model)
  end

  # Extract structured output from tool call for :object operations
  defp extract_and_set_object(response) do
    extracted_object =
      response
      |> ReqLLM.Response.tool_calls()
      |> ReqLLM.ToolCall.find_args("structured_output")

    %{response | object: extracted_object}
  end

  # Create the synthetic structured_output tool for :object operations
  defp prepare_structured_output_context(context, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    structured_output_tool =
      ReqLLM.Tool.new!(
        name: "structured_output",
        description: "Generate structured output matching the provided schema",
        parameter_schema: compiled_schema.schema,
        callback: fn _args -> {:ok, "structured output generated"} end
      )

    existing_tools = Map.get(context, :tools, [])
    updated_context = Map.put(context, :tools, [structured_output_tool | existing_tools])

    updated_opts =
      opts
      |> Keyword.put(:tools, [structured_output_tool | Keyword.get(opts, :tools, [])])
      |> Keyword.put(
        :tool_choice,
        %{type: "function", function: %{name: "structured_output"}}
      )

    {updated_context, updated_opts}
  end
end

defmodule ReqLLM.Providers.GoogleVertex.Gemini do
  @moduledoc """
  Gemini model family support for Google Vertex AI.

  Handles Gemini models (gemini-2.5-flash, gemini-2.5-pro, etc.) on Google Vertex AI.

  This module acts as a thin adapter between Vertex AI's GCP infrastructure
  and Google's native Gemini format. It delegates to the native Google provider
  for all format conversion, with one critical difference: Vertex AI Gemini API
  is stricter and requires sanitizing function call IDs.

  ## Critical Quirks

  Vertex AI Gemini has stricter validation than the direct Google API:

  1. Rejects the "id" field in functionCall parts - we strip these IDs

  ## Features

  - Extended thinking/reasoning via `google_thinking_budget`
  - Context caching (90% discount on cached tokens!)
  - Google Search grounding via `google_grounding: %{enable: true}`
  - All standard Gemini options (safety settings, etc.)
  """

  alias ReqLLM.Providers.Google

  @doc """
  Formats a ReqLLM context into Gemini request format for Vertex AI.

  Delegates to the native Google provider's encoding logic, then applies
  shared tool call ID compatibility policy.
  """
  def format_request(model_id, context, opts) do
    {provider_opts, rest} = Keyword.pop(opts, :provider_options, [])
    provider_model = Keyword.get(opts, :provider_model)

    opts_map =
      rest
      |> Keyword.merge(provider_opts)
      |> Map.new()
      |> Map.merge(%{context: context, model: model_id})

    temp_request =
      Req.new(method: :post, url: URI.parse("https://example.com/temp"))
      |> Map.put(:body, {:json, %{}})
      |> Map.put(:options, opts_map)

    %Req.Request{body: encoded_body} = Google.encode_body(temp_request)

    body = Jason.decode!(encoded_body)

    ReqLLM.ToolCallIdCompat.apply_body(
      ReqLLM.Providers.GoogleVertex,
      opts[:operation] || :chat,
      provider_model || %{id: model_id, provider_model_id: model_id, provider: :google_vertex},
      body,
      opts
    )
  end

  @doc """
  Parses a Gemini response from Vertex AI into ReqLLM format.

  Delegates to the native Google provider's response parsing logic.
  """
  def parse_response(body, model, opts) do
    operation = opts[:operation]
    context = opts[:context] || %ReqLLM.Context{messages: []}

    temp_req = %Req.Request{
      options: %{
        context: context,
        model: model.model,
        operation: operation,
        stream: false
      }
    }

    temp_resp = %Req.Response{
      status: 200,
      body: body
    }

    {_req, decoded_resp} = Google.decode_response({temp_req, temp_resp})

    case decoded_resp do
      %Req.Response{body: parsed_body} ->
        {:ok, parsed_body}

      error ->
        {:error, error}
    end
  end

  @doc """
  Extracts usage information from Gemini response.

  Gemini responses include usageMetadata with token counts including cached tokens.
  """
  def extract_usage(body, model) do
    Google.extract_usage(body, model)
  end

  @doc """
  Decodes Server-Sent Events for streaming responses.

  Gemini uses the same SSE format as the native Google provider.
  """
  def decode_stream_event(event, model) do
    Google.decode_stream_event(event, model)
  end
end

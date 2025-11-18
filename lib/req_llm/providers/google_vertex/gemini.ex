defmodule ReqLLM.Providers.GoogleVertex.Gemini do
  @moduledoc """
  Gemini model family support for Google Vertex AI.

  Handles Gemini models (gemini-2.5-flash, gemini-2.5-pro, etc.) on Google Vertex AI.

  This module acts as a thin adapter between Vertex AI's GCP infrastructure
  and Google's native Gemini format. It delegates to the native Google provider
  for all format conversion, with one critical difference: Vertex AI Gemini API
  is stricter and requires sanitizing function call IDs.

  ## Critical Quirk

  Vertex AI Gemini rejects the "id" field in functionCall parts, while the
  direct Google API includes it. We must strip these IDs before sending requests.

  ## Features

  - Extended thinking/reasoning via `google_thinking_budget`
  - Context caching (90% discount on cached tokens!)
  - All standard Gemini options (safety, grounding, etc.)
  """

  alias ReqLLM.Providers.Google

  @doc """
  Formats a ReqLLM context into Gemini request format for Vertex AI.

  Delegates to the native Google provider's encoding logic, then sanitizes
  function call IDs which Vertex AI rejects.
  """
  def format_request(model_id, context, opts) do
    # Create a temporary request structure that mimics what Google.encode_body expects
    # Use Req.new() to properly initialize the opaque request structure
    temp_request =
      Req.new(method: :post, url: URI.parse("https://example.com/temp"))
      |> Map.put(:body, {:json, %{}})
      |> Map.put(:options, opts |> Map.new() |> Map.merge(%{context: context, model: model_id}))

    # Let Google provider encode the body
    %Req.Request{body: encoded_body} = Google.encode_body(temp_request)

    # Decode the JSON body
    body = Jason.decode!(encoded_body)

    # Vertex AI has stricter validation: remove "id" from functionCall parts
    sanitize_function_calls(body)
  end

  # Removes "id" field from functionCall parts in contents
  # Vertex AI Gemini API does not accept this field, while direct Google API includes it
  defp sanitize_function_calls(%{"contents" => contents} = body) when is_list(contents) do
    sanitized_contents =
      Enum.map(contents, fn
        %{"parts" => parts} = content when is_list(parts) ->
          sanitized_parts =
            Enum.map(parts, fn
              %{"functionCall" => fc} = part ->
                Map.put(part, "functionCall", Map.delete(fc, "id"))

              other ->
                other
            end)

          Map.put(content, "parts", sanitized_parts)

        other ->
          other
      end)

    Map.put(body, "contents", sanitized_contents)
  end

  defp sanitize_function_calls(body), do: body

  @doc """
  Parses a Gemini response from Vertex AI into ReqLLM format.

  Delegates to the native Google provider's response parsing logic.
  """
  def parse_response(body, model, opts) do
    operation = opts[:operation]
    context = opts[:context] || %ReqLLM.Context{messages: []}

    # Create temporary request/response pair that mimics what Google.decode_response expects
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

    # Let Google provider decode the response
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
  def extract_usage(body, _model) do
    case body do
      %{"usageMetadata" => usage} ->
        {:ok,
         %{
           input_tokens: Map.get(usage, "promptTokenCount", 0),
           output_tokens: Map.get(usage, "candidatesTokenCount", 0),
           reasoning_tokens: Map.get(usage, "thinkingTokenCount"),
           cached_tokens: Map.get(usage, "cachedContentTokenCount")
         }}

      _ ->
        {:error, :no_usage_data}
    end
  end

  @doc """
  Decodes Server-Sent Events for streaming responses.

  Gemini uses the same SSE format as the native Google provider.
  """
  def decode_stream_event(event, model) do
    # Delegate directly to Google provider's decode_stream_event
    Google.decode_stream_event(event, model)
  end
end

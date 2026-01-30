defmodule ReqLLM.Providers.Azure.ResponsesAPI do
  @moduledoc """
  Azure Responses API adapter.

  Thin wrapper around `ReqLLM.Providers.OpenAI.ResponsesAPI` that delegates all
  encoding/decoding to the native OpenAI implementation.

  ## Endpoint

  Azure Responses API uses: `{base_url}/responses?api-version=...`
  where base_url ends with `/openai` (model specified in request body, not in URL path)

  ## Supported Models

  Models with `"api": "responses"` in their metadata:
  - codex-mini, gpt-5-codex, gpt-5.1-codex-mini
  - Future models that use the Responses API format
  """

  alias ReqLLM.Providers.OpenAI.ResponsesAPI

  @doc """
  Formats a request body for the Azure Responses API.

  Delegates to the native OpenAI Responses API encoder.
  """
  def format_request(model_id, context, opts) when is_list(opts) do
    provider_opts = opts[:provider_options] || []

    fake_request = %{
      options: %{
        model: model_id,
        id: model_id,
        context: context,
        stream: opts[:stream],
        max_tokens: opts[:max_tokens],
        max_output_tokens: opts[:max_output_tokens],
        max_completion_tokens: opts[:max_completion_tokens],
        tools: opts[:tools],
        tool_choice: opts[:tool_choice],
        provider_options: provider_opts
      }
    }

    ResponsesAPI.build_body(fake_request)
  end

  @doc """
  Parses a Responses API response body.

  Delegates to the native OpenAI ResponsesAPI decoder.
  """
  def parse_response(body, model, opts) do
    fake_request = %{
      options: %{
        model: model.id,
        operation: opts[:operation],
        context: opts[:context],
        compiled_schema: opts[:compiled_schema]
      }
    }

    fake_response = %{status: 200, body: body}

    case ResponsesAPI.decode_response({fake_request, fake_response}) do
      {_req, %{body: %ReqLLM.Response{} = response}} ->
        {:ok, response}

      {_req, %ReqLLM.Error.API.Response{} = error} ->
        {:error, error}

      {_req, response} when is_map(response) ->
        {:ok, response}
    end
  end

  @doc """
  Decodes Server-Sent Events for streaming responses.

  Delegates to the native OpenAI ResponsesAPI.
  """
  def decode_stream_event(event, model) do
    {chunks, _state} = decode_stream_event(event, model, nil)
    chunks
  end

  def decode_stream_event(event, model, state) do
    ResponsesAPI.decode_stream_event(event, model, state)
  end

  @doc """
  Azure Responses API models do not support embeddings.
  """
  def format_embedding_request(_model_id, _text, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "Responses API models do not support embeddings."
     )}
  end
end

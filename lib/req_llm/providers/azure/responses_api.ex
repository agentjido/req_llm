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

  ## Reasoning Effort

  Accepts the top-level `:reasoning_effort` option (`:minimal | :low | :medium |
  :high | :xhigh | :none` or the equivalent string) and forwards it to the
  Responses API as `"reasoning": {"effort": <level>}`.

  ## Parallel Tool Calls

  Accepts `parallel_tool_calls` via the top-level option, or via
  `provider_options[:openai_parallel_tool_calls]` (Azure's preferred key) or
  `provider_options[:parallel_tool_calls]`. Forwarded to the Responses API
  as the top-level `"parallel_tool_calls"` boolean. An explicit `false` is
  preserved.
  """

  alias ReqLLM.Providers.OpenAI.ResponsesAPI

  @doc """
  Formats a request body for the Azure Responses API.

  Delegates to the native OpenAI Responses API encoder.
  """
  def format_request(model_id, context, opts) when is_list(opts) do
    provider_opts = opts[:provider_options] || []

    parallel_tool_calls =
      fetch_first([
        {opts, :parallel_tool_calls},
        {provider_opts, :openai_parallel_tool_calls},
        {provider_opts, :parallel_tool_calls}
      ])

    fake_request = %{
      options: %{
        model: model_id,
        id: model_id,
        context: context,
        stream: opts[:stream],
        max_tokens: opts[:max_tokens],
        max_output_tokens: opts[:max_output_tokens],
        max_completion_tokens: opts[:max_completion_tokens],
        reasoning_effort: opts[:reasoning_effort],
        parallel_tool_calls: parallel_tool_calls,
        tools: opts[:tools],
        tool_choice: opts[:tool_choice],
        provider_options: provider_opts
      }
    }

    ResponsesAPI.build_body(fake_request)
  end

  defp fetch_first([]), do: nil

  defp fetch_first([{source, key} | rest]) do
    case Keyword.fetch(source, key) do
      {:ok, value} -> value
      :error -> fetch_first(rest)
    end
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
  Extracts usage from Azure Responses API payloads.
  """
  def extract_usage(body, _model) do
    parsed_body = ReqLLM.Provider.Utils.ensure_parsed_body(body)

    case parsed_body do
      %{"usage" => usage} ->
        input_tokens = usage["input_tokens"] || 0
        output_tokens = usage["output_tokens"] || 0
        total_tokens = usage["total_tokens"] || input_tokens + output_tokens

        reasoning_tokens =
          usage["reasoning_tokens"] ||
            get_in(usage, ["output_tokens_details", "reasoning_tokens"]) ||
            get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) || 0

        cached_tokens =
          get_in(usage, ["input_tokens_details", "cached_tokens"]) ||
            get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0

        {:ok,
         %{
           input_tokens: input_tokens,
           output_tokens: output_tokens,
           total_tokens: total_tokens,
           cached_tokens: cached_tokens,
           reasoning_tokens: reasoning_tokens
         }}

      _ ->
        {:error, :no_usage_found}
    end
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

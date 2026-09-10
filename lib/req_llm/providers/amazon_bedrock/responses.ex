defmodule ReqLLM.Providers.AmazonBedrock.Responses do
  @moduledoc """
  Bedrock Mantle adapter for the OpenAI Responses API wire format.

  Request encoding and response decoding delegate to the native OpenAI
  Responses implementation. Bedrock remains responsible for routing and
  authentication.
  """

  alias ReqLLM.Providers.OpenAI.ResponsesAPI

  def format_request(model_id, context, opts) when is_list(opts) do
    openai_model = openai_model(model_id)

    opts
    |> Map.new()
    |> Map.merge(%{
      model: openai_model.id,
      id: openai_model.id,
      context: context,
      req_llm_model: openai_model
    })
    |> then(&%{options: &1})
    |> ResponsesAPI.build_body()
    |> Map.drop([:model, "model"])
    |> Map.put(:model, model_id)
  end

  def parse_response(body, opts) do
    model = openai_model(opts[:model])

    fake_request = %{
      options: %{
        model: model.id,
        req_llm_model: model,
        operation: opts[:operation],
        context: opts[:context],
        compiled_schema: opts[:compiled_schema]
      }
    }

    case ResponsesAPI.decode_response({fake_request, %{status: 200, body: body}}) do
      {_request, %{body: %ReqLLM.Response{} = response}} -> {:ok, response}
      {_request, %ReqLLM.Error.API.Response{} = error} -> {:error, error}
      {_request, response} when is_map(response) -> {:ok, response}
    end
  end

  def decode_stream_event(event, model, state) do
    ResponsesAPI.decode_stream_event(event, as_openai_model(model), state)
  end

  def extract_usage(body, _model) do
    parsed_body = ReqLLM.Provider.Utils.ensure_parsed_body(body)

    case parsed_body do
      %{"usage" => usage} ->
        input_tokens = usage["input_tokens"] || 0
        output_tokens = usage["output_tokens"] || 0

        {:ok,
         %{
           input_tokens: input_tokens,
           output_tokens: output_tokens,
           total_tokens: usage["total_tokens"] || input_tokens + output_tokens,
           cached_tokens: get_in(usage, ["input_tokens_details", "cached_tokens"]) || 0,
           reasoning_tokens:
             get_in(usage, ["output_tokens_details", "reasoning_tokens"]) || 0
         }}

      _ ->
        {:error, :no_usage_found}
    end
  end

  defp openai_model(model_id) do
    %LLMDB.Model{
      provider: :openai,
      id: openai_model_id(model_id),
      model: openai_model_id(model_id)
    }
  end

  defp as_openai_model(%LLMDB.Model{} = model) do
    model_id = model.provider_model_id || model.id
    %{model | provider: :openai, id: openai_model_id(model_id), provider_model_id: nil}
  end

  defp openai_model_id(model_id) do
    model_id
    |> strip_region_prefix()
    |> String.replace_prefix("openai.", "")
  end

  defp strip_region_prefix(model_id) do
    case String.split(model_id, ".", parts: 2) do
      [region, rest] when region in ~w(us eu ap apac ca au jp us-gov global) -> rest
      _ -> model_id
    end
  end
end

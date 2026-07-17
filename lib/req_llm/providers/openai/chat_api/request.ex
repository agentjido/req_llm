defmodule ReqLLM.Providers.OpenAI.ChatAPI.Request do
  @moduledoc false

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  alias ReqLLM.Providers.OpenAI.AdapterHelpers

  @doc false
  @spec build_body(ReqLLM.Context.t(), String.t(), keyword(), atom()) :: map()
  def build_body(context, model_name, opts, operation) do
    request =
      Req.new(method: :post, url: URI.parse("https://example.com/temp"))
      |> Map.put(:body, {:json, %{}})
      |> Map.put(
        :options,
        Map.new([model: model_name, context: context, operation: operation] ++ opts)
      )

    body = %{} = ReqLLM.Provider.Defaults.default_build_body(request)
    request_options = opts |> Map.new() |> Map.to_list()

    case operation do
      :embedding ->
        add_embedding_options(body, request_options)

      _ ->
        body
        |> add_token_limits(model_name, request_options)
        |> add_stream_options(request_options)
        |> add_reasoning_effort(request_options)
        |> add_service_tier(request_options)
        |> add_verbosity(request_options)
        |> add_response_format(request_options)
        |> add_parallel_tool_calls(request_options)
        |> add_logprobs(request_options)
        |> add_audio_output(request_options)
        |> AdapterHelpers.translate_tool_choice_format()
        |> AdapterHelpers.add_strict_to_tools()
    end
  end

  defp add_embedding_options(body, request_options) do
    body
    |> maybe_put(:dimensions, request_options[:dimensions])
    |> maybe_put(:encoding_format, request_options[:encoding_format])
  end

  defp add_token_limits(body, model_name, request_options) do
    body =
      Map.drop(body, [
        :max_tokens,
        :max_completion_tokens,
        "max_tokens",
        "max_completion_tokens"
      ])

    if completion_token_limit_model?(model_name) do
      maybe_put(
        body,
        :max_completion_tokens,
        request_options[:max_completion_tokens] || request_options[:max_tokens]
      )
    else
      body
      |> maybe_put(:max_tokens, request_options[:max_tokens])
      |> maybe_put(:max_completion_tokens, request_options[:max_completion_tokens])
    end
  end

  defp completion_token_limit_model?("gpt-5-chat-latest"), do: false
  defp completion_token_limit_model?(<<"gpt-5", _::binary>>), do: true
  defp completion_token_limit_model?(<<"gpt-4.1", _::binary>>), do: true
  defp completion_token_limit_model?(<<"o1", _::binary>>), do: true
  defp completion_token_limit_model?(<<"o3", _::binary>>), do: true
  defp completion_token_limit_model?(<<"o4", _::binary>>), do: true
  defp completion_token_limit_model?(_model_name), do: false

  defp add_stream_options(body, request_options) do
    if request_options[:stream] do
      maybe_put(body, :stream_options, %{include_usage: true})
    else
      body
    end
  end

  defp add_reasoning_effort(body, request_options) do
    maybe_put(body, :reasoning_effort, request_options[:reasoning_effort])
  end

  defp add_service_tier(body, request_options) do
    provider_options = provider_options(request_options)
    service_tier = request_options[:service_tier] || provider_options[:service_tier]
    maybe_put(body, :service_tier, service_tier)
  end

  defp add_verbosity(body, request_options) do
    provider_options = provider_options(request_options)
    maybe_put(body, :verbosity, normalize_verbosity(provider_options[:verbosity]))
  end

  defp normalize_verbosity(nil), do: nil
  defp normalize_verbosity(verbosity) when is_atom(verbosity), do: Atom.to_string(verbosity)
  defp normalize_verbosity(verbosity) when is_binary(verbosity), do: verbosity

  defp add_response_format(body, request_options) do
    provider_options = provider_options(request_options)
    response_format = provider_options[:response_format]

    normalized =
      case response_format do
        %{type: "json_schema", json_schema: %{schema: schema}} = format when is_list(schema) ->
          put_in(format, [:json_schema, :schema], ReqLLM.Schema.to_json(schema))

        %{"type" => "json_schema", "json_schema" => %{"schema" => schema}} = format
        when is_list(schema) ->
          json_schema = Map.put(format["json_schema"], "schema", ReqLLM.Schema.to_json(schema))
          %{format | "json_schema" => json_schema}

        _other ->
          response_format
      end

    body
    |> Map.drop(["response_format", :response_format])
    |> maybe_put(:response_format, normalized)
  end

  defp add_parallel_tool_calls(body, request_options) do
    provider_options = provider_options(request_options)
    AdapterHelpers.add_parallel_tool_calls(body, request_options, provider_options)
  end

  defp add_logprobs(body, request_options) do
    provider_options = provider_options(request_options)

    body
    |> maybe_put(:logprobs, provider_options[:openai_logprobs])
    |> maybe_put(:top_logprobs, provider_options[:openai_top_logprobs])
  end

  defp add_audio_output(body, request_options) do
    provider_options = provider_options(request_options)

    body
    |> maybe_put(:modalities, request_options[:modalities] || provider_options[:modalities])
    |> maybe_put(:audio, request_options[:audio] || provider_options[:audio])
  end

  defp provider_options(request_options) do
    case request_options[:provider_options] do
      nil -> []
      options when is_list(options) -> options
      options when is_map(options) -> Map.to_list(options)
    end
  end
end

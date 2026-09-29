defmodule ReqLLM.Providers.OpenAI.MultiAgent do
  @moduledoc false

  alias ReqLLM.Providers.OpenAI.Astra

  @beta "responses_multi_agent=v1"

  def configuration(opts, model_name) do
    opts = Map.new(opts)
    provider_opts = Map.new(opts[:provider_options] || [])
    value = opts[:multi_agent] || provider_opts[:multi_agent]
    normalize(value, model_name, Map.merge(provider_opts, opts))
  end

  def headers(opts, model_name) do
    case configuration(opts, model_name) do
      %{"enabled" => true} -> [{"OpenAI-Beta", @beta}]
      _ -> []
    end
  end

  def put_http_header(request, model_name) do
    Enum.reduce(headers(request.options, model_name), request, fn {key, value}, req ->
      existing = Req.Request.get_header(req, key)
      values = Enum.uniq(existing ++ [value])
      Req.Request.put_header(req, key, Enum.join(values, ","))
    end)
  end

  defp normalize(nil, _model, _opts), do: nil

  defp normalize(value, model, opts) when is_map(value) or is_list(value) do
    value = Map.new(value, fn {key, val} -> {to_string(key), val} end)

    if Enum.any?(Map.keys(value), &(&1 not in ~w(enabled max_concurrent_subagents))) do
      Astra.invalid!("Unsupported multi_agent option")
    end

    unless is_boolean(value["enabled"]) do
      Astra.invalid!("multi_agent.enabled must be a boolean")
    end

    limit = value["max_concurrent_subagents"]

    if limit != nil and (not is_integer(limit) or limit < 1) do
      Astra.invalid!("multi_agent.max_concurrent_subagents must be a positive integer")
    end

    if value["enabled"] do
      unless supported_model?(model),
        do: Astra.invalid!("Multi-agent requires GPT-6.1 Sol or GPT-5.6")

      if opts[:operation] == :compact, do: Astra.invalid!("Multi-agent does not support compact")

      if opts[:reasoning_summary] != nil do
        Astra.invalid!("Multi-agent does not support reasoning summaries")
      end
    end

    value
  end

  defp normalize(_value, _model, _opts),
    do: Astra.invalid!("multi_agent must be a map or keyword list")

  defp supported_model?("gpt-6.1-sol"), do: true
  defp supported_model?(<<"gpt-6.1-sol-", _::binary>>), do: true
  defp supported_model?("gpt-5.6"), do: true
  defp supported_model?(<<"gpt-5.6-", _::binary>>), do: true
  defp supported_model?(_), do: false
end

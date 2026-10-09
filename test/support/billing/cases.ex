defmodule ReqLLM.Test.Billing.Cases do
  @moduledoc false

  @cases [
    {"basic_usage", [:anthropic, :openai, :openrouter], ["cold"]},
    {"cache_5m", [:anthropic], ["cold", "warm"]},
    {"cache_1h", [:anthropic], ["cold", "warm"]},
    {"mixed_cache_ttl", [:anthropic], ["cold", "warm"]},
    {"client_function", [:openai], ["call", "result"]},
    {"hosted_web_search", [:openai], ["search"]},
    {"returned_service_tier", [:openai], ["default", "auto", "flex"]},
    {"long_context", [:openai], ["short", "long"]},
    {"compact_unknown", [:openai], ["compact"]},
    {"websocket_usage", [:openai], ["response"]}
  ]
  @layers ~w(capture normalization pricing pipeline adversarial)

  def all do
    Enum.map(@cases, fn {id, providers, phases} ->
      %{id: id, providers: providers, phases: phases, layers: @layers}
    end)
  end

  def layers, do: @layers

  def fetch!(id) do
    Enum.find(all(), &(&1.id == id)) || raise ArgumentError, "unknown billing case: #{id}"
  end

  def select(ids, models, mode \\ "both") do
    modes =
      case mode do
        "both" -> ~w(buffered streamed)
        value when value in ~w(buffered streamed) -> [value]
        _ -> raise ArgumentError, "mode must be buffered, streamed, or both"
      end

    for id <- ids, model <- models, stream_mode <- modes do
      spec = fetch!(id)
      [provider, _model_id] = String.split(model, ":", parts: 2)
      provider = String.to_existing_atom(provider)

      unless provider in spec.providers,
        do: raise(ArgumentError, "#{id} does not support #{model}")

      if id == "compact_unknown" and stream_mode == "streamed",
        do: raise(ArgumentError, "compact_unknown is buffered only")

      if id == "websocket_usage" and stream_mode == "buffered",
        do: raise(ArgumentError, "websocket_usage is streamed only")

      %{case_id: id, model: model, mode: stream_mode, phases: spec.phases}
    end
  end
end

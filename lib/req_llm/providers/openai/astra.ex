defmodule ReqLLM.Providers.OpenAI.Astra do
  @moduledoc false

  alias ReqLLM.Error.Invalid.Parameter
  alias ReqLLM.Providers.OpenAI.AdapterHelpers

  @efforts ~w(low medium high xhigh max)

  def validate_options!(model, opts) do
    provider_opts = Keyword.get(opts, :provider_options, [])
    options = Keyword.merge(provider_opts, Keyword.delete(opts, :provider_options))

    if AdapterHelpers.gpt6_astra_model?(model.id) do
      effort = options[:reasoning_effort]
      if effort not in [nil, :default, "default"], do: validate_effort!(effort)

      if options[:openai_logprobs] == true or
           not is_nil(options[:openai_top_logprobs]) or
           "message.output_text.logprobs" in (options[:include] || []) do
        invalid!("GPT-6 Astra does not support logprobs")
      end
    end

    Enum.each(options[:tools] || [], &validate_tool!(&1, model.id))
    opts
  end

  def validate_effort!(effort) do
    if not (is_atom(effort) or is_binary(effort)) or to_string(effort) not in @efforts do
      invalid!("GPT-6 Astra reasoning effort must be low, medium, high, xhigh, or max")
    end

    to_string(effort)
  end

  def validate_body!(body, model_name) do
    if AdapterHelpers.gpt6_astra_model?(model_name) do
      effort = get_in(body, ["reasoning", "effort"])
      if effort, do: validate_effort!(effort)

      if Enum.any?(["temperature", "top_p", "top_logprobs", "logprobs"], &Map.has_key?(body, &1)) or
           "message.output_text.logprobs" in (body["include"] || []) do
        invalid!("GPT-6 Astra does not support sampling parameters or logprobs")
      end
    end

    Enum.each(body["tools"] || [], &validate_tool!(&1, model_name))
    validate_configuration!(body, model_name)
    body
  end

  defp validate_configuration!(%{"input" => input} = body, model_name) when is_list(input) do
    updates = Enum.filter(input, &configuration_update?/1)

    if updates != [] do
      require_astra!(model_name, "configuration_update")

      if body["context_management"] not in [nil, []] or
           body["truncation"] not in [nil, "disabled"] or
           get_in(body, ["multi_agent", "enabled"]) == true do
        invalid!(
          "Configuration updates require single-agent mode without automatic compaction or truncation"
        )
      end

      Enum.each(updates, &validate_effort!(get_in(&1, ["reasoning", "effort"])))

      if input
         |> Enum.chunk_every(2, 1, :discard)
         |> Enum.any?(fn [a, b] -> configuration_update?(a) and configuration_update?(b) end) do
        invalid!("Adjacent configuration updates are not supported")
      end
    end
  end

  defp validate_configuration!(_body, _model_name), do: :ok

  defp configuration_update?(%{"type" => "configuration_update"}), do: true
  defp configuration_update?(_item), do: false

  def async_metadata(item) do
    case Map.fetch(item, "async") do
      {:ok, value} when is_boolean(value) -> %{async: value}
      _ -> if is_boolean(item[:async]), do: %{async: item[:async]}, else: %{}
    end
  end

  def put_async(body, source) do
    case Map.fetch(async_metadata(source), :async) do
      {:ok, value} -> Map.put(body, "async", value)
      :error -> body
    end
  end

  def configuration_items(%ReqLLM.Message{role: :user, metadata: metadata}, model_name) do
    case Map.get(metadata, :openai_reasoning_effort) ||
           Map.get(metadata, "openai_reasoning_effort") do
      nil ->
        []

      effort ->
        require_astra!(model_name, "configuration_update")

        [
          %{
            "type" => "configuration_update",
            "reasoning" => %{"effort" => validate_effort!(effort)}
          }
        ]
    end
  end

  def configuration_items(_message, _model_name), do: []

  def require_astra!(model_name, feature) do
    unless AdapterHelpers.gpt6_astra_model?(model_name) do
      invalid!("#{feature} requires GPT-6 Astra")
    end
  end

  def validate_tool!(%ReqLLM.Tool{} = tool, model_name) do
    tool |> ReqLLM.Tool.provider_options(:openai) |> validate_async!(model_name, "function")
  end

  def validate_tool!(tool, model_name) when is_map(tool) do
    function = tool["function"] || tool[:function] || %{}
    type = tool["type"] || tool[:type] || "function"
    validate_async!(tool, model_name, to_string(type))
    validate_async!(function, model_name, "function")
  end

  def validate_tool!(_tool, _model_name), do: :ok

  defp validate_async!(options, model_name, type) do
    value = Map.get(options, :async, Map.get(options, "async"))

    if Map.has_key?(options, :async) or Map.has_key?(options, "async") do
      unless is_boolean(value), do: invalid!("Tool async must be a boolean")
      unless type == "function", do: invalid!("Async tool encoding supports function tools only")
      require_astra!(model_name, "Async tools")
    end
  end

  def invalid!(message), do: raise(Parameter.exception(parameter: message))
end

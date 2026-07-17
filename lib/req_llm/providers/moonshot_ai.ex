defmodule ReqLLM.Providers.MoonshotAI do
  @moduledoc """
  Moonshot AI provider using the OpenAI-compatible Chat Completions API.

  Kimi K3 always reasons at maximum effort. Its fixed sampling parameters are
  omitted from requests, and generated-token limits use `max_completion_tokens`.
  The shared OpenAI-compatible codec preserves `reasoning_content` for streaming,
  multi-turn conversations, and tool-call round trips.

  ## Configuration

      MOONSHOT_API_KEY=your-api-key

  ## Examples

      ReqLLM.generate_text("moonshotai:kimi-k3", "Hello!")

      ReqLLM.stream_text("moonshotai:kimi-k3", "Explain linear attention",
        reasoning_effort: :max
      )
  """

  use ReqLLM.Provider,
    id: :moonshotai,
    default_base_url: "https://api.moonshot.ai/v1",
    default_env_key: "MOONSHOT_API_KEY"

  use ReqLLM.Provider.Defaults

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  @default_receive_timeout 300_000
  @fixed_sampling_options [:temperature, :top_p, :n, :presence_penalty, :frequency_penalty]
  @fixed_sampling_values %{
    temperature: 1.0,
    top_p: 0.95,
    n: 1,
    presence_penalty: 0,
    frequency_penalty: 0
  }
  @canonical_reasoning_efforts [:minimal, :low, :medium, :high, :xhigh, :max, :none]

  @provider_schema [
    max_completion_tokens: [
      type: :pos_integer,
      doc: "Maximum generated tokens. Kimi K3 uses max_completion_tokens."
    ],
    thinking: [
      type: :map,
      doc: "K2.x thinking configuration. It is rejected for Kimi K3."
    ]
  ]

  @doc false
  def display_name, do: "Moonshot AI"

  @impl ReqLLM.Provider
  def translate_options(_operation, model, opts) do
    if kimi_k3?(model) do
      opts
      |> translate_token_limit()
      |> strip_fixed_sampling_options()
      |> strip_thinking_option()
      |> normalize_reasoning_effort()
      |> normalize_tool_choice()
      |> put_default_receive_timeout()
      |> then(fn {translated, warnings} -> {translated, Enum.reverse(warnings)} end)
    else
      {opts, []}
    end
  end

  @impl ReqLLM.Provider
  def build_body(request) do
    body = ReqLLM.Provider.Defaults.default_build_body(request)
    model = request.private[:req_llm_model]

    if kimi_k3?(model) or request.options[:model] == "kimi-k3" do
      body
      |> Map.drop(@fixed_sampling_options ++ [:max_tokens, :thinking])
      |> maybe_put(:max_completion_tokens, token_limit(request.options))
      |> Map.put(:reasoning_effort, "max")
    else
      body
    end
  end

  defp translate_token_limit(opts) do
    {max_tokens, opts} = Keyword.pop(opts, :max_tokens)

    cond do
      is_nil(max_tokens) ->
        {opts, []}

      Keyword.has_key?(opts, :max_completion_tokens) ->
        {opts,
         [
           "Kimi K3 uses max_completion_tokens; ignored max_tokens because max_completion_tokens is set."
         ]}

      true ->
        {Keyword.put(opts, :max_completion_tokens, max_tokens),
         ["Kimi K3 uses max_completion_tokens; translated max_tokens."]}
    end
  end

  defp strip_fixed_sampling_options({opts, warnings}) do
    Enum.reduce(@fixed_sampling_options, {opts, warnings}, fn option, {acc, messages} ->
      fixed_value = Map.fetch!(@fixed_sampling_values, option)

      case Keyword.fetch(acc, option) do
        {:ok, value} when value == fixed_value ->
          {Keyword.delete(acc, option), messages}

        {:ok, _value} ->
          {Keyword.delete(acc, option),
           ["Kimi K3 fixes #{option}; removed it from the request." | messages]}

        :error ->
          {acc, messages}
      end
    end)
  end

  defp strip_thinking_option({opts, warnings}) do
    {thinking, opts} = Keyword.pop(opts, :thinking)
    {provider_options, opts} = Keyword.pop(opts, :provider_options, [])
    {nested_thinking, provider_options} = pop_option(provider_options, :thinking)
    opts = put_provider_options(opts, provider_options)
    thinking = thinking || nested_thinking

    if is_nil(thinking) do
      {opts, warnings}
    else
      {opts,
       ["Kimi K3 always reasons; removed the K2.x thinking option from the request." | warnings]}
    end
  end

  defp normalize_reasoning_effort({opts, warnings}) do
    {effort, opts} = Keyword.pop(opts, :reasoning_effort)

    case effort do
      nil ->
        {Keyword.put(opts, :reasoning_effort, :max), warnings}

      :default ->
        {Keyword.put(opts, :reasoning_effort, :max), warnings}

      "max" ->
        {Keyword.put(opts, :reasoning_effort, :max), warnings}

      :max ->
        {Keyword.put(opts, :reasoning_effort, :max), warnings}

      effort when effort in @canonical_reasoning_efforts ->
        {Keyword.put(opts, :reasoning_effort, :max),
         [
           "Kimi K3 only supports reasoning_effort :max; translated #{inspect(effort)} to :max."
           | warnings
         ]}

      effort ->
        {Keyword.put(opts, :reasoning_effort, :max),
         [
           "Kimi K3 only supports reasoning_effort :max; replaced #{inspect(effort)} with :max."
           | warnings
         ]}
    end
  end

  defp normalize_tool_choice({opts, warnings}) do
    case Keyword.get(opts, :tool_choice) do
      choice when is_map(choice) ->
        {Keyword.put(opts, :tool_choice, "required"),
         [
           "Kimi K3 does not support named tool choice with reasoning; translated it to required."
           | warnings
         ]}

      _choice ->
        {opts, warnings}
    end
  end

  defp put_default_receive_timeout({opts, warnings}) do
    {Keyword.put_new(opts, :receive_timeout, @default_receive_timeout), warnings}
  end

  defp token_limit(options) do
    options[:max_completion_tokens] || options[:max_tokens]
  end

  defp pop_option(options, key) when is_list(options), do: Keyword.pop(options, key)

  defp pop_option(options, key) when is_map(options) do
    value = Map.get(options, key) || Map.get(options, to_string(key))
    {value, options |> Map.delete(key) |> Map.delete(to_string(key))}
  end

  defp pop_option(_options, _key), do: {nil, []}

  defp put_provider_options(opts, provider_options)
       when provider_options in [[], %{}],
       do: opts

  defp put_provider_options(opts, provider_options),
    do: Keyword.put(opts, :provider_options, provider_options)

  defp kimi_k3?(%LLMDB.Model{} = model) do
    model_id = model.provider_model_id || model.model || model.id
    model_id == "kimi-k3" or model.id == "moonshotai:kimi-k3"
  end

  defp kimi_k3?(_model), do: false
end

defmodule ReqLLM.Providers.Mistral do
  @moduledoc """
  Mistral provider built on the official Mistral chat completions and embeddings APIs.

  ## Implementation

  Uses the shared OpenAI-compatible defaults for request/response handling with
  targeted overrides for Mistral-specific request fields:

  - `random_seed` instead of `seed`
  - `parallel_tool_calls`
  - `prompt_mode`
  - `safe_prompt`
  - `prediction`
  - `metadata`
  - `response_format`
  - `output_dimension` and `output_dtype` for embeddings

  ## Configuration

      MISTRAL_API_KEY=your-api-key

  ## Examples

      ReqLLM.generate_text("mistral:mistral-small-latest", "Hello!")

      ReqLLM.generate_embedding(
        "mistral:mistral-embed",
        "hello world",
        dimensions: 512
      )
  """

  use ReqLLM.Provider,
    id: :mistral,
    default_base_url: "https://api.mistral.ai/v1",
    default_env_key: "MISTRAL_API_KEY"

  use ReqLLM.Provider.Defaults

  import ReqLLM.Provider.Utils, only: [maybe_put: 3, maybe_put_skip: 4]

  @provider_schema [
    random_seed: [
      type: :non_neg_integer,
      doc: "Seed for deterministic sampling"
    ],
    metadata: [
      type: {:or, [:map, :keyword_list]},
      doc: "Arbitrary request metadata"
    ],
    prediction: [
      type: {:or, [:map, :keyword_list]},
      doc: "Expected content prediction object"
    ],
    response_format: [
      type: {:or, [:map, :keyword_list]},
      doc: "Response format configuration"
    ],
    parallel_tool_calls: [
      type: :boolean,
      doc: "Whether to allow multiple tool calls in parallel"
    ],
    prompt_mode: [
      type: {:or, [{:in, [:reasoning]}, {:in, ["reasoning"]}]},
      doc: "Prompt mode for reasoning models"
    ],
    safe_prompt: [
      type: :boolean,
      doc: "Whether to inject Mistral's safety prompt"
    ],
    output_dimension: [
      type: :pos_integer,
      doc: "Requested output embedding dimensions"
    ],
    output_dtype: [
      type: {:in, ["float", "int8", "uint8", "binary", "ubinary"]},
      doc: "Output embedding data type"
    ]
  ]

  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts) do
    warnings = []

    {reasoning_effort, opts} = Keyword.pop(opts, :reasoning_effort)

    {opts, warnings} =
      case normalize_reasoning_effort(reasoning_effort) do
        nil when is_nil(reasoning_effort) or reasoning_effort == :default ->
          {opts, warnings}

        nil ->
          warning =
            "Mistral supports reasoning_effort values :high and :none; #{inspect(reasoning_effort)} will be ignored"

          {Keyword.delete(opts, :reasoning_effort), [warning | warnings]}

        normalized ->
          {Keyword.put(opts, :reasoning_effort, normalized), warnings}
      end

    {prompt_mode, opts} = Keyword.pop(opts, :prompt_mode)

    {opts, warnings} =
      case normalize_prompt_mode(prompt_mode) do
        nil when is_nil(prompt_mode) ->
          {opts, warnings}

        nil ->
          warning =
            "Mistral supports prompt_mode value :reasoning; #{inspect(prompt_mode)} will be ignored"

          {Keyword.delete(opts, :prompt_mode), [warning | warnings]}

        normalized ->
          {Keyword.put(opts, :prompt_mode, normalized), warnings}
      end

    {opts, Enum.reverse(warnings)}
  end

  @impl ReqLLM.Provider
  def build_body(request) do
    case request.options[:operation] do
      :embedding -> build_embedding_body(request)
      _ -> build_chat_body(request)
    end
  end

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    processed_opts =
      ReqLLM.Provider.Options.process_stream!(
        __MODULE__,
        opts[:operation] || :chat,
        model,
        context,
        opts
      )

    base_url = ReqLLM.Provider.Options.effective_base_url(__MODULE__, model, processed_opts)
    opts_with_base_url = Keyword.put(processed_opts, :base_url, base_url)

    ReqLLM.Provider.Defaults.default_attach_stream(
      __MODULE__,
      model,
      context,
      opts_with_base_url,
      finch_name
    )
  end

  defp build_chat_body(request) do
    ReqLLM.Provider.Defaults.default_build_body(request)
    |> Map.delete(:seed)
    |> maybe_put(:random_seed, provider_option(request, :random_seed) || request.options[:seed])
    |> maybe_put(:metadata, normalized_provider_map(request, :metadata))
    |> maybe_put(:prediction, normalized_provider_map(request, :prediction))
    |> maybe_put(:response_format, normalized_provider_map(request, :response_format))
    |> maybe_put_skip(
      :parallel_tool_calls,
      provider_option(request, :parallel_tool_calls),
      [true]
    )
    |> maybe_put(:prompt_mode, normalize_prompt_mode(provider_option(request, :prompt_mode)))
    |> maybe_put(
      :reasoning_effort,
      normalize_reasoning_effort(request.options[:reasoning_effort])
    )
    |> maybe_put_skip(:safe_prompt, provider_option(request, :safe_prompt), [false])
  end

  defp build_embedding_body(request) do
    %{
      model: request.options[:model],
      input: request.options[:text]
    }
    |> maybe_put(:encoding_format, request.options[:encoding_format])
    |> maybe_put(
      :output_dimension,
      provider_option(request, :output_dimension) ||
        request.options[:dimensions]
    )
    |> maybe_put(:output_dtype, provider_option(request, :output_dtype))
    |> maybe_put(:metadata, normalized_provider_map(request, :metadata))
  end

  defp provider_option(request, key) do
    provider_opts = request.options[:provider_options] || []

    cond do
      option_present?(request.options, key) ->
        option_value(request.options, key)

      option_present?(provider_opts, key) ->
        option_value(provider_opts, key)

      true ->
        nil
    end
  end

  defp normalized_provider_map(request, key) do
    request
    |> provider_option(key)
    |> normalize_nested_value()
  end

  defp normalize_prompt_mode(:reasoning), do: "reasoning"
  defp normalize_prompt_mode("reasoning"), do: "reasoning"
  defp normalize_prompt_mode(_), do: nil

  defp normalize_reasoning_effort(:high), do: "high"
  defp normalize_reasoning_effort("high"), do: "high"
  defp normalize_reasoning_effort(:none), do: "none"
  defp normalize_reasoning_effort("none"), do: "none"
  defp normalize_reasoning_effort(_), do: nil

  defp normalize_nested_value(value) when is_list(value) do
    if Keyword.keyword?(value) do
      Map.new(value, fn {key, nested} ->
        {normalize_nested_key(key), normalize_nested_value(nested)}
      end)
    else
      Enum.map(value, &normalize_nested_value/1)
    end
  end

  defp normalize_nested_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      {normalize_nested_key(key), normalize_nested_value(nested)}
    end)
  end

  defp normalize_nested_value(value), do: value

  defp normalize_nested_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_nested_key(key), do: key

  defp option_present?(value, key) when is_list(value), do: Keyword.has_key?(value, key)

  defp option_present?(value, key) when is_map(value) do
    Map.has_key?(value, key) or Map.has_key?(value, Atom.to_string(key))
  end

  defp option_present?(_value, _key), do: false

  defp option_value(value, key) when is_list(value), do: Keyword.fetch!(value, key)

  defp option_value(value, key) when is_map(value) do
    cond do
      Map.has_key?(value, key) -> Map.fetch!(value, key)
      Map.has_key?(value, Atom.to_string(key)) -> Map.fetch!(value, Atom.to_string(key))
      true -> nil
    end
  end

  defp option_value(_value, _key), do: nil
end

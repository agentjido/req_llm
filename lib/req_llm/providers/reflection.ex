defmodule ReqLLM.Providers.Reflection do
  @moduledoc """
  Reflection AI provider for text, tool calls, and structured output.

  Uses the Chat Completions API at `https://api.reflection.ai/openai/v1`.
  Set `REFLECTION_API_KEY` or pass the `:api_key` option to authenticate.

  Beam always reasons. Supported `:reasoning_effort` values are `:low`,
  `:medium`, `:high`, `:xhigh`, and `:max`. Omit the option, or use `:default`,
  to use the organization's default. `:max_tokens` maps to
  `:max_completion_tokens`, which includes reasoning and answer tokens.

  Each previous assistant message must contain reasoning. Reuse the response
  context to preserve it, including after tool calls and streamed responses.

      model = ReqLLM.model!(%{provider: :reflection, id: "Beam-1.0-501B-A23B"})
      ReqLLM.generate_text(model, "Hello!", reasoning_effort: :low)

  See the Reflection provider guide for details.
  """

  use ReqLLM.Provider,
    id: :reflection,
    default_base_url: "https://api.reflection.ai/openai/v1",
    default_env_key: "REFLECTION_API_KEY"

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  @reasoning_efforts [:low, :medium, :high, :xhigh, :max]
  @unsupported_options [:top_k, :reasoning_token_budget, :stop, :seed]

  @provider_schema [
    max_completion_tokens: [
      type: :pos_integer,
      doc: "Maximum output tokens, including reasoning and answer tokens."
    ],
    parallel_tool_calls: [type: :boolean, doc: "Allow parallel calls when tools are supplied."],
    response_format: [type: :map, doc: "Text, JSON object, or JSON schema response format."],
    safety_identifier: [type: :string, doc: "Stable end-user identifier for abuse monitoring."]
  ]

  @doc "Returns the provider name."
  def display_name, do: "Reflection AI"

  @impl ReqLLM.Provider
  def prepare_request(operation, model_spec, input, opts) when operation in [:chat, :object] do
    with {:ok, context} <- ReqLLM.Context.normalize(input),
         :ok <- validate_context(context) do
      case operation do
        :chat ->
          ReqLLM.Provider.Defaults.prepare_request(__MODULE__, :chat, model_spec, context, opts)

        :object ->
          ReqLLM.Provider.Defaults.prepare_json_schema_object_request(
            __MODULE__,
            model_spec,
            context,
            opts
          )
      end
    end
  end

  def prepare_request(operation, _model_spec, _input, _opts),
    do: {:error, unsupported_operation(operation)}

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    operation = opts[:operation] || :chat

    with :ok <- validate_operation(operation),
         :ok <- validate_context(context) do
      super(model, context, opts, finch_name)
    end
  rescue
    error -> {:error, error}
  end

  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts) do
    {max_tokens, opts} = Keyword.pop(opts, :max_tokens)
    {effort, opts} = Keyword.pop(opts, :reasoning_effort)

    warnings =
      if max_tokens && opts[:max_completion_tokens] && max_tokens != opts[:max_completion_tokens],
        do: ["Reflection uses max_completion_tokens; ignored max_tokens because both are set."],
        else: []

    opts =
      opts
      |> put_token_limit(max_tokens)
      |> put_reasoning_effort(effort)
      |> Keyword.put_new(:receive_timeout, 300_000)

    Enum.reduce(@unsupported_options, {opts, warnings}, fn key, {options, messages} ->
      case Keyword.pop(options, key) do
        {nil, remaining} ->
          {remaining, messages}

        {_value, remaining} ->
          {remaining, messages ++ ["Reflection does not support #{key}; removed it."]}
      end
    end)
  end

  @impl ReqLLM.Provider
  def build_body(request) do
    body = ReqLLM.Provider.Defaults.default_build_body(request)
    validate_messages!(body.messages)

    body
    |> Map.update!(
      :messages,
      &Enum.map(&1, fn message -> Map.drop(message, [:metadata, :reasoning_details]) end)
    )
    |> Map.drop([:max_tokens | @unsupported_options])
    |> maybe_put(
      :max_completion_tokens,
      request.options[:max_completion_tokens] || request.options[:max_tokens]
    )
    |> maybe_put(:reasoning_effort, wire_effort(request.options[:reasoning_effort]))
    |> maybe_put(:safety_identifier, request.options[:safety_identifier])
    |> put_parallel_tool_calls(request.options[:parallel_tool_calls])
    |> ReqLLM.Providers.OpenAI.AdapterHelpers.translate_tool_choice_format()
  end

  defp put_token_limit(opts, nil), do: opts
  defp put_token_limit(opts, limit), do: Keyword.put_new(opts, :max_completion_tokens, limit)

  defp put_reasoning_effort(opts, effort) when effort in [nil, :default], do: opts

  defp put_reasoning_effort(opts, effort) when effort in @reasoning_efforts,
    do: Keyword.put(opts, :reasoning_effort, effort)

  defp put_reasoning_effort(_opts, _effort) do
    raise ReqLLM.Error.Invalid.Parameter,
      parameter: "Reflection reasoning_effort must be low, medium, high, xhigh, max, or default"
  end

  defp wire_effort(effort) when effort in [nil, :default], do: nil
  defp wire_effort(effort) when effort in @reasoning_efforts, do: Atom.to_string(effort)

  defp put_parallel_tool_calls(%{tools: [_ | _]} = body, value),
    do: maybe_put(body, :parallel_tool_calls, value)

  defp put_parallel_tool_calls(body, _value), do: body

  defp validate_operation(operation) when operation in [:chat, :object], do: :ok
  defp validate_operation(operation), do: {:error, unsupported_operation(operation)}

  defp unsupported_operation(operation) do
    ReqLLM.Error.Invalid.Parameter.exception(
      parameter: "Reflection does not support operation #{inspect(operation)}"
    )
  end

  defp validate_context(context) do
    Enum.each(context.messages, fn message ->
      Enum.each(message.content || [], fn part ->
        unless part.type == :text or (message.role == :assistant and part.type == :thinking) do
          raise ReqLLM.Error.Invalid.Parameter, parameter: "Reflection accepts text input only"
        end
      end)
    end)

    %{messages: messages} =
      ReqLLM.Provider.Defaults.encode_context_to_openai_format(context, "")

    validate_messages!(messages)
    :ok
  rescue
    error in ReqLLM.Error.Invalid.Parameter -> {:error, error}
  end

  defp validate_messages!(messages) do
    Enum.each(messages, fn message ->
      if message.role == "assistant" and
           (not is_binary(message[:reasoning_content]) or message[:reasoning_content] == "") do
        raise ReqLLM.Error.Invalid.Parameter,
          parameter:
            "Reflection requires non-empty reasoning_content on each assistant message. " <>
              "Reuse the response context to preserve reasoning."
      end

      case message.content do
        parts when is_list(parts) ->
          if Enum.any?(parts, &(&1[:type] != "text")) do
            raise ReqLLM.Error.Invalid.Parameter, parameter: "Reflection accepts text input only"
          end

        _ ->
          :ok
      end
    end)
  end
end

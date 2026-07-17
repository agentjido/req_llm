defmodule ReqLLM.RequestPlan.Diagnostic do
  @moduledoc false

  alias ReqLLM.Error.Invalid.Parameter
  alias ReqLLM.RequestPlan

  @omitted_option_keys [
    :access_token,
    :api_key,
    :auth_file,
    :auth_mode,
    :chatgpt_account_id,
    :compiled_schema,
    :context,
    :fixture,
    :oauth_file,
    :oauth_http_options,
    :on_finch_request,
    :req_http_options,
    :text
  ]

  @sensitive_option_names ~w(authorization cookie credential header headers password secret token)

  @spec build(ReqLLM.model_input(), atom(), keyword()) ::
          {:ok, ReqLLM.plan_diagnostic()} | {:error, term()}
  def build(model_input, operation, opts \\ [])

  def build(model_input, operation, opts) when is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, plan} <- RequestPlan.build(model_input, operation, opts),
         {:ok, canonical_options} <- flatten_provider_options(plan.options),
         {:ok, translated_options, translation_warnings} <-
           translate_options(plan, canonical_options),
         redacted_warnings <-
           redact_warning_values(plan.warnings ++ translation_warnings, canonical_options),
         :ok <- enforce_warning_policy(plan.options, translation_warnings, canonical_options) do
      {:ok, diagnostic(plan, canonical_options, translated_options, redacted_warnings)}
    else
      {:error, error} -> {:error, sanitize_error(error)}
    end
  end

  def build(_model_input, _operation, _opts),
    do: invalid_parameter("options must be a keyword list")

  defp diagnostic(plan, canonical_options, translated_options, warnings) do
    %{
      model: %{provider: plan.provider, id: plan.model.id},
      operation: plan.operation,
      surface: plan.surface,
      transport: plan.transport,
      route: route(plan),
      options: %{
        canonical: option_keys(canonical_options),
        translated: option_keys(translated_options)
      },
      fallbacks: [],
      warnings: warnings
    }
  end

  defp validate_options(opts) do
    if Keyword.keyword?(opts), do: :ok, else: invalid_parameter("options must be a keyword list")
  end

  defp flatten_provider_options(opts) do
    {provider_options, canonical_options} = Keyword.pop(opts, :provider_options, [])

    if Keyword.keyword?(provider_options) do
      {:ok, Keyword.merge(canonical_options, provider_options)}
    else
      invalid_parameter(":provider_options must be a keyword list")
    end
  end

  defp translate_options(plan, opts) do
    with {:ok, prevalidated, prevalidation_warnings} <-
           apply_option_callback(plan.provider_module, :pre_validate_options, plan, opts),
         {:ok, translated, translation_warnings} <-
           apply_option_callback(plan.provider_module, :translate_options, plan, prevalidated) do
      {:ok, translated, prevalidation_warnings ++ translation_warnings}
    end
  end

  defp apply_option_callback(provider_module, callback, plan, opts) do
    if function_exported?(provider_module, callback, 3) do
      provider_module
      |> apply(callback, [option_operation(plan), plan.model, opts])
      |> normalize_option_callback_result()
    else
      {:ok, opts, []}
    end
  rescue
    _error -> translation_error()
  end

  defp option_operation(%RequestPlan{operation: :object}), do: :chat
  defp option_operation(%RequestPlan{operation: operation}), do: operation

  defp normalize_option_callback_result({opts, warnings})
       when is_list(opts) and is_list(warnings) do
    if Keyword.keyword?(opts) and Enum.all?(warnings, &is_binary/1) do
      {:ok, opts, warnings}
    else
      translation_error()
    end
  end

  defp normalize_option_callback_result(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: {:ok, opts, []}, else: translation_error()
  end

  defp normalize_option_callback_result(_result), do: translation_error()

  defp enforce_warning_policy(opts, warnings, canonical_options) do
    if warnings != [] and Keyword.get(opts, :on_unsupported, :warn) == :error do
      reason = warnings |> redact_warning_values(canonical_options) |> Enum.join("; ")

      {:error,
       ReqLLM.Error.Validation.Error.exception(
         tag: :unsupported_options,
         reason: reason,
         context: []
       )}
    else
      :ok
    end
  end

  defp route(%RequestPlan{surface: surface, api_module: api_module, transport: transport})
       when surface in [:openai_responses, :openai_chat_completions] do
    %{method: route_method(transport), path: api_module.path()}
  end

  defp route(%RequestPlan{surface: :anthropic_messages, transport: transport}) do
    %{method: route_method(transport), path: "/v1/messages"}
  end

  defp route_method(:websocket), do: :websocket
  defp route_method(_transport), do: :post

  defp option_keys(opts) do
    opts
    |> Keyword.keys()
    |> Enum.reject(&omitted_option_key?/1)
    |> Enum.uniq()
    |> Enum.sort_by(&to_string/1)
  end

  defp omitted_option_key?(key) when key in @omitted_option_keys, do: true

  defp omitted_option_key?(key) when is_atom(key) do
    name = Atom.to_string(key)

    name in @sensitive_option_names or
      String.ends_with?(name, ["_key", "_token", "_secret", "_password", "_header", "_headers"]) or
      String.contains?(name, "credential") or
      String.starts_with?(name, "auth_") or
      String.ends_with?(name, "_auth")
  end

  defp omitted_option_key?(_key), do: true

  defp redact_warning_values(warnings, options) do
    values = collect_binary_values(options)

    Enum.map(warnings, fn warning ->
      Enum.reduce(values, warning, &String.replace(&2, &1, "[REDACTED]"))
    end)
  end

  defp collect_binary_values(value) when is_binary(value),
    do: if(value == "", do: [], else: [value])

  defp collect_binary_values(value) when is_list(value) do
    Enum.flat_map(value, fn
      {_key, item} -> collect_binary_values(item)
      item -> collect_binary_values(item)
    end)
  end

  defp collect_binary_values(%_{} = struct),
    do: struct |> Map.from_struct() |> collect_binary_values()

  defp collect_binary_values(value) when is_map(value) do
    Enum.flat_map(value, fn {_key, item} -> collect_binary_values(item) end)
  end

  defp collect_binary_values(_value), do: []

  defp sanitize_error(%Parameter{parameter: parameter}) when is_binary(parameter) do
    safe_parameter =
      cond do
        String.contains?(parameter, "options must be a keyword list") ->
          "options must be a keyword list"

        String.contains?(parameter, "supports only :chat and :object") ->
          "request planning supports only :chat and :object operations"

        String.contains?(parameter, "wire protocol") ->
          "wire protocol is invalid for the resolved provider"

        String.contains?(parameter, ":stream must be a boolean") ->
          ":stream must be a boolean"

        String.contains?(parameter, "unsupported OpenAI stream transport") ->
          "unsupported OpenAI stream transport"

        String.contains?(parameter, "unsupported internal stream transport") ->
          "unsupported internal stream transport"

        String.contains?(parameter, "WebSocket transport is not supported") ->
          parameter

        true ->
          "request plan is invalid; verify provider, operation, and transport metadata"
      end

    Parameter.exception(parameter: safe_parameter)
  end

  defp sanitize_error(%ReqLLM.Error.Invalid.Provider{provider: provider}) do
    ReqLLM.Error.Invalid.Provider.exception(provider: provider)
  end

  defp sanitize_error(%ReqLLM.Error.Validation.Error{tag: :unsupported_options} = error),
    do: error

  defp sanitize_error(_error) do
    ReqLLM.Error.Validation.Error.exception(
      tag: :invalid_request_plan,
      reason: "Invalid model specification for request planning",
      context: []
    )
  end

  defp translation_error do
    invalid_parameter(
      "provider option translation could not be inspected; verify option names and types"
    )
  end

  defp invalid_parameter(message), do: {:error, Parameter.exception(parameter: message)}
end

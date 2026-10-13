defmodule ReqLLM.Providers.Anthropic.PlatformReasoning do
  @moduledoc """
  Shared extended thinking/reasoning support for Anthropic models on third-party platforms.

  This module provides common functionality for Anthropic Claude models running on
  third-party AI platforms that use the `additional_model_request_fields` approach
  for extended thinking configuration.

  Adaptive models use native Anthropic option translation before the translated
  fields are stored in the platform request options. Budget-thinking models keep
  their platform-specific token-budget handling.

  ## Shared Functionality

  This module provides:
  - `add_reasoning_to_additional_fields/3` - Adds thinking config to provider_options (model optional for adaptive detection)
  - `maybe_clean_thinking_after_translation/2` - Removes thinking when incompatible

  ## Platform-Specific Functionality

  Each platform maintains its own:
  - `maybe_translate_reasoning_params/2` - Platform-specific translation logic
    (handles model capability checks and calls shared functions)
  """

  @doc """
  Adds thinking config to provider_options.additional_model_request_fields.

  This is the format used by Bedrock, Vertex, and other third-party platforms
  that host Anthropic models.

  Automatically uses `type: "adaptive"` (with display: "summarized") for
  "adaptive-thinking only" Claude models (e.g. certain Opus 4.x variants),
  otherwise falls back to `type: "enabled"` with budget_tokens.

  ## Example

      opts = add_reasoning_to_additional_fields(opts, 4000, model)
      # Adds to provider_options:
      # additional_model_request_fields: %{
      #   thinking: %{type: "enabled", budget_tokens: 4000}
      # }
  """
  def add_reasoning_to_additional_fields(opts, budget_tokens, model \\ nil) do
    provider_opts = Keyword.get(opts, :provider_options, [])

    thinking =
      if model && ReqLLM.ModelHelpers.adaptive_thinking_required?(model) do
        %{type: "adaptive", display: "summarized"}
      else
        %{type: "enabled", budget_tokens: budget_tokens}
      end

    additional_fields =
      Keyword.get(provider_opts, :additional_model_request_fields, %{})
      |> Map.put(:thinking, thinking)

    updated_provider_opts =
      Keyword.put(provider_opts, :additional_model_request_fields, additional_fields)

    Keyword.put(opts, :provider_options, updated_provider_opts)
  end

  @doc """
  Applies native Anthropic adaptive reasoning rules and stores the translated
  thinking and output configuration in the platform request fields.
  """
  def prepare_adaptive_options(operation, model, opts) do
    {provider_opts, opts} = Keyword.pop(opts, :provider_options, [])
    {provider_effort, provider_opts} = Keyword.pop(provider_opts, :reasoning_effort)
    {provider_budget, provider_opts} = Keyword.pop(provider_opts, :reasoning_token_budget)

    fields =
      provider_opts |> Keyword.get(:additional_model_request_fields, %{}) |> normalize_fields()

    opts =
      opts
      |> Keyword.put(:provider_options, provider_opts)
      |> put_default_option(:reasoning_effort, provider_effort)
      |> put_default_option(:reasoning_token_budget, provider_budget)
      |> put_default_option(:thinking, ReqLLM.MapAccess.get(fields, :thinking))
      |> put_default_option(:output_config, ReqLLM.MapAccess.get(fields, :output_config))

    opts =
      case opts[:reasoning_effort] do
        nil ->
          opts

        effort ->
          Keyword.put(opts, :reasoning_effort, ReqLLM.Provider.Reasoning.normalize_effort(effort))
      end

    opts =
      if opts[:reasoning_effort] == nil and is_integer(opts[:reasoning_token_budget]) do
        Keyword.put(opts, :thinking, %{
          type: "enabled",
          budget_tokens: opts[:reasoning_token_budget]
        })
      else
        opts
      end

    translation_model = ReqLLM.ModelHelpers.with_anthropic_effort_metadata(model)

    {opts, _warnings} =
      ReqLLM.Providers.Anthropic.translate_options(operation, translation_model, opts)

    move_fields(opts)
  end

  defp put_default_option(opts, _key, nil), do: opts
  defp put_default_option(opts, key, value), do: Keyword.put_new(opts, key, value)

  @doc """
  Moves native thinking and output configuration into platform request fields.
  Preserves other platform fields and output configuration entries.
  """
  def move_fields(opts) do
    {native_fields, opts} = Keyword.split(opts, [:thinking, :output_config])
    provider_opts = Keyword.get(opts, :provider_options, [])

    fields =
      provider_opts |> Keyword.get(:additional_model_request_fields, %{}) |> normalize_fields()

    fields =
      Enum.reduce(native_fields, fields, fn
        {:output_config, config}, fields ->
          config = normalize_output_config(config)
          Map.update(fields, :output_config, config, &Map.merge(&1, config))

        {key, value}, fields ->
          Map.put(fields, key, value)
      end)

    if native_fields == [] do
      opts
    else
      Keyword.put(
        opts,
        :provider_options,
        Keyword.put(provider_opts, :additional_model_request_fields, fields)
      )
    end
  end

  defp normalize_fields(fields) do
    Enum.reduce([:thinking, :output_config], fields, fn key, fields ->
      case ReqLLM.MapAccess.get(fields, key) do
        nil ->
          fields

        value ->
          value = if key == :output_config, do: normalize_output_config(value), else: value
          fields |> Map.delete(to_string(key)) |> Map.put(key, value)
      end
    end)
  end

  defp normalize_output_config(config) when is_list(config),
    do: config |> Map.new() |> normalize_output_config()

  defp normalize_output_config(config) when is_map(config) do
    Enum.reduce([:effort, :format], config, fn key, config ->
      case ReqLLM.MapAccess.get(config, key) do
        nil -> config
        value -> config |> Map.delete(to_string(key)) |> Map.put(key, value)
      end
    end)
  end

  @doc """
  Adds `output_config.effort` to provider_options.additional_model_request_fields
  for adaptive-thinking-only Claude models, where effort (not a token budget) is
  what controls thinking depth. A no-op for budget-thinking models.
  """
  def maybe_add_effort_to_additional_fields(opts, reasoning_effort, model) do
    if ReqLLM.ModelHelpers.adaptive_thinking_required?(model) do
      provider_opts = Keyword.get(opts, :provider_options, [])

      additional_fields =
        provider_opts
        |> Keyword.get(:additional_model_request_fields, %{})
        |> Map.update(:output_config, %{effort: effort_value(reasoning_effort)}, fn
          config when is_map(config) -> Map.put(config, :effort, effort_value(reasoning_effort))
          _ -> %{effort: effort_value(reasoning_effort)}
        end)

      Keyword.put(
        opts,
        :provider_options,
        Keyword.put(provider_opts, :additional_model_request_fields, additional_fields)
      )
    else
      opts
    end
  end

  defp effort_value(effort) do
    case ReqLLM.Provider.Reasoning.normalize_effort(effort) do
      :minimal -> "low"
      effort when effort in [:low, :medium, :high, :xhigh, :max] -> Atom.to_string(effort)
      _ -> "medium"
    end
  end

  @doc """
  Removes thinking config when incompatible with other parameters.

  Extended thinking is incompatible with:
  - Forced tool choice (`tool_choice: %{type: "tool"}`)
  - `:object` operations using forced tools (JSON schema mode keeps thinking)
  - Temperature != 1.0 (Anthropic-specific constraint)

  This should be called AFTER translate_options has run, since translate_options
  may add or modify tool_choice and temperature.

  ## Example

      opts = maybe_clean_thinking_after_translation(opts, :object)
      # Removes thinking from additional_model_request_fields if incompatible
  """
  def maybe_clean_thinking_after_translation(opts, operation) do
    tool_choice = opts[:tool_choice]
    mode = ReqLLM.Providers.Anthropic.AdapterHelpers.structured_output_mode(opts)

    has_forced_tool =
      match?(%{type: "tool"}, tool_choice) or match?(%{"type" => "tool"}, tool_choice) or
        (operation == :object and mode != :json_schema)

    temperature = opts[:temperature]
    incompatible_temperature = temperature != nil and temperature != 1.0

    if has_forced_tool or incompatible_temperature do
      update_in(opts, [:provider_options, :additional_model_request_fields], fn
        nil ->
          nil

        fields when is_map(fields) ->
          fields
          |> Map.delete(:thinking)
          |> Map.delete("thinking")
          |> remove_output_effort()
      end)
    else
      opts
    end
  end

  defp remove_output_effort(fields) do
    case ReqLLM.MapAccess.get(fields, :output_config) do
      config when is_map(config) ->
        config = Map.drop(config, [:effort, "effort"])
        fields = Map.drop(fields, [:output_config, "output_config"])
        if map_size(config) == 0, do: fields, else: Map.put(fields, :output_config, config)

      _ ->
        fields
    end
  end
end

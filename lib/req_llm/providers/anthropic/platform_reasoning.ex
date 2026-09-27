defmodule ReqLLM.Providers.Anthropic.PlatformReasoning do
  @moduledoc """
  Shared extended thinking/reasoning support for Anthropic models on third-party platforms.

  This module provides common functionality for Anthropic Claude models running on
  third-party AI platforms that use the `additional_model_request_fields` approach
  for extended thinking configuration.

  ## Not for Native Anthropic

  Native Anthropic API uses a different approach with additional logic
  (adjust_max_tokens_for_thinking, adjust_top_p_for_thinking).

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
  - `:object` operations (which use forced tool choice internally)
  - Temperature != 1.0 (Anthropic-specific constraint)

  This should be called AFTER translate_options has run, since translate_options
  may add or modify tool_choice and temperature.

  ## Example

      opts = maybe_clean_thinking_after_translation(opts, :object)
      # Removes thinking from additional_model_request_fields if incompatible
  """
  def maybe_clean_thinking_after_translation(opts, operation) do
    # Check if we have forced tool_choice
    # For :object operation, tool_choice is added later by the formatter, but we know it will be forced
    tool_choice = opts[:tool_choice]
    has_forced_tool = match?(%{type: "tool"}, tool_choice) or operation == :object

    # Check if temperature is set to something other than 1.0
    # When thinking is enabled, temperature must be 1.0 (Anthropic-specific constraint)
    temperature = opts[:temperature]
    incompatible_temperature = temperature != nil and temperature != 1.0

    if has_forced_tool or incompatible_temperature do
      # Remove thinking from additional_model_request_fields
      update_in(
        opts,
        [:provider_options, :additional_model_request_fields],
        fn
          nil -> nil
          fields when is_map(fields) -> Map.delete(fields, :thinking)
        end
      )
    else
      opts
    end
  end
end

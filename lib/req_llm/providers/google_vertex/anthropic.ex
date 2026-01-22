defmodule ReqLLM.Providers.GoogleVertex.Anthropic do
  @moduledoc """
  Anthropic model family support for Google Vertex AI.

  Handles Claude models (Claude 3.5 Haiku, Claude 3.5 Sonnet, Claude Opus, etc.)
  on Google Vertex AI.

  This module acts as a thin adapter between Vertex AI's GCP infrastructure
  and Anthropic's native message format. It delegates to the native Anthropic
  modules for all format conversion.

  ## Prompt Caching Support

  Full Anthropic prompt caching is supported. Enable with `anthropic_prompt_cache: true` option.

  ## Extended Thinking Support

  Extended thinking (reasoning) is supported for models that support it.
  Enable with `reasoning_effort: "low" | "medium" | "high"` option.
  """

  alias ReqLLM.ModelHelpers
  alias ReqLLM.Providers.Anthropic
  alias ReqLLM.Providers.Anthropic.AdapterHelpers
  alias ReqLLM.Providers.Anthropic.PlatformReasoning

  @doc """
  Pre-validates and transforms options for Claude models on Vertex AI.
  Handles reasoning_effort/reasoning_token_budget translation to thinking config.
  """
  def pre_validate_options(_operation, model, opts) do
    # Handle reasoning parameters for Claude models
    opts = maybe_translate_reasoning_params(model, opts)
    {opts, []}
  end

  @doc """
  Formats a ReqLLM context into Anthropic request format for Vertex AI.

  Delegates to the native Anthropic.Context module. Vertex AI uses the
  native Anthropic Messages API format directly.

  For :object operations, creates a synthetic "structured_output" tool to
  leverage Claude's tool-calling for structured JSON output.
  """
  def format_request(_model_id, context, opts) do
    operation = opts[:operation]

    # For :object operation, we need to inject the structured_output tool
    {context, opts} =
      if operation == :object do
        AdapterHelpers.prepare_structured_output_context(context, opts)
      else
        {context, opts}
      end

    # Create a fake model struct for Anthropic.Context.encode_request
    model = %{model: opts[:model] || "claude-3-sonnet"}

    # Delegate to native Anthropic context encoding
    body = Anthropic.Context.encode_request(context, model)

    # Remove model field - Vertex specifies model in URL, not body
    body = Map.delete(body, :model)

    # Add parameters
    # Use 4096 for :object operations (need more tokens for structured output), 1024 otherwise
    default_max_tokens = if operation == :object, do: 4096, else: 1024

    # Note: temperature/top_p conflict is already handled by Anthropic.translate_options
    body
    |> Map.put(:anthropic_version, "vertex-2023-10-16")
    |> AdapterHelpers.maybe_add_param(:max_tokens, opts[:max_tokens] || default_max_tokens)
    |> AdapterHelpers.maybe_add_param(:stream, opts[:stream])
    |> AdapterHelpers.maybe_add_param(:temperature, opts[:temperature])
    |> AdapterHelpers.maybe_add_param(:top_p, opts[:top_p])
    |> AdapterHelpers.maybe_add_param(:top_k, opts[:top_k])
    |> AdapterHelpers.maybe_add_param(:stop_sequences, opts[:stop_sequences])
    |> AdapterHelpers.maybe_add_thinking(opts)
    |> maybe_add_tools(opts)
    |> Anthropic.maybe_apply_prompt_caching(opts)
  end

  # Add tools from opts to request body
  defp maybe_add_tools(body, opts) do
    tools = Keyword.get(opts, :tools, [])

    case tools do
      [] ->
        body

      tools when is_list(tools) ->
        # Convert tools to Anthropic format using public helper
        anthropic_tools = Enum.map(tools, &Anthropic.tool_to_anthropic_format/1)
        body = Map.put(body, :tools, anthropic_tools)

        # Add tool_choice if specified
        case Keyword.get(opts, :tool_choice) do
          nil -> body
          choice -> Map.put(body, :tool_choice, choice)
        end
    end
  end

  @doc """
  Parses Anthropic response from Vertex AI into ReqLLM format.

  Delegates to the native Anthropic.Response module.

  For :object operations, extracts the structured output from the tool call.
  """
  def parse_response(body, %LLMDB.Model{} = vertex_model, opts) when is_map(body) do
    # Create an Anthropic model struct for decode_response
    # Use the model ID from the response body, or fall back to the Vertex model
    model_id = Map.get(body, "model", vertex_model.id)

    anthropic_model = %LLMDB.Model{
      id: model_id,
      provider: :anthropic
    }

    # Delegate to native Anthropic response decoding
    case Anthropic.Response.decode_response(body, anthropic_model) do
      {:ok, response} ->
        # Merge with input context to preserve conversation history
        input_context = opts[:context] || %ReqLLM.Context{messages: []}
        merged_response = ReqLLM.Context.merge_response(input_context, response)

        # For :object operation, extract structured output from tool call
        final_response =
          if opts[:operation] == :object do
            AdapterHelpers.extract_and_set_object(merged_response)
          else
            merged_response
          end

        {:ok, final_response}

      error ->
        error
    end
  end

  @doc """
  Extracts usage metadata from the response body.

  Delegates to the native Anthropic provider.
  """
  def extract_usage(body, model) do
    # Delegate to native Anthropic extract_usage
    Anthropic.extract_usage(body, model)
  end

  # Translate reasoning_effort/reasoning_token_budget to Vertex additionalModelRequestFields
  # Only for Claude models that support extended thinking
  defp maybe_translate_reasoning_params(model, opts) do
    # Check if this model has reasoning capability
    has_reasoning = ModelHelpers.reasoning_enabled?(model)

    if has_reasoning do
      {reasoning_effort, opts} = Keyword.pop(opts, :reasoning_effort)
      {reasoning_budget, opts} = Keyword.pop(opts, :reasoning_token_budget)

      cond do
        reasoning_budget && is_integer(reasoning_budget) ->
          # Explicit budget_tokens provided
          opts
          |> PlatformReasoning.add_reasoning_to_additional_fields(reasoning_budget)
          |> ensure_min_max_tokens(reasoning_budget)
          |> Keyword.put(:temperature, 1.0)

        reasoning_effort ->
          # Map effort to budget using canonical Anthropic mappings
          budget = Anthropic.map_reasoning_effort_to_budget(reasoning_effort)

          opts
          |> PlatformReasoning.add_reasoning_to_additional_fields(budget)
          |> ensure_min_max_tokens(budget)
          |> Keyword.put(:temperature, 1.0)

        true ->
          # No reasoning params
          opts
      end
    else
      opts
    end
  end

  # Ensure max_tokens is at least budget + 201 (Anthropic requirement for thinking)
  defp ensure_min_max_tokens(opts, budget_tokens) do
    min_tokens = budget_tokens + 201
    Keyword.update(opts, :max_tokens, min_tokens, fn current -> max(current, min_tokens) end)
  end

  @doc """
  Cleans up thinking config if incompatible with other options.

  Delegates to shared PlatformReasoning module.
  See `ReqLLM.Providers.Anthropic.PlatformReasoning.maybe_clean_thinking_after_translation/2`.
  """
  def maybe_clean_thinking_after_translation(opts, operation) do
    PlatformReasoning.maybe_clean_thinking_after_translation(opts, operation)
  end
end

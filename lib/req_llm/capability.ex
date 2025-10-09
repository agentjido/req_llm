defmodule ReqLLM.Capability do
  @moduledoc """
  Model capability discovery and validation.

  Provides programmatic interface to query what features are supported by specific models.
  Capabilities are extracted from provider metadata loaded from models.dev.
  """

  alias ReqLLM.Provider.Registry

  @doc """
  Get all supported capabilities for a model.

  ## Examples

      iex> ReqLLM.Capability.capabilities("anthropic:claude-3-haiku")
      [:max_tokens, :system_prompt, :temperature, :tools, :streaming]
  """
  @spec capabilities(ReqLLM.Model.t() | binary()) :: [atom()]
  def capabilities(model_input) do
    case normalize_model(model_input) do
      {:ok, %ReqLLM.Model{} = model} -> extract_capabilities_from_model(model)
      _ -> []
    end
  end

  @doc """
  Check if a model supports a specific capability.

  ## Examples

      iex> ReqLLM.Capability.supports?("anthropic:claude-3-sonnet", :tools)
      true
  """
  @spec supports?(ReqLLM.Model.t() | binary(), atom()) :: boolean()
  def supports?(model_spec, capability) when is_atom(capability) do
    model_capabilities = capabilities(model_spec)
    capability in model_capabilities
  end

  @doc """
  Check if model supports object generation (structured output).

  Different providers implement this via different mechanisms:
  - Google: Native JSON mode via responseMimeType
  - OpenAI: response_format with json_schema OR strict tools
  - Anthropic/Groq/OpenRouter/XAI: Function calling with structured tool

  ## Examples

      iex> ReqLLM.Capability.supports_object_generation?("openai:gpt-4o")
      true

      iex> ReqLLM.Capability.supports_object_generation?("anthropic:claude-3-haiku")
      true
  """
  @spec supports_object_generation?(ReqLLM.Model.t() | binary()) :: boolean()
  def supports_object_generation?(model_input) do
    case normalize_model(model_input) do
      {:ok, %ReqLLM.Model{} = model} ->
        case model.provider do
          :google ->
            true

          :openai ->
            json_schema_support =
              get_in(model, [Access.key(:_metadata, %{}), "supports_json_schema_response_format"]) ==
                true

            strict_tools_support =
              get_in(model, [Access.key(:_metadata, %{}), "supports_strict_tools"]) == true

            json_schema_support or strict_tools_support

          _ ->
            supports?(model, :tool_call)
        end

      _ ->
        false
    end
  end

  @doc """
  Get all models from a provider that support a specific capability.

  ## Examples

      iex> ReqLLM.Capability.models_for(:anthropic, :reasoning)
      ["anthropic:claude-3-5-sonnet-20241022"]
  """
  @spec models_for(atom(), atom()) :: [binary()]
  def models_for(provider, capability) when is_atom(provider) and is_atom(capability) do
    case Registry.list_models(provider) do
      {:ok, model_names} ->
        model_names
        |> Enum.map(&"#{provider}:#{&1}")
        |> Enum.filter(fn model_spec -> supports?(model_spec, capability) end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Get all available models for a provider.

  ## Examples

      iex> ReqLLM.Capability.provider_models(:anthropic)
      ["anthropic:claude-3-haiku", "anthropic:claude-3-sonnet"]
  """
  @spec provider_models(atom()) :: [binary()]
  def provider_models(provider) when is_atom(provider) do
    case Registry.list_models(provider) do
      {:ok, model_names} -> Enum.map(model_names, &"#{provider}:#{&1}")
      {:error, _} -> []
    end
  end

  @doc """
  Get all providers that have models supporting a capability.

  ## Examples

      iex> ReqLLM.Capability.providers_for(:tools)
      [:anthropic, :openai, :google]
  """
  @spec providers_for(atom()) :: [atom()]
  def providers_for(capability) when is_atom(capability) do
    Registry.list_providers()
    |> Enum.filter(&(!Enum.empty?(models_for(&1, capability))))
  end

  @doc """
  Validate that a model supports required capabilities from options.

  ## Options

  - `:on_unsupported` - `:ignore` (default), `:warn`, or `:error`

  ## Examples

      iex> ReqLLM.Capability.validate!(model, temperature: 0.7)
      :ok

      iex> ReqLLM.Capability.validate!(model, tools: [...], on_unsupported: :error)
      ** (ReqLLM.Error.Invalid.Capability) Model does not support [:tools]
  """
  @spec validate!(ReqLLM.Model.t() | binary(), keyword()) :: :ok
  def validate!(model, opts) do
    model_capabilities = capabilities(model)
    on_unsupported = Keyword.get(opts, :on_unsupported, :ignore)

    required = opts |> extract_capability_requirements() |> Enum.uniq()
    unsupported = required -- model_capabilities

    if unsupported == [] do
      :ok
    else
      handle_unsupported(model, unsupported, on_unsupported)
    end
  end

  # Convert various model inputs to a Model struct
  defp normalize_model(%ReqLLM.Model{} = model), do: {:ok, model}
  defp normalize_model(model_spec), do: ReqLLM.Model.from(model_spec)

  # Extract capabilities from a Model struct, preferring validated capabilities if available
  defp extract_capabilities_from_model(%ReqLLM.Model{capabilities: capabilities})
       when not is_nil(capabilities) do
    # Use validated capabilities from the model struct when available
    validated_capabilities = for {key, true} <- capabilities, do: key

    # Add additional capabilities that are always supported
    additional_capabilities = [:max_tokens, :system_prompt, :metadata, :stop_sequences]

    # Add tool-related capabilities based on tool_call support
    tool_capabilities =
      if Map.get(capabilities, :tool_call, false), do: [:tools, :tool_choice], else: []

    # Add streaming (assume supported unless explicitly disabled)
    streaming_capabilities = [:streaming]

    (validated_capabilities ++
       additional_capabilities ++ tool_capabilities ++ streaming_capabilities)
    |> Enum.uniq()
  end

  defp extract_capabilities_from_model(%ReqLLM.Model{provider: provider, model: model_name}) do
    # Fallback to loading metadata directly
    case ReqLLM.Model.Metadata.get_model_metadata(provider, model_name) do
      {:ok, metadata} -> extract_capabilities(metadata)
      _ -> []
    end
  end

  # Extract all supported capabilities from model metadata (fallback method)
  defp extract_capabilities(metadata) do
    capabilities = ReqLLM.Metadata.build_capabilities_from_metadata(metadata)

    # Get validated capabilities from metadata structure
    validated_capabilities = for {key, true} <- capabilities, do: key

    # Add additional capabilities that are always supported or derived from other metadata
    additional_capabilities = [
      # All models support token limits
      :max_tokens,
      # All models support system prompts
      :system_prompt,
      # All models have metadata
      :metadata,
      # All models support stop sequences
      :stop_sequences
    ]

    # Add sampling parameters based on metadata
    sampling_capabilities =
      for {key, supported} <- %{
            temperature: Map.get(metadata, "temperature", false),
            top_p: Map.get(metadata, "top_p", false),
            top_k: Map.get(metadata, "top_k", false)
          },
          supported,
          do: key

    # Add streaming support (default to true if not specified)
    streaming_capabilities =
      if Map.get(metadata, "streaming", true), do: [:streaming], else: []

    # Add tool-related capabilities based on tool_call support
    tool_capabilities =
      if Map.get(metadata, "tool_call", false), do: [:tools, :tool_choice], else: []

    (validated_capabilities ++
       additional_capabilities ++
       sampling_capabilities ++
       streaming_capabilities ++ tool_capabilities)
    |> Enum.uniq()
  end

  # Extract capability requirements from user options
  defp extract_capability_requirements(opts) do
    opts
    |> Enum.flat_map(fn
      # Sampling parameters
      {:temperature, _} -> [:temperature]
      {:top_p, _} -> [:top_p]
      {:top_k, _} -> [:top_k]
      # Tool calling
      {:tools, _} -> [:tools]
      {:tool_choice, _} -> [:tool_choice]
      # Advanced features
      {:reasoning, _} -> [:reasoning]
      {:stop_sequences, _} -> [:stop_sequences]
      # Streaming (internal flag set by stream_* functions)
      {:stream, true} -> [:streaming]
      # Ignore other options
      _ -> []
    end)
  end

  # Handle unsupported capabilities according to policy
  defp handle_unsupported(model, unsupported, on_unsupported) do
    model_name = format_model_name(model)
    msg = "Model #{model_name} does not support #{inspect(unsupported)}"

    case on_unsupported do
      :ignore ->
        :ok

      :warn ->
        require Logger

        Logger.warning(msg)
        :ok

      :error ->
        raise ReqLLM.Error.Invalid.Capability, message: msg, missing: unsupported
    end
  end

  # Format model name for error messages
  defp format_model_name(%ReqLLM.Model{provider: provider, model: model}),
    do: "#{provider}:#{model}"

  defp format_model_name(model_spec) when is_binary(model_spec), do: model_spec
end

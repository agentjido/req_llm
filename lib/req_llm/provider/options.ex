defmodule ReqLLM.Provider.Options do
  @moduledoc """
  Runtime generation options processing for ReqLLM providers.

  This module handles only the core generation options that are truly universal
  across providers, plus the orchestration logic for validation, translation,
  and provider-specific option handling.

  ## Design Principles

  1. **Universal Core**: Only include options supported by most major providers
  2. **Provider Extensions**: Allow providers to define their own options via `provider_schema/0`
  3. **Clean Separation**: Metadata (capabilities, costs) belongs in separate modules

  ## Core Options

  The following options are considered universal:
  - `temperature`, `max_tokens` - Basic sampling control
  - `top_p`, `top_k` - Advanced sampling
  - `frequency_penalty`, `presence_penalty` - Repetition control
  - `seed`, `stop` - Deterministic generation and control
  - `tools`, `tool_choice` - Function calling
  - `reasoning_effort`, `reasoning_token_budget` - Reasoning controls
  - `n`, `stream` - Output control
  - `user` - Tracking/identification

  ## Provider-Specific Options

  Providers can extend the schema via:
  ```elixir
  def provider_schema do
    NimbleOptions.new!([
      dimensions: [type: :pos_integer, doc: "Embedding dimensions"],
      custom_param: [type: :string, doc: "Provider-specific parameter"]
    ])
  end
  ```

  ## Usage

  The main entry point is `process/4` which handles the complete pipeline:
  ```elixir
  {:ok, processed_opts} = Options.process(MyProvider, :chat, model, user_opts)
  ```
  """

  # Core generation options - only truly universal parameters
  @generation_options_schema NimbleOptions.new!(
                               # Basic sampling (supported by virtually all providers)
                               temperature: [
                                 type: :float,
                                 doc: "Controls randomness in output (0.0 to 2.0)"
                               ],
                               max_tokens: [
                                 type: :pos_integer,
                                 doc: "Maximum number of tokens to generate"
                               ],

                               # Advanced sampling (widely supported)
                               top_p: [
                                 type: :float,
                                 doc: "Nucleus sampling parameter (0.0 to 1.0)"
                               ],
                               top_k: [
                                 type: :pos_integer,
                                 doc: "Top-k sampling parameter"
                               ],

                               # Repetition control (OpenAI, Anthropic, others)
                               frequency_penalty: [
                                 type: :float,
                                 doc: "Penalize tokens based on frequency (-2.0 to 2.0)"
                               ],
                               presence_penalty: [
                                 type: :float,
                                 doc: "Penalize tokens based on presence (-2.0 to 2.0)"
                               ],

                               # Control parameters
                               seed: [
                                 type: :pos_integer,
                                 doc: "Random seed for deterministic generation"
                               ],
                               stop: [
                                 type: {:or, [:string, {:list, :string}]},
                                 doc: "Stop sequences to end generation"
                               ],
                               user: [
                                 type: :string,
                                 doc: "User identifier for tracking and abuse detection"
                               ],

                               # System prompt (widely supported)
                               system_prompt: [
                                 type: :string,
                                 doc: "System prompt to set context and instructions"
                               ],

                               # Canonical reasoning controls
                               reasoning_effort: [
                                 type: {:in, [:low, :medium, :high, :default]},
                                 doc:
                                   "Computational effort for reasoning models (higher = more thinking)"
                               ],
                               reasoning_token_budget: [
                                 type: :pos_integer,
                                 doc:
                                   "Maximum tokens allocated for internal reasoning/thinking processes"
                               ],

                               # Function/tool calling (widely supported)
                               tools: [
                                 type: {:list, :any},
                                 doc: "List of available tools/functions"
                               ],
                               tool_choice: [
                                 type: {:or, [:string, :atom, :map]},
                                 doc:
                                   "Tool selection strategy (auto, none, required, or specific)"
                               ],

                               # Output control
                               n: [
                                 type: :pos_integer,
                                 default: 1,
                                 doc: "Number of completions to generate"
                               ],
                               stream: [
                                 type: :boolean,
                                 default: false,
                                 doc: "Enable streaming responses"
                               ],

                               # Provider-specific options container
                               provider_options: [
                                 type: {:list, :any},
                                 doc: "Provider-specific options (nested under this key)"
                               ],

                               # Framework options
                               on_unsupported: [
                                 type: {:in, [:warn, :error, :ignore]},
                                 doc: "How to handle unsupported parameter translations",
                                 default: :warn
                               ],
                               req_http_options: [
                                 type: {:list, :any},
                                 doc: "Req HTTP client options"
                               ],

                               # HTTP client options
                               receive_timeout: [
                                 type: :pos_integer,
                                 doc:
                                   "Timeout for receiving HTTP responses in milliseconds (defaults to global config)"
                               ],
                               max_retries: [
                                 type: :pos_integer,
                                 default: 3,
                                 doc:
                                   "Maximum number of retry attempts for transient network errors"
                               ]
                             )

  # Internal keys that bypass validation (framework concerns)
  @internal_keys [
    :api_key,
    :base_url,
    :on_unsupported,
    :fixture,
    :req_http_options,
    :compiled_schema,
    :operation,
    :text,
    :context
  ]

  @doc """
  Returns the core generation options schema.
  """
  def generation_schema, do: @generation_options_schema

  @doc """
  Main processing function - validates, translates, and composes options.

  This is the primary public API for option processing. It handles:
  1. Provider key collision detection (prevents shadowing core options)
  2. Validation against composed schema (core + provider options)
  3. Provider-specific option translation
  4. Internal option preservation
  5. Error wrapping for consistency

  ## Parameters
  - `provider_mod` - Provider module implementing the Provider behavior
  - `operation` - Operation type (:chat, :embedding, :object, etc.)
  - `model` - ReqLLM.Model struct
  - `opts` - Raw user options keyword list

  ## Returns
  `{:ok, processed_opts}` or `{:error, wrapped_error}`

  ## Examples
      {:ok, model} = ReqLLM.model("openai:gpt-4")

      opts = [
        temperature: 0.7,
        provider_options: [dimensions: 512, encoding_format: "float"]
      ]
      {:ok, processed} = Options.process(MyProvider, :chat, model, opts)
  """
  @spec process(module(), atom(), LLMDB.Model.t(), keyword()) ::
          {:ok, keyword()} | {:error, term()}
  def process(provider_mod, operation, model, opts) do
    processed_opts = process!(provider_mod, operation, model, opts)
    {:ok, processed_opts}
  rescue
    error in [NimbleOptions.ValidationError] ->
      # Enhance validation error messages with helpful suggestions
      enhanced_error = enhance_validation_error(error, provider_mod, opts)
      {:error, ReqLLM.Error.Unknown.Unknown.exception(error: enhanced_error)}

    error ->
      {:error, error}
  end

  @doc """
  Same as process/4 but raises on error.
  """
  @spec process!(module(), atom(), LLMDB.Model.t(), keyword()) :: keyword()
  def process!(provider_mod, operation, model, opts) do
    {internal_opts, user_opts} = Keyword.split(opts, @internal_keys)
    user_opts = handle_stream_alias(user_opts)
    user_opts = normalize_legacy_options(user_opts)

    # Extract model options (e.g. max_tokens) if present
    user_opts = extract_model_options(model, user_opts)

    # Check for key collisions before schema validation
    check_provider_key_collisions!(provider_mod, user_opts)

    # Auto-hoist provider-specific top-level options into :provider_options
    user_opts = auto_hoist_provider_options(provider_mod, user_opts)

    # Apply pre-validation normalization (allows providers to filter/map unsupported options)
    user_opts = apply_pre_validation(provider_mod, operation, model, user_opts)

    schema = compose_schema_internal(@generation_options_schema, provider_mod)
    validated_opts = NimbleOptions.validate!(user_opts, schema)

    {provider_options, standard_opts} = Keyword.pop(validated_opts, :provider_options, [])
    flattened_for_translation = Keyword.merge(standard_opts, provider_options)
    translated_opts = apply_translation(provider_mod, operation, model, flattened_for_translation)

    final_opts =
      if provider_options == [] do
        translated_opts
      else
        Keyword.put(translated_opts, :provider_options, provider_options)
      end

    final_opts = handle_warnings(final_opts, opts)

    final_opts =
      final_opts
      |> Keyword.merge(internal_opts)
      |> validate_context(opts)
      |> inject_base_url_from_registry(model, provider_mod)

    final_opts
  end

  # Public utility functions

  @doc """
  Returns a list of all generation option keys.
  """
  def all_generation_keys do
    @generation_options_schema.schema |> Keyword.keys()
  end

  @doc """
  Extracts provider-specific options from a mixed options list.

  This is useful for separating standard options from provider-specific ones.

  ## Examples

      iex> opts = [temperature: 0.7, max_tokens: 100, custom_param: "value"]
      iex> ReqLLM.Provider.Options.extract_provider_options(opts)
      {[temperature: 0.7, max_tokens: 100], [custom_param: "value"]}
  """
  def extract_provider_options(opts) do
    opts_with_aliases = handle_stream_alias(opts)
    known_keys = all_generation_keys() |> Enum.reject(&(&1 == :provider_options))
    {standard, custom} = Keyword.split(opts_with_aliases, known_keys)
    {standard, custom}
  end

  @doc """
  Extracts only generation options from a mixed options list.

  Unlike `extract_provider_options/1`, this returns only the generation
  options without the unused remainder.

  ## Examples

      iex> mixed_opts = [temperature: 0.7, custom_param: "value", max_tokens: 100]
      iex> ReqLLM.Provider.Options.extract_generation_opts(mixed_opts)
      [temperature: 0.7, max_tokens: 100]
  """
  def extract_generation_opts(opts) do
    {generation_opts, _rest} = extract_provider_options(opts)
    generation_opts
  end

  @doc """
  Returns a NimbleOptions schema that contains only the requested generation keys.

  ## Examples

      iex> schema = ReqLLM.Provider.Options.generation_subset_schema([:temperature, :max_tokens])
      iex> NimbleOptions.validate([temperature: 0.7], schema)
      {:ok, [temperature: 0.7]}
  """
  def generation_subset_schema(keys) when is_list(keys) do
    wanted = Keyword.take(@generation_options_schema.schema, keys)
    NimbleOptions.new!(wanted)
  end

  @doc """
  Validates generation options against a subset of supported keys.

  ## Examples

      iex> ReqLLM.Provider.Options.validate_generation_options(
      ...>   [temperature: 0.7, max_tokens: 100],
      ...>   only: [:temperature, :max_tokens]
      ...> )
      {:ok, [temperature: 0.7, max_tokens: 100]}
  """
  def validate_generation_options(opts, only: keys) do
    schema = generation_subset_schema(keys)
    NimbleOptions.validate(opts, schema)
  end

  @doc """
  Filters generation options to only include supported keys.

  This is a pure filter function that doesn't validate - it just removes
  unsupported keys from the options.

  ## Examples

      iex> opts = [temperature: 0.7, unsupported_key: "value", max_tokens: 100]
      iex> ReqLLM.Provider.Options.filter_generation_options(opts, [:temperature, :max_tokens])
      [temperature: 0.7, max_tokens: 100]
  """
  def filter_generation_options(opts, keys) when is_list(keys) do
    Keyword.take(opts, keys)
  end

  @doc """
  Merges options with defaults, respecting user-provided overrides.

  ## Examples

      iex> defaults = [temperature: 0.7, max_tokens: 1000]
      iex> user_opts = [temperature: 0.9]
      iex> result = ReqLLM.Provider.Options.merge_with_defaults(user_opts, defaults)
      iex> result[:temperature]
      0.9
      iex> result[:max_tokens]
      1000
  """
  def merge_with_defaults(opts, defaults) do
    Keyword.merge(defaults, opts)
  end

  @doc """
  Builds a dynamic schema by composing base schema with provider-specific options.

  This function takes a base schema and provider module, creating a unified schema where
  provider-specific options are nested under the :provider_options key with proper validation.

  This is the public API for schema composition and should be used by external modules
  that need to validate options with provider-specific extensions.

  ## Parameters

  - `base_schema` - Base NimbleOptions schema (usually generation_options_schema/0)
  - `provider_mod` - Provider module that may implement provider_schema/0

  ## Examples

      schema = ReqLLM.Provider.Options.compose_schema(
        ReqLLM.Provider.Options.generation_schema(),
        MyProvider
      )
  """
  def compose_schema(base_schema, provider_mod) do
    compose_schema_internal(base_schema, provider_mod)
  end

  @doc """
  Returns the effective base URL for the provider based on precedence rules.

  The base URL is determined by the following precedence order (highest to lowest):
  1. `opts[:base_url]` - Explicitly passed in options
  2. Application config - `Application.get_env(:req_llm, model.provider)[:base_url]`
  3. Provider registry metadata - Loaded from provider's JSON metadata file
  4. Provider default - `provider_mod.default_base_url()`

  ## Parameters

  - `provider_mod` - Provider module implementing the Provider behavior
  - `model` - ReqLLM.Model struct containing provider information
  - `opts` - Options keyword list that may contain :base_url

  ## Examples

      iex> {:ok, model} = ReqLLM.model("openai:gpt-4")
      iex> ReqLLM.Provider.Options.effective_base_url(ReqLLM.Providers.OpenAI, model, [])
      "https://api.openai.com/v1"

      iex> opts = [base_url: "https://custom.example.com"]
      iex> ReqLLM.Provider.Options.effective_base_url(ReqLLM.Providers.OpenAI, model, opts)
      "https://custom.example.com"
  """
  @spec effective_base_url(module(), LLMDB.Model.t(), keyword()) :: String.t()
  def effective_base_url(provider_mod, %LLMDB.Model{} = model, opts) do
    from_opts = opts[:base_url]
    from_config = base_url_from_application_config(model.provider)
    from_metadata = base_url_from_provider_metadata(model.provider)
    from_provider_default = provider_mod.default_base_url()

    result = from_opts || from_config || from_metadata || from_provider_default

    result
  end

  # Private helper functions

  defp normalize_legacy_options(opts) do
    opts
    |> normalize_stop_sequences()
    |> normalize_legacy_reasoning()
    |> normalize_req_http_options()
    |> normalize_tools()
  end

  defp extract_model_options(%LLMDB.Model{} = model, opts) do
    cond do
      Keyword.has_key?(opts, :max_tokens) ->
        opts

      is_map(model.limits) and is_integer(model.limits[:output]) and model.limits[:output] > 0 ->
        Keyword.put(opts, :max_tokens, model.limits.output)

      true ->
        opts
    end
  end

  defp normalize_stop_sequences(opts) do
    case Keyword.pop(opts, :stop_sequences) do
      {nil, rest} -> rest
      {sequences, rest} -> Keyword.put(rest, :stop, sequences)
    end
  end

  defp normalize_legacy_reasoning(opts) do
    opts
    |> normalize_thinking_flag()
    |> normalize_reasoning_flag()
  end

  defp normalize_thinking_flag(opts) do
    case Keyword.pop(opts, :thinking) do
      {nil, rest} ->
        rest

      {false, rest} ->
        rest

      {true, rest} ->
        rest
    end
  end

  defp normalize_reasoning_flag(opts) do
    case Keyword.pop(opts, :reasoning) do
      {nil, rest} ->
        rest

      {false, rest} ->
        rest

      {true, rest} ->
        rest
        |> Keyword.put_new(:reasoning_effort, :medium)

      {"low", rest} ->
        rest
        |> Keyword.put_new(:reasoning_effort, :low)

      {"auto", rest} ->
        rest

      {"high", rest} ->
        rest
        |> Keyword.put_new(:reasoning_effort, :high)
    end
  end

  defp normalize_req_http_options(opts) do
    case Keyword.get(opts, :req_http_options) do
      map when is_map(map) ->
        Keyword.put(opts, :req_http_options, Map.to_list(map))

      _ ->
        opts
    end
  end

  defp normalize_tools(opts) do
    case Keyword.get(opts, :tools) do
      tools when not is_list(tools) and not is_nil(tools) ->
        Keyword.put(opts, :tools, [tools])

      _ ->
        opts
    end
  end

  defp handle_stream_alias(opts) do
    case Keyword.pop(opts, :stream?) do
      {nil, rest} -> rest
      {value, rest} -> Keyword.put(rest, :stream, value)
    end
  end

  defp auto_hoist_provider_options(provider_mod, opts) do
    if function_exported?(provider_mod, :provider_schema, 0) do
      provider_schema = provider_mod.provider_schema()
      provider_keys = Keyword.keys(provider_schema.schema)

      {provider_specific, rest} = Keyword.split(opts, provider_keys)

      if provider_specific == [] do
        opts
      else
        existing_provider_opts = Keyword.get(rest, :provider_options, [])
        merged_provider_opts = Keyword.merge(provider_specific, existing_provider_opts)
        Keyword.put(rest, :provider_options, merged_provider_opts)
      end
    else
      opts
    end
  end

  defp compose_schema_internal(base_schema, provider_mod) do
    if function_exported?(provider_mod, :provider_schema, 0) do
      provider_schema = provider_mod.provider_schema()

      updated_keys =
        Keyword.update!(base_schema.schema, :provider_options, fn opt ->
          Keyword.merge(opt,
            type: :keyword_list,
            keys: provider_schema.schema,
            default: []
          )
        end)

      NimbleOptions.new!(updated_keys)
    else
      base_schema
    end
  end

  defp apply_pre_validation(provider_mod, operation, model, opts) do
    if function_exported?(provider_mod, :pre_validate_options, 3) do
      case provider_mod.pre_validate_options(operation, model, opts) do
        {normalized_opts, warnings} when is_list(warnings) ->
          existing_warnings = Process.get(:req_llm_warnings, [])
          Process.put(:req_llm_warnings, existing_warnings ++ warnings)
          normalized_opts

        normalized_opts ->
          normalized_opts
      end
    else
      opts
    end
  end

  defp apply_translation(provider_mod, operation, model, opts) do
    if function_exported?(provider_mod, :translate_options, 3) do
      case provider_mod.translate_options(operation, model, opts) do
        {translated_opts, warnings} when is_list(warnings) ->
          Process.put(:req_llm_warnings, warnings)
          translated_opts

        translated_opts ->
          translated_opts
      end
    else
      opts
    end
  end

  defp handle_warnings(opts, original_opts) do
    warnings = Process.get(:req_llm_warnings, [])
    Process.delete(:req_llm_warnings)

    if warnings == [] do
      opts
    else
      case Keyword.get(original_opts, :on_unsupported, :warn) do
        :warn ->
          Enum.each(warnings, fn warning ->
            require Logger

            Logger.warning(warning)
          end)

          opts

        :error ->
          reason = Enum.join(warnings, "; ")
          raise ReqLLM.Error.Validation.Error.exception(reason: reason)

        :ignore ->
          opts
      end
    end
  end

  defp validate_context(opts, original_opts) do
    case Keyword.get(original_opts, :context) do
      %ReqLLM.Context{} = ctx ->
        Keyword.put(opts, :context, ctx)

      nil ->
        opts

      other ->
        raise ReqLLM.Error.Invalid.Parameter.exception(
                parameter: "context must be ReqLLM.Context, got: #{inspect(other)}"
              )
    end
  end

  defp check_provider_key_collisions!(provider_mod, _opts) do
    if function_exported?(provider_mod, :provider_schema, 0) do
      provider_schema = provider_mod.provider_schema()
      provider_keys = Keyword.keys(provider_schema.schema)
      core_keys = all_generation_keys() |> Enum.reject(&(&1 == :provider_options))

      collisions = MapSet.intersection(MapSet.new(provider_keys), MapSet.new(core_keys))

      if !Enum.empty?(collisions) do
        collision_list = collisions |> Enum.sort() |> Enum.join(", ")

        raise ReqLLM.Error.Invalid.Parameter.exception(
                parameter:
                  "Provider #{provider_mod.provider_id()} defines options that shadow core generation options: #{collision_list}. " <>
                    "Provider-specific options must not conflict with core ReqLLM generation options. " <>
                    "Please rename these provider options or move them to a different namespace."
              )
      end
    end
  end

  defp enhance_validation_error(%NimbleOptions.ValidationError{} = error, provider_mod, opts) do
    enhanced_message = enhance_error_message(error.message, provider_mod, opts)
    %{error | message: enhanced_message}
  end

  defp enhance_error_message(message, provider_mod, opts) do
    cond do
      String.contains?(message, "unknown options") ->
        enhance_unknown_options_error(message, provider_mod, opts)

      String.contains?(message, "invalid value") ->
        enhance_invalid_value_error(message, provider_mod)

      true ->
        message
    end
  end

  defp enhance_unknown_options_error(message, provider_mod, opts) do
    unknown_keys = extract_unknown_keys_from_opts(opts)
    provider_suggestions = get_provider_option_suggestions(provider_mod, unknown_keys)

    output_related_keys = [:output, :mode, :schema_name, :schema_description, :enum]
    has_output_options = Enum.any?(unknown_keys, &(&1 in output_related_keys))

    base_message = message

    base_message =
      if has_output_options do
        output_tip =
          "Tip: The :output option and related options (:mode, :schema_name, :schema_description, :enum) are not yet supported. " <>
            "For array/enum outputs, use Zoi to define your schema and convert it with ReqLLM.Schema.to_json/1, then pass it to generate_object/4. " <>
            "This requires a provider that supports JSON Schema (e.g., OpenAI). " <>
            "Example: array_schema = Zoi.array(Zoi.object(%{name: Zoi.string()})) |> ReqLLM.Schema.to_json()"

        base_message <> "\n\n" <> output_tip
      else
        base_message
      end

    if provider_suggestions == "" do
      base_message
    else
      base_message <> "\n\n" <> provider_suggestions
    end
  end

  defp enhance_invalid_value_error(message, _provider_mod) do
    message <>
      "\n\nTip: Check the documentation for valid parameter ranges and types. " <>
      "For provider-specific options, nest them under the :provider_options key."
  end

  defp extract_unknown_keys_from_opts(opts) do
    core_keys = all_generation_keys()
    user_keys = Keyword.keys(opts)
    user_keys -- (core_keys ++ @internal_keys)
  end

  defp get_provider_option_suggestions(provider_mod, unknown_keys) do
    if function_exported?(provider_mod, :provider_schema, 0) and unknown_keys != [] do
      provider_schema = provider_mod.provider_schema()
      provider_keys = Keyword.keys(provider_schema.schema)

      matching_keys = Enum.filter(unknown_keys, fn key -> key in provider_keys end)

      if matching_keys == [] do
        suggestions = suggest_similar_keys(unknown_keys, provider_keys)

        if suggestions == "" do
          ""
        else
          "Suggestion: Did you mean one of these provider-specific options? #{suggestions}\n" <>
            "Provider-specific options should be nested under :provider_options: [provider_options: [your_option: value]]"
        end
      else
        keys_str = matching_keys |> Enum.map_join(", ", &inspect/1)

        "Suggestion: The following options appear to be provider-specific and should be nested under :provider_options: #{keys_str}\n" <>
          "Example: [temperature: 0.7, provider_options: [#{keys_str |> String.replace(~r/[:,]/, "")} => value]]"
      end
    else
      ""
    end
  end

  defp suggest_similar_keys(unknown_keys, provider_keys) do
    suggestions =
      for unknown <- unknown_keys,
          provider <- provider_keys,
          similar?(unknown, provider) do
        "#{unknown} -> #{provider}"
      end

    if suggestions == [] do
      ""
    else
      Enum.join(suggestions, ", ")
    end
  end

  defp similar?(key1, key2) do
    str1 = Atom.to_string(key1)
    str2 = Atom.to_string(key2)

    String.jaro_distance(str1, str2) > 0.7
  end

  defp inject_base_url_from_registry(opts, model, provider_mod) do
    Keyword.put_new_lazy(opts, :base_url, fn ->
      base_url_from_application_config(model.provider) ||
        base_url_from_provider_metadata(model.provider) ||
        provider_mod.default_base_url()
    end)
  end

  defp base_url_from_provider_metadata(provider) do
    result =
      case LLMDB.provider(provider) do
        {:ok, provider_data} ->
          provider_data.base_url

        {:error, _} ->
          nil
      end

    result
  end

  defp base_url_from_application_config(provider_id) do
    config = Application.get_env(:req_llm, provider_id, [])
    Keyword.get(config, :base_url)
  end
end

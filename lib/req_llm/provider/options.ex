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

                               # Model specific base_url
                               base_url: [
                                 type: :string,
                                 doc:
                                   "Allows base_url to be specified on a per model basis.  Commonly used for locally hosted llm servers, i.e. vLLM, etc."
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
                               cache: [
                                 type: :any,
                                 doc: "Application-layer cache backend implementing ReqLLM.Cache"
                               ],
                               cache_key: [
                                 type: :any,
                                 doc: "Explicit cache key for application-layer response caching"
                               ],
                               cache_ttl: [
                                 type: :non_neg_integer,
                                 doc: "TTL in seconds for application-layer response caching"
                               ],
                               cache_options: [
                                 type: {:or, [:map, :keyword_list]},
                                 default: [],
                                 doc: "Options passed through to ReqLLM.Cache callbacks"
                               ],
                               json_repair: [
                                 type: :boolean,
                                 default: true,
                                 doc:
                                   "Attempt light JSON repair for structured outputs before failing decode"
                               ],

                               # Canonical reasoning controls
                               reasoning_effort: [
                                 type:
                                   {:in,
                                    [:none, :minimal, :low, :medium, :high, :xhigh, :default]},
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
                               tool_call_id_compat: [
                                 type: {:in, [:auto, :sanitize, :strict, :passthrough]},
                                 default: :auto,
                                 doc:
                                   "Tool call ID compatibility mode for cross-provider contexts"
                               ],

                               # Provider-specific options container
                               provider_options: [
                                 type: {:list, :any},
                                 doc: "Provider-specific options (nested under this key)"
                               ],

                               # Streaming request hook
                               on_finch_request: [
                                 type: {:fun, 1},
                                 doc:
                                   "Callback `(Finch.Request.t() -> Finch.Request.t())` applied to the streaming request just before it is sent. Applied after the global `finch_request_adapter` config. See `ReqLLM.FinchRequestAdapter` for the config-level equivalent."
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
                               telemetry: [
                                 type: {:or, [:map, :keyword_list]},
                                 doc:
                                   "ReqLLM telemetry options. Currently supports [payloads: :none | :raw]"
                               ],

                               # HTTP client options
                               receive_timeout: [
                                 type: :pos_integer,
                                 doc:
                                   "Timeout for receiving HTTP responses in milliseconds (defaults to global config)"
                               ],
                               max_retries: [
                                 type: :non_neg_integer,
                                 default: 3,
                                 doc:
                                   "Maximum number of retry attempts for transient network errors. Set to 0 to disable retries."
                               ]
                             )

  # Internal keys that bypass validation (framework concerns)
  @internal_keys [
    :api_key,
    :access_token,
    :on_finch_request,
    :auth_mode,
    :oauth_file,
    :auth_file,
    :oauth_http_options,
    :base_url,
    :on_unsupported,
    :fixture,
    :req_http_options,
    :telemetry,
    :compiled_schema,
    :operation,
    :text,
    :context
  ]

  @stream_request_option_keys [
    :api_mod,
    :auth,
    :finch,
    :json,
    :model,
    :params,
    :plug,
    :pool_timeout,
    :retry,
    :retry_log_level,
    :telemetry_original_opts
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
    user_opts = maybe_extract_model_options(operation, model, user_opts)

    # Check for key collisions before schema validation
    check_provider_key_collisions!(provider_mod, user_opts)

    # Auto-hoist provider-specific top-level options into :provider_options
    user_opts = auto_hoist_provider_options(provider_mod, user_opts)

    telemetry_original_opts =
      user_opts
      |> Keyword.merge(Keyword.take(internal_opts, [:telemetry, :context, :text, :operation]))

    # Apply pre-validation normalization (allows providers to filter/map unsupported options)
    user_opts = apply_pre_validation(provider_mod, operation, model, user_opts)

    schema = compose_schema_internal(base_schema_for_operation(operation), provider_mod)
    validated_opts = NimbleOptions.validate!(user_opts, schema)

    {provider_options, standard_opts} = Keyword.pop(validated_opts, :provider_options, [])
    flattened_for_translation = Keyword.merge(standard_opts, provider_options)
    translated_opts = apply_translation(provider_mod, operation, model, flattened_for_translation)

    final_opts =
      if provider_options == [] do
        translated_opts
      else
        translated_provider_opts =
          Keyword.take(translated_opts, Keyword.keys(provider_options))

        if translated_provider_opts == [] do
          translated_opts
        else
          Keyword.put(translated_opts, :provider_options, translated_provider_opts)
        end
      end

    final_opts = handle_warnings(final_opts, opts)

    final_opts =
      final_opts
      |> Keyword.merge(internal_opts)
      |> validate_context(opts)
      |> inject_base_url_from_registry(model, provider_mod)

    final_opts
    |> Keyword.put(:telemetry_original_opts, telemetry_original_opts)
  end

  @doc """
  Processes options for provider streaming callbacks.

  Streaming can receive options copied from prepared `Req.Request` structs, so this
  trims request-only keys before running the normal generation option pipeline.
  """
  @spec process_stream!(module(), atom(), LLMDB.Model.t(), ReqLLM.Context.t(), keyword()) ::
          keyword()
  def process_stream!(provider_mod, operation, model, context, opts) do
    opts
    |> strip_stream_request_options()
    |> Keyword.merge(stream: true, context: context, operation: operation)
    |> then(&process!(provider_mod, operation, model, &1))
  end

  @doc false
  @spec strip_stream_request_options(keyword()) :: keyword()
  def strip_stream_request_options(opts), do: Keyword.drop(opts, @stream_request_option_keys)

  # Public utility functions

  @doc """
  Returns a list of all generation option keys.
  """
  def all_generation_keys do
    @generation_options_schema.schema |> Keyword.keys()
  end

  defp base_schema_for_operation(:image), do: ReqLLM.Images.schema()

  defp base_schema_for_operation(:embedding) do
    embedding_schema = ReqLLM.Embedding.schema()
    embedding_keys = Keyword.delete(embedding_schema.schema, :return_usage)
    NimbleOptions.new!(embedding_keys)
  end

  defp base_schema_for_operation(:rerank), do: ReqLLM.Rerank.schema()

  defp base_schema_for_operation(_operation), do: @generation_options_schema

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
    from_model_opts =
      if is_bitstring(model.base_url) do
        model.base_url
      end

    from_opts = opts[:base_url]
    from_config = base_url_from_application_config(model.provider)
    from_metadata = base_url_from_provider_metadata(model.provider)
    from_provider_default = provider_mod.default_base_url()

    result = from_model_opts || from_opts || from_config || from_metadata || from_provider_default

    result
  end

  @doc """
  Adds a default generated-token limit from model metadata.

  Explicit `:max_tokens`, `:max_completion_tokens`, `:max_output_tokens`, or matching
  nested `:provider_options` values are preserved. When model metadata does not expose
  an output limit, `:fallback` is used if provided.
  """
  @spec put_model_max_tokens_default(keyword(), LLMDB.Model.t() | ReqLLM.model_input(), keyword()) ::
          keyword()
  def put_model_max_tokens_default(opts, model_input, options \\ [])

  def put_model_max_tokens_default(opts, %LLMDB.Model{} = model, options) do
    key = Keyword.get(options, :key, :max_tokens)
    fallback = Keyword.get(options, :fallback)
    output_limit = model_output_limit(model)

    cond do
      token_limit_present?(opts) ->
        opts

      is_integer(output_limit) and output_limit > 0 ->
        Keyword.put(opts, key, output_limit)

      is_integer(fallback) and fallback > 0 ->
        Keyword.put(opts, key, fallback)

      true ->
        opts
    end
  end

  def put_model_max_tokens_default(opts, model_input, options) do
    case ReqLLM.model(model_input) do
      {:ok, %LLMDB.Model{} = model} ->
        put_model_max_tokens_default(opts, model, options)

      _ ->
        put_fallback_max_tokens_default(opts, options)
    end
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
    maybe_extract_max_tokens(model, opts)
    |> maybe_extract_model_base_url(model)
  end

  defp maybe_extract_model_options(:image, _model, opts), do: opts
  defp maybe_extract_model_options(:embedding, _model, opts), do: opts
  defp maybe_extract_model_options(:rerank, _model, opts), do: opts

  defp maybe_extract_model_options(_operation, model, opts),
    do: extract_model_options(model, opts)

  defp maybe_extract_max_tokens(%LLMDB.Model{} = model, opts) do
    put_model_max_tokens_default(opts, model)
  end

  defp token_limit_present?(opts) do
    Enum.any?([:max_tokens, :max_completion_tokens, :max_output_tokens], fn key ->
      Keyword.has_key?(opts, key) or provider_option_present?(opts, key)
    end)
  end

  defp provider_option_present?(opts, key) do
    case Keyword.get(opts, :provider_options, []) do
      provider_options when is_list(provider_options) ->
        Keyword.keyword?(provider_options) and Keyword.has_key?(provider_options, key)

      provider_options when is_map(provider_options) ->
        Map.has_key?(provider_options, key) or Map.has_key?(provider_options, Atom.to_string(key))

      _ ->
        false
    end
  end

  defp put_fallback_max_tokens_default(opts, options) do
    key = Keyword.get(options, :key, :max_tokens)
    fallback = Keyword.get(options, :fallback)

    if token_limit_present?(opts) or !is_integer(fallback) or fallback <= 0 do
      opts
    else
      Keyword.put(opts, key, fallback)
    end
  end

  defp model_output_limit(%LLMDB.Model{limits: limits}) when is_map(limits) do
    limits[:output] || limits["output"]
  end

  defp model_output_limit(%LLMDB.Model{}), do: nil

  defp maybe_extract_model_base_url(opts, %LLMDB.Model{} = model) do
    if is_bitstring(model.base_url) do
      Keyword.put(opts, :base_url, model.base_url)
    else
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

      {"auto", rest} ->
        rest

      {"none", rest} ->
        rest
        |> Keyword.put_new(:reasoning_effort, :none)

      {"minimal", rest} ->
        rest
        |> Keyword.put_new(:reasoning_effort, :minimal)

      {"low", rest} ->
        rest
        |> Keyword.put_new(:reasoning_effort, :low)

      {"medium", rest} ->
        rest
        |> Keyword.put_new(:reasoning_effort, :medium)

      {"high", rest} ->
        rest
        |> Keyword.put_new(:reasoning_effort, :high)

      {"xhigh", rest} ->
        rest
        |> Keyword.put_new(:reasoning_effort, :xhigh)
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

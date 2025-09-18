defmodule ReqLLM.Provider.Options do
  @moduledoc """
  Comprehensive provider options module for ReqLLM.

  This module defines all possible provider options that can be used across different
  AI model providers, including both provider-level configuration and model-level
  parameters. Options are validated using NimbleOptions schemas.

  ## Option Categories

  1. **Provider Configuration** - Base settings for provider connections
  2. **Model Capabilities** - What features a model supports
  3. **Generation Parameters** - Runtime options for text generation
  4. **Cost & Limits** - Pricing and usage constraints
  5. **Advanced Options** - Provider-specific advanced settings
  """

  # Provider-level configuration options schema
  @provider_options_schema NimbleOptions.new!(
                             id: [
                               type: :atom,
                               required: true,
                               doc:
                                 "Unique identifier for the provider (e.g., :anthropic, :openai)"
                             ],
                             name: [
                               type: :string,
                               doc: "Human-readable name of the provider"
                             ],
                             base_url: [
                               type: :string,
                               required: true,
                               doc: "Base URL for the provider's API endpoint"
                             ],
                             env: [
                               type: {:list, :string},
                               default: [],
                               doc: "List of environment variable names for API keys"
                             ],
                             doc: [
                               type: :string,
                               doc: "Documentation or description of the provider"
                             ],
                             metadata: [
                               type: :string,
                               doc: "Path to JSON metadata file containing model information"
                             ],
                             api_key: [
                               type: :string,
                               doc:
                                 "API key for authentication (can also be set via environment variable)"
                             ],
                             organization_id: [
                               type: :string,
                               doc: "Organization ID for providers that support it (e.g., OpenAI)"
                             ],
                             project_id: [
                               type: :string,
                               doc:
                                 "Project ID for providers that require it (e.g., Google Vertex AI)"
                             ],
                             region: [
                               type: :string,
                               doc: "Region for regional endpoints (e.g., AWS Bedrock, Azure)"
                             ],
                             deployment_id: [
                               type: :string,
                               doc: "Deployment ID for Azure OpenAI deployments"
                             ],
                             version: [
                               type: :string,
                               doc: "API version to use"
                             ],
                             timeout: [
                               type: :pos_integer,
                               default: 30_000,
                               doc: "Request timeout in milliseconds"
                             ],
                             retry_attempts: [
                               type: :non_neg_integer,
                               default: 3,
                               doc: "Number of retry attempts for failed requests"
                             ],
                             retry_delay: [
                               type: :pos_integer,
                               default: 1000,
                               doc: "Delay between retry attempts in milliseconds"
                             ]
                           )

  # Model capability options schema
  @model_capabilities_schema NimbleOptions.new!(
                               id: [
                                 type: :string,
                                 required: true,
                                 doc: "Model identifier"
                               ],
                               provider_model_id: [
                                 type: :string,
                                 doc: "Provider-specific model ID (may differ from generic ID)"
                               ],
                               name: [
                                 type: :string,
                                 doc: "Human-readable model name"
                               ],
                               modalities: [
                                 type: :map,
                                 doc: "Supported input/output modalities",
                                 keys: [
                                   input: [
                                     type:
                                       {:list, {:in, [:text, :image, :audio, :video, :document]}},
                                     doc: "Supported input modalities"
                                   ],
                                   output: [
                                     type: {:list, {:in, [:text, :image, :audio, :video]}},
                                     doc: "Supported output modalities"
                                   ]
                                 ]
                               ],
                               attachment: [
                                 type: :boolean,
                                 default: false,
                                 doc: "Whether the model supports file attachments"
                               ],
                               reasoning: [
                                 type: :boolean,
                                 default: false,
                                 doc:
                                   "Whether the model supports explicit reasoning/thinking tokens"
                               ],
                               tool_call: [
                                 type: :boolean,
                                 default: false,
                                 doc: "Whether the model supports function/tool calling"
                               ],
                               temperature: [
                                 type: :boolean,
                                 default: true,
                                 doc: "Whether the model supports temperature parameter"
                               ],
                               open_weights: [
                                 type: :boolean,
                                 default: false,
                                 doc: "Whether the model weights are open source"
                               ],
                               knowledge: [
                                 type: :string,
                                 doc: "Knowledge cutoff date (YYYY-MM or YYYY-MM-DD format)"
                               ],
                               release_date: [
                                 type: :string,
                                 doc: "Model release date (YYYY-MM-DD format)"
                               ],
                               last_updated: [
                                 type: :string,
                                 doc: "Last update date (YYYY-MM-DD format)"
                               ]
                             )

  # Model limit options schema
  @model_limits_schema NimbleOptions.new!(
                         context: [
                           type: :pos_integer,
                           doc: "Maximum context window size in tokens"
                         ],
                         output: [
                           type: :pos_integer,
                           doc: "Maximum output tokens"
                         ],
                         rate_limit: [
                           type: :map,
                           doc: "Rate limiting configuration",
                           keys: [
                             requests_per_minute: [
                               type: :pos_integer,
                               doc: "Maximum requests per minute"
                             ],
                             tokens_per_minute: [
                               type: :pos_integer,
                               doc: "Maximum tokens per minute"
                             ],
                             requests_per_day: [
                               type: :pos_integer,
                               doc: "Maximum requests per day"
                             ]
                           ]
                         ]
                       )

  # Model cost options schema
  @model_cost_schema NimbleOptions.new!(
                       input: [
                         type: :float,
                         doc: "Cost per million input tokens"
                       ],
                       output: [
                         type: :float,
                         doc: "Cost per million output tokens"
                       ],
                       cache_read: [
                         type: :float,
                         doc: "Cost per million cached input tokens (for providers with caching)"
                       ],
                       cache_write: [
                         type: :float,
                         doc: "Cost per million tokens to write to cache"
                       ],
                       training: [
                         type: :float,
                         doc: "Cost per million training tokens (for fine-tuned models)"
                       ],
                       image: [
                         type: :float,
                         doc: "Cost per image (for image generation models)"
                       ],
                       audio: [
                         type: :float,
                         doc: "Cost per minute of audio (for audio models)"
                       ]
                     )

  # Generation parameter options schema
  @generation_options_schema NimbleOptions.new!(
                               # Core generation parameters
                               temperature: [
                                 type: :float,
                                 doc:
                                   "Controls randomness in output (0.0 to 2.0, provider-dependent)"
                               ],
                               max_tokens: [
                                 type: :pos_integer,
                                 doc: "Maximum number of tokens to generate"
                               ],
                               top_p: [
                                 type: :float,
                                 doc: "Nucleus sampling parameter (0.0 to 1.0)"
                               ],
                               top_k: [
                                 type: :pos_integer,
                                 doc: "Top-k sampling parameter"
                               ],
                               frequency_penalty: [
                                 type: :float,
                                 doc:
                                   "Penalize tokens based on frequency in the output (-2.0 to 2.0)"
                               ],
                               presence_penalty: [
                                 type: :float,
                                 doc:
                                   "Penalize tokens based on presence in the output (-2.0 to 2.0)"
                               ],
                               repetition_penalty: [
                                 type: :float,
                                 doc: "Alternative repetition penalty (provider-specific)"
                               ],

                               # Sampling control
                               seed: [
                                 type: :integer,
                                 doc: "Random seed for deterministic generation"
                               ],
                               stop: [
                                 type: {:or, [:string, {:list, :string}]},
                                 doc: "Stop sequences to end generation"
                               ],
                               stop_sequences: [
                                 type: {:list, :string},
                                 doc: "Alternative name for stop sequences (provider-specific)"
                               ],

                               # Output format
                               response_format: [
                                 type: {:or, [:map, :string]},
                                 doc: "Response format specification (e.g., JSON mode)"
                               ],
                               json_mode: [
                                 type: :boolean,
                                 doc: "Enable JSON output mode"
                               ],

                               # Advanced sampling
                               n: [
                                 type: :pos_integer,
                                 default: 1,
                                 doc: "Number of completions to generate"
                               ],
                               best_of: [
                                 type: :pos_integer,
                                 doc: "Generate best_of completions and return the best one"
                               ],
                               logprobs: [
                                 type: {:or, [:boolean, :pos_integer]},
                                 doc: "Include log probabilities in the response"
                               ],
                               echo: [
                                 type: :boolean,
                                 doc: "Echo the prompt in the response"
                               ],
                               logit_bias: [
                                 type: :map,
                                 doc: "Token ID to bias value mapping"
                               ],

                               # Tool/Function calling
                               tools: [
                                 type: {:list, :map},
                                 doc: "List of available tools/functions"
                               ],
                               tool_choice: [
                                 type: {:or, [:string, :atom, :map]},
                                 doc:
                                   "Tool selection strategy (auto, none, required, or specific tool)"
                               ],
                               functions: [
                                 type: {:list, :map},
                                 doc: "Legacy function definitions (deprecated in favor of tools)"
                               ],
                               function_call: [
                                 type: {:or, [:string, :map]},
                                 doc: "Legacy function call strategy (deprecated)"
                               ],

                               # System and context
                               system_prompt: [
                                 type: :string,
                                 doc: "System prompt to set context"
                               ],
                               system: [
                                 type: :string,
                                 doc: "Alternative name for system prompt"
                               ],
                               user: [
                                 type: :string,
                                 doc: "User identifier for tracking"
                               ],

                               # Reasoning (for models that support it)
                               reasoning: [
                                 type: {:in, [nil, false, true, "low", "auto", "high"]},
                                 doc: "Request reasoning/thinking tokens from the model"
                               ],
                               thinking: [
                                 type: :boolean,
                                 doc:
                                   "Enable thinking/reasoning tokens (Anthropic-specific beta feature)"
                               ],

                               # Streaming
                               stream: [
                                 type: :boolean,
                                 default: false,
                                 doc: "Enable streaming response"
                               ],
                               stream_format: [
                                 type: {:in, [:sse, :chunked, :json, :text]},
                                 default: :sse,
                                 doc: "Streaming transport format"
                               ],
                               chunk_timeout: [
                                 type: :pos_integer,
                                 default: 30_000,
                                 doc: "Timeout between stream chunks in milliseconds"
                               ],

                               # Provider-specific
                               provider_options: [
                                 type: :map,
                                 doc:
                                   "Provider-specific options that don't fit standard parameters"
                               ],

                               # Safety and moderation
                               safety_settings: [
                                 type: {:list, :map},
                                 doc: "Safety filter settings (Google, Anthropic)"
                               ],
                               moderation: [
                                 type: :boolean,
                                 doc: "Enable content moderation"
                               ],

                               # Caching (provider-specific)
                               cache_control: [
                                 type: :map,
                                 doc: "Cache control settings for providers that support caching"
                               ],
                               use_cache: [
                                 type: :boolean,
                                 doc: "Enable response caching"
                               ],
                               candidate_count: [
                                 type: :pos_integer,
                                 doc:
                                   "Number of response candidates to generate (Google-specific)"
                               ],

                               # OpenRouter-specific parameters
                               top_logprobs: [
                                 type: :pos_integer,
                                 doc:
                                   "Number of top log probabilities to return (OpenRouter-specific)"
                               ],
                               min_p: [
                                 type: :float,
                                 doc:
                                   "Minimum probability threshold for tokens (OpenRouter-specific)"
                               ],
                               top_a: [
                                 type: :float,
                                 doc: "Top-a sampling parameter (OpenRouter-specific)"
                               ],
                               models: [
                                 type: {:list, :string},
                                 doc: "Alternative model list for routing (OpenRouter-specific)"
                               ],
                               provider: [
                                 type: :map,
                                 doc: "Provider routing preferences (OpenRouter-specific)"
                               ],
                               usage: [
                                 type: :map,
                                 doc: "Usage tracking preferences (OpenRouter-specific)"
                               ],
                               transforms: [
                                 type: {:list, :string},
                                 doc: "Prompt transforms to apply (OpenRouter-specific)"
                               ]
                             )

  # Complete options schema combining all categories
  @complete_options_schema NimbleOptions.new!(
                             provider: [
                               type: :keyword_list,
                               doc: "Provider configuration options",
                               keys: @provider_options_schema.schema
                             ],
                             capabilities: [
                               type: :keyword_list,
                               doc: "Model capability options",
                               keys: @model_capabilities_schema.schema
                             ],
                             limits: [
                               type: :keyword_list,
                               doc: "Model limit options",
                               keys: @model_limits_schema.schema
                             ],
                             cost: [
                               type: :keyword_list,
                               doc: "Model cost options",
                               keys: @model_cost_schema.schema
                             ],
                             generation: [
                               type: :keyword_list,
                               doc: "Generation parameter options",
                               keys: @generation_options_schema.schema
                             ]
                           )

  @doc """
  Provider-level configuration options.

  These options configure the provider connection and authentication.
  """
  def provider_options_schema, do: @provider_options_schema

  @doc """
  Model capability options.

  These options describe what features and modalities a model supports.
  """
  def model_capabilities_schema, do: @model_capabilities_schema

  @doc """
  Model limit options.

  These options define the constraints and limits of a model.
  """
  def model_limits_schema, do: @model_limits_schema

  @doc """
  Model cost options.

  These options define the pricing structure for a model.
  """
  def model_cost_schema, do: @model_cost_schema

  @doc """
  Generation parameter options.

  These are runtime options that can be passed when generating text.
  """
  def generation_options_schema, do: @generation_options_schema

  @doc """
  Complete options schema combining all option categories.

  This can be used for validating a complete set of provider and generation options.
  """
  def complete_options_schema, do: @complete_options_schema

  @doc """
  Validates provider options against the schema.

  ## Examples

      iex> {:ok, result} = ReqLLM.Provider.Options.validate_provider_options(
      ...>   id: :openai,
      ...>   base_url: "https://api.openai.com/v1",
      ...>   env: ["OPENAI_API_KEY"]
      ...> )
      iex> result[:id]
      :openai
      iex> result[:base_url]
      "https://api.openai.com/v1"
      iex> result[:env]
      ["OPENAI_API_KEY"]
  """
  def validate_provider_options(opts) do
    NimbleOptions.validate(opts, @provider_options_schema)
  end

  @doc """
  Validates generation options against the schema.

  ## Examples

      iex> {:ok, result} = ReqLLM.Provider.Options.validate_generation_options(
      ...>   temperature: 0.7,
      ...>   max_tokens: 1000,
      ...>   stream: true
      ...> )
      iex> result[:temperature]
      0.7
      iex> result[:max_tokens]
      1000
      iex> result[:stream]
      true
  """
  def validate_generation_options(opts) do
    NimbleOptions.validate(opts, @generation_options_schema)
  end

  @doc """
  Validates model capabilities against the schema.

  ## Examples

      iex> {:ok, result} = ReqLLM.Provider.Options.validate_capabilities(
      ...>   id: "gpt-4",
      ...>   reasoning: true,
      ...>   tool_call: true
      ...> )
      iex> result[:id]
      "gpt-4"
      iex> result[:reasoning]
      true
      iex> result[:tool_call]
      true
  """
  def validate_capabilities(opts) do
    NimbleOptions.validate(opts, @model_capabilities_schema)
  end

  @doc """
  Validates model limits against the schema.

  ## Examples

      iex> ReqLLM.Provider.Options.validate_limits(
      ...>   context: 128000,
      ...>   output: 4096
      ...> )
      {:ok, [context: 128000, output: 4096]}
  """
  def validate_limits(opts) do
    NimbleOptions.validate(opts, @model_limits_schema)
  end

  @doc """
  Validates model cost options against the schema.

  ## Examples

      iex> ReqLLM.Provider.Options.validate_cost(
      ...>   input: 3.0,
      ...>   output: 15.0
      ...> )
      {:ok, [input: 3.0, output: 15.0]}
  """
  def validate_cost(opts) do
    NimbleOptions.validate(opts, @model_cost_schema)
  end

  @doc """
  Returns a list of all known provider option keys.
  """
  def all_provider_keys do
    @provider_options_schema.schema
    |> Keyword.keys()
  end

  @doc """
  Returns a list of all known generation option keys.
  """
  def all_generation_keys do
    @generation_options_schema.schema
    |> Keyword.keys()
  end

  @doc """
  Returns a list of all known model capability keys.
  """
  def all_capability_keys do
    @model_capabilities_schema.schema
    |> Keyword.keys()
  end

  @doc """
  Returns a list of all known model limit keys.
  """
  def all_limit_keys do
    @model_limits_schema.schema
    |> Keyword.keys()
  end

  @doc """
  Returns a list of all known model cost keys.
  """
  def all_cost_keys do
    @model_cost_schema.schema
    |> Keyword.keys()
  end

  @doc """
  Returns the base generation options schema used for end-user parameters.

  This schema contains vendor-neutral options that apply to all providers.
  Providers extend this via their provider_schema in the DSL.
  """
  def generation_schema, do: @generation_options_schema

  @doc """
  Returns the base provider configuration schema.

  This schema contains provider-level connection and configuration options.
  """
  def provider_schema_base, do: @provider_options_schema

  @doc """
  Extracts provider-specific options from a mixed options list.

  This is useful for separating standard options from provider-specific ones.

  ## Examples

      iex> opts = [temperature: 0.7, max_tokens: 100, custom_param: "value"]
      iex> ReqLLM.Provider.Options.extract_provider_options(opts)
      {[temperature: 0.7, max_tokens: 100], [custom_param: "value"]}
  """
  def extract_provider_options(opts) do
    # Handle stream? -> stream alias for backward compatibility
    opts_with_aliases =
      case Keyword.pop(opts, :stream?) do
        {nil, rest} -> rest
        {stream_value, rest} -> Keyword.put(rest, :stream, stream_value)
      end

    # Exclude provider_options from being treated as a standard generation option
    # since it's a meta-container, not an actual parameter
    known_keys = all_generation_keys() |> Enum.reject(&(&1 == :provider_options))

    {standard, custom} = Keyword.split(opts_with_aliases, known_keys)

    {standard, custom}
  end

  @doc """
  Merges options with defaults, respecting provider-specific overrides.

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
  Filters options to only include those supported by a specific provider.

  This function would typically be implemented by each provider to filter
  out unsupported options.
  """
  def filter_for_provider(opts, provider) when is_atom(provider) do
    # This would be implemented based on provider capabilities
    # For now, return all standard generation options
    {standard, _custom} = extract_provider_options(opts)
    standard
  end

  @doc """
  Extracts only generation options from a mixed options list.

  Unlike `extract_provider_options/1`, this returns only the generation 
  options without the unused remainder.

  ## Parameters

  - `opts` - Mixed options list

  ## Returns

  Keyword list containing only generation options.

  ## Examples

      iex> mixed_opts = [temperature: 0.7, custom_param: "value", max_tokens: 100]
      iex> ReqLLM.Provider.Options.extract_generation_opts(mixed_opts)
      [temperature: 0.7, max_tokens: 100]
  """
  @spec extract_generation_opts(keyword()) :: keyword()
  def extract_generation_opts(opts) do
    {generation_opts, _rest} = extract_provider_options(opts)
    generation_opts
  end
end

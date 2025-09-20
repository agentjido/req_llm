defmodule ReqLLM.Metadata do
  @moduledoc """
  Unified metadata and configuration schema definitions.

  This module consolidates all provider configuration and model metadata schemas
  into a single source of truth, providing validation for:

  - Provider connection configuration (API endpoints, authentication, timeouts)
  - Model capabilities (reasoning, tool calling, temperature support, etc.)
  - Model limits (context window, output tokens, rate limits)
  - Model costs (pricing per million tokens)

  ## Usage

      # Validate provider connection config
      {:ok, config} = ReqLLM.Metadata.validate(:connection, %{
        id: :openai,
        base_url: "https://api.openai.com/v1",
        api_key: "sk-..."
      })

      # Validate model capabilities
      {:ok, caps} = ReqLLM.Metadata.validate(:capabilities, %{
        id: "gpt-4",
        reasoning: false,
        tool_call: true
      })

      # Get schema information
      schema = ReqLLM.Metadata.schema(:capabilities)
      keys = ReqLLM.Metadata.keys(:capabilities)
  """

  @connection_schema NimbleOptions.new!(
                       id: [
                         type: :atom,
                         required: true,
                         doc: "Unique identifier for the provider (e.g., :anthropic, :openai)"
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
                         doc: "Project ID for providers that require it (e.g., Google Vertex AI)"
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

  @capabilities_schema NimbleOptions.new!(
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
                               type: {:list, {:in, [:text, :image, :audio, :video, :document]}},
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
                           doc: "Whether the model supports explicit reasoning/thinking tokens"
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

  @limits_schema NimbleOptions.new!(
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

  @costs_schema NimbleOptions.new!(
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

  @doc """
  Validates metadata using the appropriate schema.

  ## Parameters

    * `type` - Schema type (`:connection`, `:capabilities`, `:limits`, `:costs`)
    * `data` - Data to validate

  ## Returns

    * `{:ok, validated_data}` - Successfully validated data with defaults applied
    * `{:error, NimbleOptions.ValidationError}` - Validation error

  ## Examples

      {:ok, config} = ReqLLM.Metadata.validate(:connection, %{
        id: :openai,
        base_url: "https://api.openai.com/v1"
      })

      {:ok, caps} = ReqLLM.Metadata.validate(:capabilities, %{
        id: "gpt-4",
        reasoning: true
      })
  """
  @spec validate(:connection | :capabilities | :limits | :costs, map()) ::
          {:ok, map()} | {:error, NimbleOptions.ValidationError.t()}
  def validate(:connection, data), do: NimbleOptions.validate(data, @connection_schema)
  def validate(:capabilities, data), do: NimbleOptions.validate(data, @capabilities_schema)
  def validate(:limits, data), do: NimbleOptions.validate(data, @limits_schema)
  def validate(:costs, data), do: NimbleOptions.validate(data, @costs_schema)

  @doc """
  Returns the schema for a metadata type.

  ## Examples

      schema = ReqLLM.Metadata.schema(:capabilities)
      schema.schema[:id][:required]  #=> true
  """
  @spec schema(:connection | :capabilities | :limits | :costs) :: NimbleOptions.t()
  def schema(:connection), do: @connection_schema
  def schema(:capabilities), do: @capabilities_schema
  def schema(:limits), do: @limits_schema
  def schema(:costs), do: @costs_schema

  @doc """
  Returns all option keys for a schema type.

  ## Examples

      keys = ReqLLM.Metadata.keys(:capabilities)
      #=> [:id, :provider_model_id, :name, :modalities, ...]
  """
  @spec keys(:connection | :capabilities | :limits | :costs) :: [atom()]
  def keys(type) do
    schema(type).schema |> Keyword.keys()
  end

  @doc """
  Extracts HTTP client options from provider configuration.

  Takes provider config and extracts options that should be passed
  to the HTTP client (Req).

  ## Examples

      config = %{timeout: 60_000, retry_attempts: 5, api_key: "secret"}
      ReqLLM.Metadata.extract_http_options(config)
      #=> %{timeout: 60_000, retry_attempts: 5}
  """
  @spec extract_http_options(map()) :: map()
  def extract_http_options(config) do
    http_keys = [:timeout, :retry_attempts, :retry_delay]
    Map.take(config, http_keys)
  end

  @doc """
  Extracts authentication options from provider configuration.

  Takes provider config and extracts options related to authentication.

  ## Examples

      config = %{api_key: "secret", organization_id: "org-123", project_id: "proj-456"}
      ReqLLM.Metadata.extract_auth_options(config)
      #=> %{api_key: "secret", organization_id: "org-123", project_id: "proj-456"}
  """
  @spec extract_auth_options(map()) :: map()
  def extract_auth_options(config) do
    auth_keys = [:api_key, :organization_id, :project_id, :region, :deployment_id]
    Map.take(config, auth_keys)
  end

  # Whitelist of safe metadata keys to convert to atoms
  @safe_metadata_keys ~w[
    input output context text image reasoning tool_call temperature
    cache_read cache_write limit modalities capabilities cost
  ]

  @doc """
  Converts string keys in metadata maps to atoms for safe keys only.

  This prevents atom leakage by only converting known safe keys to atoms.

  ## Examples

      data = %{"input" => [:text], "unknown_key" => "value"}
      ReqLLM.Metadata.map_string_keys_to_atoms(data)
      #=> %{input: [:text], "unknown_key" => "value"}
  """
  @spec map_string_keys_to_atoms(map() | nil) :: map() | nil
  def map_string_keys_to_atoms(nil), do: nil

  def map_string_keys_to_atoms(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) and key in @safe_metadata_keys ->
        atom_key = String.to_existing_atom(key)
        {atom_key, value}

      {key, value} when is_binary(key) ->
        {key, value}

      {key, value} ->
        {key, value}
    end)
  rescue
    ArgumentError ->
      map
  end

  @doc """
  Builds capabilities map from metadata.

  ## Examples

      metadata = %{"reasoning" => true, "tool_call" => false}
      ReqLLM.Metadata.build_capabilities_from_metadata(metadata)
      #=> %{reasoning: true, tool_call: false, temperature: false, attachment: false}
  """
  @spec build_capabilities_from_metadata(map()) :: map()
  def build_capabilities_from_metadata(metadata) do
    %{
      reasoning: Map.get(metadata, "reasoning", false),
      tool_call: Map.get(metadata, "tool_call", false),
      temperature: Map.get(metadata, "temperature", false),
      attachment: Map.get(metadata, "attachment", false)
    }
  end

  @doc """
  Converts modality string values to atoms.

  ## Examples

      modalities = %{input: ["text", "image"], output: ["text"]}
      ReqLLM.Metadata.convert_modality_values(modalities)
      #=> %{input: [:text, :image], output: [:text]}
  """
  @spec convert_modality_values(map() | nil) :: map() | nil
  def convert_modality_values(nil), do: nil

  def convert_modality_values(modalities) when is_map(modalities) do
    modalities
    |> Map.new(fn
      {:input, values} when is_list(values) ->
        {:input, Enum.map(values, &String.to_atom/1)}

      {:output, values} when is_list(values) ->
        {:output, Enum.map(values, &String.to_atom/1)}

      {key, value} ->
        {key, value}
    end)
  end

  @doc """
  Merges model metadata with defaults for missing fields.

  ## Examples

      ReqLLM.Metadata.merge_with_defaults(nil, %{context: 4096})
      #=> %{context: 4096}

      ReqLLM.Metadata.merge_with_defaults(%{output: 1024}, %{context: 4096, output: 2048})
      #=> %{context: 4096, output: 1024}
  """
  @spec merge_with_defaults(map() | nil, map()) :: map()
  def merge_with_defaults(nil, defaults), do: defaults
  def merge_with_defaults(existing, defaults), do: Map.merge(defaults, existing)

  @doc """
  Parses a provider string to a valid provider atom.

  Converts hyphenated provider names to underscored atoms and validates
  against the list of supported providers.

  ## Parameters

  - `str` - Provider name string (e.g., "anthropic", "google-vertex")

  ## Returns

  `{:ok, atom}` if provider is valid, `{:error, reason}` otherwise.

  ## Examples

      ReqLLM.Metadata.parse_provider("anthropic")
      #=> {:ok, :anthropic}

      ReqLLM.Metadata.parse_provider("google-vertex")
      #=> {:ok, :google_vertex}

      ReqLLM.Metadata.parse_provider("unknown")
      #=> {:error, "Unknown provider: unknown"}
  """
  @spec parse_provider(String.t()) :: {:ok, atom()} | {:error, String.t()}
  def parse_provider(str) when is_binary(str) do
    atom_candidate = String.replace(str, "-", "_")

    try do
      atom = String.to_existing_atom(atom_candidate)

      if atom in valid_providers() do
        {:ok, atom}
      else
        {:error, "Unsupported provider: #{str}"}
      end
    rescue
      ArgumentError -> {:error, "Unknown provider: #{str}"}
    end
  end

  @doc """
  Gets the default model for a provider spec.

  Falls back to the first available model if no default is specified.

  ## Parameters

  - `spec` - Provider spec struct with `:default_model` and `:models` fields

  ## Returns

  The default model string, or `nil` if no models are available.

  ## Examples

      spec = %{default_model: "gpt-4", models: %{"gpt-3.5" => %{}, "gpt-4" => %{}}}
      ReqLLM.Metadata.default_model(spec)
      #=> "gpt-4"

      spec = %{default_model: nil, models: %{"model-a" => %{}, "model-b" => %{}}}
      ReqLLM.Metadata.default_model(spec)
      #=> "model-a"

      spec = %{default_model: nil, models: %{}}
      ReqLLM.Metadata.default_model(spec)
      #=> nil
  """
  @spec default_model(map()) :: binary() | nil
  def default_model(spec) do
    spec.default_model ||
      case Map.keys(spec.models) do
        [first_model | _] -> first_model
        [] -> nil
      end
  end

  defp valid_providers do
    ReqLLM.Provider.Generated.ValidProviders.list()
  rescue
    UndefinedFunctionError ->
      []
  end
end

defmodule ReqLLM.Provider.Config do
  @moduledoc """
  Provider connection configuration schema.

  This module defines validation schemas for provider-level connection
  settings like API endpoints, authentication, timeouts, and retry behavior.
  This is separate from runtime generation options and model metadata.

  ## Usage

  These schemas are used for:
  1. Provider registration and setup
  2. Connection parameter validation
  3. HTTP client configuration
  4. Authentication setup

  ## Examples

      # Validate provider configuration
      config = %{
        id: :openai,
        base_url: "https://api.openai.com/v1",
        api_key: "sk-...",
        timeout: 30_000
      }
      {:ok, validated} = ReqLLM.Provider.Config.validate(config)
  """

  # Provider connection configuration schema
  @config_schema NimbleOptions.new!(
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
                     doc: "API key for authentication (can also be set via environment variable)"
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

  @doc """
  Returns the provider configuration schema.
  """
  def schema, do: @config_schema

  @doc """
  Validates provider configuration.

  ## Examples

      iex> config = %{id: :openai, base_url: "https://api.openai.com/v1"}
      iex> ReqLLM.Provider.Config.validate(config)
      {:ok, %{id: :openai, base_url: "https://api.openai.com/v1", env: [], timeout: 30_000, retry_attempts: 3, retry_delay: 1000}}
  """
  def validate(config) do
    NimbleOptions.validate(config, @config_schema)
  end

  @doc """
  Returns all configuration option keys.
  """
  def keys do
    @config_schema.schema |> Keyword.keys()
  end

  @doc """
  Extracts HTTP client options from provider configuration.

  Takes provider config and extracts options that should be passed
  to the HTTP client (Req).

  ## Examples

      iex> config = %{timeout: 60_000, retry_attempts: 5, api_key: "secret"}
      iex> ReqLLM.Provider.Config.extract_http_options(config)
      %{timeout: 60_000, retry_attempts: 5}
  """
  def extract_http_options(config) do
    http_keys = [:timeout, :retry_attempts, :retry_delay]
    Map.take(config, http_keys)
  end

  @doc """
  Extracts authentication options from provider configuration.

  Takes provider config and extracts options related to authentication.

  ## Examples

      iex> config = %{api_key: "secret", organization_id: "org-123", project_id: "proj-456"}
      iex> ReqLLM.Provider.Config.extract_auth_options(config)
      %{api_key: "secret", organization_id: "org-123", project_id: "proj-456"}
  """
  def extract_auth_options(config) do
    auth_keys = [:api_key, :organization_id, :project_id, :region, :deployment_id]
    Map.take(config, auth_keys)
  end
end

defmodule ReqLLM.Providers.Zai do
  @moduledoc """
  Z.AI provider – OpenAI-compatible Chat Completions API (Standard Endpoint).

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults.
  No custom request/response handling needed – leverages the standard OpenAI wire format.

  This provider uses the Z.AI **standard endpoint** (`/api/paas/v4`) for general-purpose
  chat and reasoning tasks. For code generation optimized responses, use the `zai_coder`
  provider.

  ## Supported Models

  - glm-4.5 - Advanced reasoning model with 131K context
  - glm-4.5-air - Lighter variant with same capabilities
  - glm-4.5-flash - Free tier model with fast inference
  - glm-4.5v - Vision model supporting text, image, and video inputs
  - glm-4.6 - Latest model with 204K context and improved reasoning

  ## Configuration

      # Add to .env file (automatically loaded)
      ZAI_API_KEY=your-api-key
  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :zai,
    base_url: "https://api.z.ai/api/paas/v4",
    metadata: "priv/models_dev/zai.json",
    default_env_key: "ZAI_API_KEY",
    provider_schema: []

  @impl ReqLLM.Provider
  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @impl ReqLLM.Provider
  def extract_usage(%{"usage" => u}, _), do: {:ok, u}
  def extract_usage(_, _), do: {:error, :no_usage}
end

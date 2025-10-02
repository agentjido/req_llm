defmodule ReqLLM.Providers.Cerebras do
  @moduledoc """
  Cerebras provider – OpenAI-compatible Chat Completions API with ultra-fast inference.

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults.
  No custom request/response handling needed – leverages the standard OpenAI wire format.

  ## Cerebras-Specific Notes

  - System messages have stronger influence compared to OpenAI's implementation
  - Streaming not supported with reasoning models in JSON mode or tool calling
  - Some OpenAI features are not supported (see unsupported features below)

  ## Unsupported OpenAI Features

  The following fields will result in a 400 error if supplied:
  - `frequency_penalty`
  - `logit_bias`
  - `presence_penalty`
  - `parallel_tool_calls`
  - `service_tier`

  ## Configuration

      # Add to .env file (automatically loaded)
      CEREBRAS_API_KEY=csk_...
  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :cerebras,
    base_url: "https://api.cerebras.ai/v1",
    metadata: "priv/models_dev/cerebras.json",
    default_env_key: "CEREBRAS_API_KEY",
    provider_schema: []

  @impl ReqLLM.Provider
  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @impl ReqLLM.Provider
  def extract_usage(%{"usage" => u}, _), do: {:ok, u}
  def extract_usage(_, _), do: {:error, :no_usage}
end

defmodule ReqLLM.Providers.VLLM do
  @moduledoc """
  vLLM provider – self-hosted OpenAI-compatible Chat Completions API.

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults.
  vLLM is fully OpenAI-compatible, so no custom request/response handling is needed.

  ## Self-Hosted Configuration

  vLLM is a self-hosted inference server. Users must:

  1. Deploy a vLLM service (via pip install, Docker, or other methods)
  2. Configure the model to serve (e.g., `--served-model-name my-model`)
  3. Set the base_url to point to their vLLM instance

  Since vLLM runs multiple models on different ports, use the `:base_url` option
  per-request or configure model entries with their specific URLs.

  ## Authentication

  By default, vLLM uses OPENAI_API_KEY as an environment variable.
  The presence of a value is required but typically not validated by vLLM.
  Set any non-empty value if authentication is not configured on your vLLM server.

  ## Configuration

      # Add to .env file (automatically loaded)
      OPENAI_API_KEY=any-value-for-vllm

  ## Examples

      # Basic usage with default localhost
      ReqLLM.generate_text("vllm:my-local-model", "Hello!")

      # With custom base_url for a specific vLLM instance
      ReqLLM.generate_text("vllm:llama-3", "Hello!",
        base_url: "http://my-server:8001/v1"
      )

      # Streaming
      ReqLLM.stream_text("vllm:mistral-7b", "Tell me a story")
      |> Enum.each(&IO.write/1)
  """

  use ReqLLM.Provider,
    id: :vllm,
    default_base_url: "http://localhost:8000/v1",
    default_env_key: "OPENAI_API_KEY"

  use ReqLLM.Provider.Defaults

  @provider_schema []
end

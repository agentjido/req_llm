defmodule ReqLLM.Providers.LiteLLM do
  @moduledoc """
  LiteLLM provider – self-hosted OpenAI-compatible proxy and gateway.

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults.
  LiteLLM's proxy exposes OpenAI-compatible chat and embedding endpoints, so no
  custom request or response handling is needed for the initial provider path.

  ## Default Base URL

  LiteLLM's quick-start proxy listens on `http://localhost:4000`, which matches
  the official docs examples for OpenAI-compatible clients.

  ## Authentication

  Set `LITELLM_API_KEY` to your LiteLLM master key when proxy auth is enabled.
  If proxy auth is disabled, LiteLLM still expects an OpenAI-style API key field,
  so any non-empty placeholder value works.

  ## Examples

      ReqLLM.generate_text("litellm:gpt-5", "Hello!")

      ReqLLM.generate_text(
        "litellm:anthropic-sonnet",
        "Hello!",
        base_url: "https://litellm.example.com"
      )
  """

  use ReqLLM.Provider,
    id: :litellm,
    default_base_url: "http://localhost:4000",
    default_env_key: "LITELLM_API_KEY"

  use ReqLLM.Provider.Defaults

  @provider_schema []
end

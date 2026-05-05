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

  ## Provider Options

  The following options can be passed via `provider_options`:

  - `:thinking` - Map to control the thinking/reasoning mode. Set to
    `%{type: "disabled"}` to disable thinking mode for faster responses,
    or `%{type: "enabled"}` to enable extended reasoning.

  Example:

      ReqLLM.generate_text("zai:glm-4.5-flash", context,
        provider_options: [thinking: %{type: "disabled"}]
      )
  """

  alias ReqLLM.Providers.Zai.Shared

  use ReqLLM.Provider,
    id: :zai,
    default_base_url: "https://api.z.ai/api/paas/v4",
    default_env_key: "ZAI_API_KEY"

  @provider_schema Shared.provider_schema()

  @impl ReqLLM.Provider
  def prepare_request(operation, model_spec, input, opts),
    do: Shared.prepare_request(__MODULE__, operation, model_spec, input, opts)

  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts),
    do: Shared.attach(__MODULE__, request, model_input, user_opts)

  @impl ReqLLM.Provider
  defdelegate translate_options(operation, model, opts), to: Shared

  @impl ReqLLM.Provider
  def decode_response(request_response),
    do: Shared.decode_response(request_response, :zai)

  @impl ReqLLM.Provider
  defdelegate encode_body(request), to: Shared

  @impl ReqLLM.Provider
  defdelegate extract_usage(body, model), to: Shared
end

defmodule ReqLLM.Providers.ZaiCodingPlan do
  @moduledoc """
  Z.AI Coding Plan provider – alias for zai_coder.

  This provider is an alias that delegates to the ZaiCoder provider implementation.
  It uses the same API endpoint and configuration as zai_coder.

  ## Implementation

  This provider uses the Z.AI coding endpoint (`/api/coding/paas/v4`) which is
  optimized for code generation and technical tasks.

  ## Supported Models

  - glm-4.5 - Advanced reasoning model with 131K context
  - glm-4.5-air - Lighter variant with same capabilities
  - glm-4.5-flash - Free tier model with fast inference
  - glm-4.5v - Vision model supporting text, image, and video inputs
  - glm-4.6 - Latest model with 204K context and improved reasoning
  - glm-4.6v - Vision variant of glm-4.6
  - glm-4.7 - Latest model with 204K context

  ## Configuration

      # Add to .env file (automatically loaded)
      ZAI_API_KEY=your-api-key

  ## Provider Options

  The following options can be passed via `provider_options`:

  - `:thinking` - Map to control the thinking/reasoning mode. Set to
    `%{type: "disabled"}` to disable thinking mode for faster responses,
    or `%{type: "enabled"}` to enable extended reasoning.

  Example:

      ReqLLM.generate_text("zai_coding_plan:glm-4.7", context,
        provider_options: [thinking: %{type: "disabled"}]
      )
  """

  use ReqLLM.Provider,
    id: :zai_coding_plan,
    default_base_url: "https://api.z.ai/api/coding/paas/v4",
    default_env_key: "ZAI_API_KEY"

  # Delegate all callbacks to ReqLLM.Providers.ZaiCoder
  defdelegate prepare_request(operation, model_spec, input, opts),
    to: ReqLLM.Providers.ZaiCoder

  defdelegate attach(request, model_input, user_opts), to: ReqLLM.Providers.ZaiCoder

  defdelegate encode_body(request), to: ReqLLM.Providers.ZaiCoder

  defdelegate decode_response(request_response), to: ReqLLM.Providers.ZaiCoder

  defdelegate translate_options(operation, model, opts), to: ReqLLM.Providers.ZaiCoder

  defdelegate extract_usage(data, model), to: ReqLLM.Providers.ZaiCoder
end

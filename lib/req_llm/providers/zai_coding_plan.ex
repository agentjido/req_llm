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

  @provider_schema [
    thinking: [
      type: :map,
      doc:
        ~s(Control thinking/reasoning mode. Set to %{type: "disabled"} to disable or %{type: "enabled"} to enable.)
    ]
  ]

  # Delegate all callbacks to ReqLLM.Providers.ZaiCoder
  @impl ReqLLM.Provider
  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    context = Map.get(request.options, :context)

    default_timeout =
      if context && Map.get(context, :__thinking_mode__, false) do
        Application.get_env(:req_llm, :thinking_timeout, 300_000)
      else
        Application.get_env(:req_llm, :receive_timeout, 120_000)
      end

    timeout = Keyword.get(user_opts, :receive_timeout, default_timeout)

    updated_request =
      request
      |> Map.update!(:options, fn opts ->
        opts
        |> Map.put(:receive_timeout, timeout)
        |> Map.put(:pool_timeout, timeout)
        |> Map.put(:connect_options, timeout: timeout)
      end)

    ReqLLM.Provider.Defaults.default_attach(__MODULE__, updated_request, model_input, user_opts)
  end

  defdelegate encode_body(request), to: ReqLLM.Providers.ZaiCoder

  defdelegate decode_response(request_response), to: ReqLLM.Providers.ZaiCoder

  defdelegate translate_options(operation, model, opts), to: ReqLLM.Providers.ZaiCoder

  defdelegate extract_usage(data, model), to: ReqLLM.Providers.ZaiCoder

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    ReqLLM.Provider.Defaults.default_attach_stream(__MODULE__, model, context, opts, finch_name)
  end

  defdelegate decode_stream_event(event, model), to: ReqLLM.Providers.ZaiCoder
end

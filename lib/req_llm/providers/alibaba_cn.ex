defmodule ReqLLM.Providers.AlibabaCN do
  @moduledoc """
  Alibaba Cloud Bailian (DashScope) provider – China/Beijing endpoint.

  OpenAI-compatible Chat Completions API for Qwen family models via DashScope,
  using the mainland China endpoint (`dashscope.aliyuncs.com`).

  This provider shares the same DashScope API key and parameter schema as
  `ReqLLM.Providers.Alibaba` but targets the Beijing region endpoint for
  lower latency within mainland China.

  ## Configuration

      # Add to .env file (automatically loaded)
      DASHSCOPE_API_KEY=your-api-key

  ## Examples

      # Basic usage
      ReqLLM.generate_text("alibaba_cn:qwen-plus", "Hello!")

      # With search enabled
      ReqLLM.generate_text("alibaba_cn:qwen-plus", "What happened today?",
        provider_options: [enable_search: true]
      )
  """

  use ReqLLM.Provider,
    id: :alibaba_cn,
    default_base_url: "https://dashscope.aliyuncs.com/compatible-mode/v1",
    default_env_key: "DASHSCOPE_API_KEY"

  alias ReqLLM.Providers.Alibaba.Shared

  @provider_schema Shared.provider_schema()

  def supported_provider_options, do: Shared.supported_provider_options()

  @impl ReqLLM.Provider
  defdelegate translate_options(operation, model, opts), to: Shared

  @impl ReqLLM.Provider
  defdelegate build_body(request), to: Shared

  @impl ReqLLM.Provider
  defdelegate encode_body(request), to: Shared

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    Shared.attach_stream(__MODULE__, model, context, opts, finch_name)
  end
end

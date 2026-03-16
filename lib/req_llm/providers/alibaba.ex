defmodule ReqLLM.Providers.Alibaba do
  @moduledoc """
  Alibaba Cloud Bailian (DashScope) provider – international endpoint.

  OpenAI-compatible Chat Completions API for Qwen family models via DashScope.

  ## Implementation

  Uses built-in OpenAI-style encoding/decoding defaults with DashScope-specific
  extensions for search, thinking/reasoning, and vision parameters.

  ## DashScope-Specific Extensions

  Beyond standard OpenAI parameters, DashScope supports provider-specific options
  as top-level body keys:

  - `enable_search` - Enable internet search integration
  - `search_options` - Search configuration (strategy, source citation)
  - `enable_thinking` - Activate deep thinking mode for hybrid reasoning
  - `thinking_budget` - Maximum token length for thinking process
  - `top_k` - Candidate token pool size for sampling
  - `repetition_penalty` - Penalise repeated tokens
  - `enable_code_interpreter` - Activate code execution
  - `vl_high_resolution_images` - Increase vision input pixel limit
  - `incremental_output` - Streaming: send incremental chunks only

  See `provider_schema/0` for the complete DashScope-specific schema and
  `ReqLLM.Provider.Options` for inherited OpenAI parameters.

  ## Configuration

      # Add to .env file (automatically loaded)
      DASHSCOPE_API_KEY=your-api-key

  ## Examples

      # Basic usage
      ReqLLM.generate_text("alibaba:qwen-plus", "Hello!")

      # With search enabled
      ReqLLM.generate_text("alibaba:qwen-plus", "What happened today?",
        provider_options: [enable_search: true]
      )

      # With thinking mode
      ReqLLM.generate_text("alibaba:qwen-plus", "Solve this step by step",
        provider_options: [enable_thinking: true, thinking_budget: 4096]
      )
  """

  use ReqLLM.Provider,
    id: :alibaba,
    default_base_url: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
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

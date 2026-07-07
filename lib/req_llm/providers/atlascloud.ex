defmodule ReqLLM.Providers.AtlasCloud do
  @moduledoc """
  Atlas Cloud provider using the OpenAI-compatible Chat Completions API.

  Atlas Cloud exposes text models through `https://api.atlascloud.ai/v1`, so this
  provider reuses ReqLLM's OpenAI-compatible request, response, and streaming defaults.

  ## Configuration

      ATLASCLOUD_API_KEY=your-api-key

  ## Examples

      ReqLLM.generate_text("atlascloud:qwen/qwen3.5-flash", "Hello!")

      ReqLLM.stream_text("atlascloud:deepseek-ai/deepseek-v4-pro", "Tell me a story",
        max_tokens: 512
      )
  """

  use ReqLLM.Provider,
    id: :atlascloud,
    default_base_url: "https://api.atlascloud.ai/v1",
    default_env_key: "ATLASCLOUD_API_KEY"

  use ReqLLM.Provider.Defaults

  @provider_schema []

  @impl ReqLLM.Provider
  def prepare_request(operation, _model_spec, _input, _opts)
      when operation in [:embedding, :transcription, :speech] do
    unsupported_operation(operation)
  end

  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  defp unsupported_operation(operation) do
    supported_operations = [:chat, :object]

    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: #{inspect(operation)} not supported by #{inspect(__MODULE__)}. Supported operations: #{inspect(supported_operations)}"
     )}
  end
end

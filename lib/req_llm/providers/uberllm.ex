defmodule ReqLLM.Providers.UberLLM do
  @moduledoc """
  UberLLM provider using the OpenAI-compatible Chat Completions API.

  UberLLM exposes text models from many vendors through `https://api.uberllm.dev/v1`, so this
  provider reuses ReqLLM's OpenAI-compatible request, response, and streaming defaults.
  Model IDs use the `vendor/model` form, for example `deepseek/deepseek-v4.1-flash`.
  `GET https://api.uberllm.dev/v1/models` lists the available chat models without a key.

  ## Configuration

      UBERLLM_API_KEY=your-api-key

  ## Examples

      ReqLLM.generate_text("uberllm:deepseek/deepseek-v4.1-flash", "Hello!")

      ReqLLM.stream_text("uberllm:anthropic/claude-sonnet-5", "Tell me a story",
        max_tokens: 512
      )
  """

  use ReqLLM.Provider,
    id: :uberllm,
    default_base_url: "https://api.uberllm.dev/v1",
    default_env_key: "UBERLLM_API_KEY"

  alias ReqLLM.Provider.Defaults

  @provider_schema []
  @supported_operations [:chat, :object]

  @impl ReqLLM.Provider
  def prepare_request(operation, model_spec, input, opts)
      when operation in @supported_operations do
    Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  def prepare_request(operation, _model_spec, _input, _opts) do
    unsupported_operation(operation)
  end

  defp unsupported_operation(operation) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: #{inspect(operation)} not supported by #{inspect(__MODULE__)}. Supported operations: #{inspect(@supported_operations)}"
     )}
  end
end

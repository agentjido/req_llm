defmodule ReqLLM.Providers.CheaperInference do
  @moduledoc """
  Cheaper Inference provider using the OpenAI-compatible Chat Completions API.

  Cheaper Inference exposes text models through `https://api.cheaperinference.com/v1`, so this
  provider reuses ReqLLM's OpenAI-compatible request, response, and streaming defaults.

  ## Configuration

      CHEAPERINFERENCE_API_KEY=your-api-key

  ## Examples

      ReqLLM.generate_text("cheaperinference:gpt-5.4-mini", "Hello!")

      ReqLLM.stream_text("cheaperinference:claude-sonnet-5", "Tell me a story",
        max_tokens: 512
      )
  """

  use ReqLLM.Provider,
    id: :cheaperinference,
    default_base_url: "https://api.cheaperinference.com/v1",
    default_env_key: "CHEAPERINFERENCE_API_KEY"

  use ReqLLM.Provider.Defaults

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

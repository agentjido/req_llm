defmodule ReqLLM.Providers.StepFun do
  @moduledoc """
  StepFun China provider for chat, speech generation, and transcription.

  Set `STEPFUN_API_KEY` to use this provider. Speech and transcription use
  `ReqLLM.speak/3` and `ReqLLM.transcribe/3`. See the StepFun guide.
  """

  use ReqLLM.Provider,
    id: :stepfun,
    default_base_url: "https://api.stepfun.com/v1",
    default_env_key: "STEPFUN_API_KEY"

  use ReqLLM.Provider.Defaults

  alias ReqLLM.Providers.StepFun.Shared

  @provider_schema Shared.provider_schema()

  @impl ReqLLM.Provider
  def prepare_request(operation, model_spec, input, opts) do
    Shared.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @impl ReqLLM.Provider
  def build_body(request), do: Shared.build_body(request)

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, finch_name) do
    Shared.attach_stream(__MODULE__, model, context, opts, finch_name)
  end
end

defmodule ReqLLM.Router do
  @moduledoc """
  A behaviour for application-defined model routers.

  A router is any struct whose module implements `c:resolve/2`. ReqLLM gives the
  callback a normalized `ReqLLM.Router.Request`. The callback must return a
  concrete `%LLMDB.Model{}`.

      defmodule MyApp.ModelRouter do
        @behaviour ReqLLM.Router

        defstruct fast_model: "openai:gpt-4o-mini",
                  deep_model: "anthropic:claude-sonnet-4-5"

        @impl true
        def resolve(router, %ReqLLM.Router.Request{} = request) do
          model_spec =
            if request.requirements.reasoning_effort in [:high, :xhigh] do
              router.deep_model
            else
              router.fast_model
            end

          ReqLLM.model(model_spec)
        end
      end

      router = %MyApp.ModelRouter{}
      ReqLLM.generate_text(router, "Hello")

  ReqLLM does not provide a routing policy. The callback can use local rules,
  an evaluation model, or another service.
  """

  alias ReqLLM.Router.Request

  @type t :: struct()

  @callback resolve(t(), Request.t()) ::
              {:ok, LLMDB.Model.t()} | {:error, term()}

  @doc "Returns true when a struct implements the router behaviour."
  @spec implementation?(term()) :: boolean()
  def implementation?(%{__struct__: module}) when is_atom(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :resolve, 2) and
      __MODULE__ in behaviours(module)
  end

  def implementation?(_value), do: false

  @doc "Resolves an application router to a concrete LLMDB model."
  @spec resolve(t(), Request.t()) :: {:ok, LLMDB.Model.t()} | {:error, term()}
  def resolve(%{__struct__: module} = router, %Request{} = request) do
    if implementation?(router) do
      case module.resolve(router, request) do
        {:ok, %LLMDB.Model{} = model} -> {:ok, model}
        {:error, _reason} = error -> error
        other -> invalid_callback_result(module, other)
      end
    else
      invalid_router(router)
    end
  end

  def resolve(router, %Request{}), do: invalid_router(router)

  defp behaviours(module) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  rescue
    _error -> []
  end

  defp invalid_router(_router) do
    {:error,
     ReqLLM.Error.validation_error(
       :invalid_router,
       "router must be a struct whose module implements ReqLLM.Router"
     )}
  end

  defp invalid_callback_result(module, _result) do
    {:error,
     ReqLLM.Error.validation_error(
       :invalid_router_result,
       "#{inspect(module)}.resolve/2 must return {:ok, %LLMDB.Model{}} or {:error, reason}"
     )}
  end
end

defmodule ReqLLM.Router do
  @moduledoc """
  A dynamic model input that resolves through application code.

  A router module implements `c:resolve/4` and returns any normal ReqLLM model
  specification. ReqLLM validates that specification and continues the request
  with the resulting `%LLMDB.Model{}`.

      defmodule MyApp.ModelRouter do
        @behaviour ReqLLM.Router

        @impl true
        def resolve(_router, :chat, prompt, _opts) do
          if String.length(prompt) < 200 do
            {:ok, "openai:gpt-4o-mini"}
          else
            {:ok, "anthropic:claude-sonnet-4-5"}
          end
        end
      end

      router = ReqLLM.Router.new!(MyApp.ModelRouter)
      ReqLLM.generate_text(router, "Hello")

  The callback is fully application-defined. It can use local rules, a trie,
  an evaluation model, or another service. It must return a concrete model
  specification, not another router.
  """

  @schema Zoi.struct(__MODULE__, %{
            module: Zoi.atom() |> Zoi.required(),
            options: Zoi.any() |> Zoi.default([])
          })

  @type operation :: :chat | :object
  @type t :: unquote(Zoi.type_spec(@schema))

  @callback resolve(t(), operation(), term(), keyword()) ::
              {:ok, ReqLLM.static_model_input()} | {:error, term()}

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a router."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Creates a router backed by a module that implements this behaviour."
  @spec new(module(), term()) :: {:ok, t()} | {:error, term()}
  def new(module, options \\ []) do
    with {:ok, router} <- Zoi.parse(@schema, %__MODULE__{module: module, options: options}),
         :ok <- validate_module(router.module) do
      {:ok, router}
    end
  end

  @doc "Creates a router and raises when its module is invalid."
  @spec new!(module(), term()) :: t()
  def new!(module, options \\ []) do
    case new(module, options) do
      {:ok, router} -> router
      {:error, error} -> raise ArgumentError, format_error(error)
    end
  end

  @doc false
  @spec resolve(t(), operation(), term(), keyword()) ::
          {:ok, LLMDB.Model.t()} | {:error, term()}
  def resolve(%__MODULE__{module: module} = router, operation, input, opts)
      when operation in [:chat, :object] and is_list(opts) do
    with :ok <- validate_module(module),
         {:ok, model_spec} <- module.resolve(router, operation, input, opts),
         :ok <- reject_nested_router(model_spec) do
      ReqLLM.model(model_spec)
    else
      {:error, _reason} = error -> error
      other -> invalid_callback_result(module, other)
    end
  end

  defp validate_module(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :resolve, 4) do
      :ok
    else
      {:error,
       ReqLLM.Error.validation_error(
         :invalid_router_module,
         "router module must export resolve/4",
         module: module
       )}
    end
  end

  defp validate_module(module) do
    {:error,
     ReqLLM.Error.validation_error(
       :invalid_router_module,
       "router module must be an atom",
       module: module
     )}
  end

  defp reject_nested_router(%__MODULE__{}) do
    {:error,
     ReqLLM.Error.validation_error(
       :nested_router,
       "router callbacks must return a concrete model specification"
     )}
  end

  defp reject_nested_router(_model_spec), do: :ok

  defp invalid_callback_result(module, result) do
    {:error,
     ReqLLM.Error.validation_error(
       :invalid_router_result,
       "#{inspect(module)}.resolve/4 must return {:ok, model_spec} or {:error, reason}",
       result: result
     )}
  end

  defp format_error(error) when is_exception(error), do: Exception.message(error)
  defp format_error(error), do: inspect(error)
end

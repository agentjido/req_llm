defmodule ReqLLM.Router.Request do
  @moduledoc """
  The normalized input for an application model router.

  The request has two fields:

    * `context` is the normalized conversation and tools.
    * `routing_context` is opaque application data for model selection.

  ReqLLM passes `routing_context` unchanged and does not add derived values such
  as the generation operation, streaming state, output schema, provider
  credentials, generation options, or transport options. Applications that need
  one of these values for routing must include it explicitly in
  `routing_context`.
  """

  @schema Zoi.struct(__MODULE__, %{
            context: Zoi.struct(ReqLLM.Context) |> Zoi.required(),
            routing_context: Zoi.map() |> Zoi.default(%{})
          })

  @typedoc "Opaque application data used to select a model."
  @type routing_context :: map()

  @type t :: %__MODULE__{
          context: ReqLLM.Context.t(),
          routing_context: routing_context()
        }

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a normalized router request."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a normalized router request."
  @spec new(ReqLLM.Context.prompt(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def new(input, opts \\ []) do
    with {:ok, request, _request_opts} <- build(input, opts) do
      {:ok, request}
    end
  end

  @doc false
  @spec build(ReqLLM.Context.prompt(), keyword()) ::
          {:ok, t(), keyword()} | {:error, term()}
  def build(input, opts) when is_list(opts) do
    {routing_context, request_opts} = Keyword.pop(opts, :routing_context, %{})

    with :ok <- validate_routing_context(routing_context),
         {:ok, context} <- ReqLLM.Context.normalize(input, request_opts),
         {:ok, request} <-
           Zoi.parse(@schema, %__MODULE__{
             context: context,
             routing_context: routing_context
           }) do
      {:ok, request, request_opts}
    end
  end

  defp validate_routing_context(value) when is_map(value), do: :ok

  defp validate_routing_context(value) do
    {:error,
     ReqLLM.Error.validation_error(
       :invalid_routing_context,
       "routing_context must be a map",
       value: value
     )}
  end
end

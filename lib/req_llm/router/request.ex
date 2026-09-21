defmodule ReqLLM.Router.Request do
  @moduledoc """
  The normalized input for an application model router.

  The request contains the public API surface, the provider operation, a
  normalized context, derived requirements, and explicit application routing
  data. Provider credentials and transport options are not included.
  """

  @schema Zoi.struct(__MODULE__, %{
            surface: Zoi.enum([:generate_text, :stream_text, :generate_object, :stream_object]),
            operation: Zoi.enum([:chat, :object]),
            context: Zoi.any() |> Zoi.required(),
            requirements: Zoi.map() |> Zoi.required(),
            routing_context: Zoi.map() |> Zoi.default(%{})
          })

  @type surface :: :generate_text | :stream_text | :generate_object | :stream_object
  @type operation :: :chat | :object
  @type requirements :: %{
          required(:streaming?) => boolean(),
          required(:structured_output?) => boolean(),
          required(:tools?) => boolean(),
          required(:reasoning_effort) => atom() | nil
        }
  @type t :: %__MODULE__{
          surface: surface(),
          operation: operation(),
          context: ReqLLM.Context.t(),
          requirements: requirements(),
          routing_context: map()
        }

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for a normalized router request."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a normalized router request."
  @spec new(surface(), operation(), ReqLLM.Context.prompt(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def new(surface, operation, input, opts \\ []) do
    with {:ok, request, _request_opts} <- build(surface, operation, input, opts) do
      {:ok, request}
    end
  end

  @doc false
  @spec build(surface(), operation(), ReqLLM.Context.prompt(), keyword()) ::
          {:ok, t(), keyword()} | {:error, term()}
  def build(surface, operation, input, opts) when is_list(opts) do
    {routing_context, request_opts} = Keyword.pop(opts, :routing_context, %{})

    with :ok <- validate_routing_context(routing_context),
         {:ok, context} <- ReqLLM.Context.normalize(input, request_opts),
         {:ok, request} <-
           Zoi.parse(@schema, %__MODULE__{
             surface: surface,
             operation: operation,
             context: context,
             requirements: requirements(surface, operation, context, request_opts),
             routing_context: routing_context
           }) do
      {:ok, request, request_opts}
    end
  end

  defp requirements(surface, operation, context, opts) do
    %{
      streaming?: surface in [:stream_text, :stream_object],
      structured_output?: operation == :object,
      tools?: context.tools != [],
      reasoning_effort: Keyword.get(opts, :reasoning_effort)
    }
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

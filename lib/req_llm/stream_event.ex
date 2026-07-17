defmodule ReqLLM.StreamEvent do
  @moduledoc """
  A tagged, provider-neutral projection of one streaming event.

  Events are computed from the existing `ReqLLM.StreamChunk` stream. They do
  not replace chunks in ReqLLM 1.x and are not stored on
  `ReqLLM.StreamResponse`.

  The event stream begins with `:start` and ends with exactly one of
  `:finish`, `:cancelled`, or `:error` when it is consumed to completion.
  Output deltas retain their arrival order. Provider-specific metadata is
  exposed through `:provider_event` and event metadata without treating raw
  provider frames as part of the canonical contract.

  ## Event types

  - `:start` carries the resolved provider and model identity.
  - `:text_delta` and `:reasoning_delta` carry string deltas.
  - `:tool_call_start` and `:tool_call_delta` carry incremental tool input;
    `:tool_call` carries the assembled call before the terminal event.
  - `:tool_result` carries a result already present in provider metadata. It
    does not execute a tool or continue a model loop.
  - `:source`, `:file`, and `:output_item` carry
    `ReqLLM.Response.OutputItem` projections.
  - `:usage` carries the final usage map and `:warning` carries one warning.
  - `:finish`, `:cancelled`, and `:error` are mutually exclusive terminal
    events.
  - `:provider_event` carries sanitized extension metadata that has no
    provider-neutral event type.
  """

  @event_types [
    :start,
    :text_delta,
    :reasoning_delta,
    :tool_call_start,
    :tool_call_delta,
    :tool_call,
    :tool_result,
    :source,
    :file,
    :output_item,
    :usage,
    :warning,
    :finish,
    :cancelled,
    :error,
    :provider_event
  ]

  @output_types [
    :text_delta,
    :reasoning_delta,
    :tool_call_start,
    :tool_call_delta,
    :tool_call,
    :tool_result,
    :source,
    :file,
    :output_item
  ]

  @terminal_types [:finish, :cancelled, :error]

  @schema Zoi.struct(__MODULE__, %{
            type: Zoi.enum(@event_types),
            data: Zoi.any() |> Zoi.default(nil),
            metadata: Zoi.map() |> Zoi.default(%{})
          })

  @type event_type ::
          :start
          | :text_delta
          | :reasoning_delta
          | :tool_call_start
          | :tool_call_delta
          | :tool_call
          | :tool_result
          | :source
          | :file
          | :output_item
          | :usage
          | :warning
          | :finish
          | :cancelled
          | :error
          | :provider_event

  @type t :: %__MODULE__{
          type: event_type(),
          data: term(),
          metadata: map()
        }

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for canonical stream events."
  def schema, do: @schema

  @doc "Returns all stable stream event types."
  @spec types() :: [event_type()]
  def types, do: @event_types

  @doc "Builds a canonical stream event."
  @spec new(event_type(), term(), map()) :: t()
  def new(type, data \\ nil, metadata \\ %{})
      when type in @event_types and is_map(metadata) do
    %__MODULE__{type: type, data: data, metadata: metadata}
  end

  @doc "Returns whether an event carries model output or an output delta."
  @spec output?(t()) :: boolean()
  def output?(%__MODULE__{type: type}), do: type in @output_types

  @doc "Returns whether an event is the terminal event for a consumed stream."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{type: type}), do: type in @terminal_types
end

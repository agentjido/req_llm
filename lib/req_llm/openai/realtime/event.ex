defmodule ReqLLM.OpenAI.Realtime.Event do
  @moduledoc """
  An experimental view of one OpenAI Realtime server event.

  `native` preserves the provider event shape with sensitive payloads redacted
  by default. `stream_events` contains only the exact overlap with
  `ReqLLM.StreamEvent`; provider-specific session and transport events remain
  native instead of being mislabeled as portable.
  """

  alias ReqLLM.StreamEvent

  @enforce_keys [:type, :native, :stream_events]
  defstruct [:type, :native, :stream_events]

  @type t :: %__MODULE__{
          type: String.t() | nil,
          native: map(),
          stream_events: [StreamEvent.t()]
        }

  @doc "Returns whether the provider event has exact canonical overlap."
  @spec portable?(t()) :: boolean()
  def portable?(%__MODULE__{stream_events: events}), do: events != []

  @doc "Returns whether the projection contains a canonical terminal event."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{stream_events: events}),
    do: Enum.any?(events, &StreamEvent.terminal?/1)
end

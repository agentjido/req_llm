defmodule ReqLLM.Provider.InProcessStream do
  @moduledoc """
  Describes a provider-owned in-process stream of canonical chunks.

  Providers can return an enumerable directly from
  `ReqLLM.Provider.attach_in_process_stream/3`. Use this struct when the
  provider also needs a callback when ReqLLM cancels the stream or a timeout
  stops it.

      stream =
        Stream.map(events, fn event ->
          ReqLLM.StreamChunk.text(event.text)
        end)

      ReqLLM.Provider.InProcessStream.new(stream,
        cancel: fn -> MyProvider.cancel(subscription) end
      )

  The enumerable must emit `ReqLLM.StreamChunk` structs. It can emit
  `{:error, reason}` to fail the stream.
  """

  @enforce_keys [:stream]
  defstruct [:stream, :cancel]

  @type t :: %__MODULE__{
          stream: Enumerable.t(),
          cancel: (-> any()) | nil
        }

  @doc """
  Creates an in-process stream definition.

  The optional `:cancel` callback runs when ReqLLM cancels the stream or stops
  it because of a timeout.
  """
  @spec new(Enumerable.t(), keyword()) :: t()
  def new(stream, opts \\ []) do
    %__MODULE__{stream: stream, cancel: Keyword.get(opts, :cancel)}
  end
end

defmodule ReqLLM.Speech.DetailedResult do
  @moduledoc """
  Opt-in speech result with sparse call metadata.

  The nested `result` is the unchanged `ReqLLM.Speech.Result` returned by
  `ReqLLM.speak/3`. `call_metadata` contains only values observed for the same
  provider request. Unavailable usage, identifiers, warnings, timings, and
  provider metadata are omitted rather than represented by defaults.

  The top-level `request_id` is ReqLLM's telemetry correlation ID. A provider's
  request ID, when supplied in the response, is kept separately at
  `call_metadata.provider_metadata.request_id`.
  """

  alias ReqLLM.Speech.Result

  @type call_metadata :: %{
          required(:model) => String.t(),
          required(:provider) => atom(),
          optional(:status) => non_neg_integer(),
          optional(:usage) => map(),
          optional(:request_id) => String.t(),
          optional(:response_id) => String.t(),
          optional(:warnings) => [String.t()],
          optional(:timings) => map(),
          optional(:provider_metadata) => map()
        }

  @type t :: %__MODULE__{
          result: Result.t(),
          call_metadata: call_metadata()
        }

  @enforce_keys [:result, :call_metadata]
  defstruct [:result, :call_metadata]
end

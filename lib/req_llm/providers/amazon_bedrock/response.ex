defmodule ReqLLM.Providers.AmazonBedrock.Response do
  @moduledoc false
  defstruct [:payload]
  @type t :: %__MODULE__{payload: term()}
end

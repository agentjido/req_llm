defmodule ReqLLM.Providers.Bedrock.Response do
  @moduledoc false
  defstruct [:payload]
  @type t :: %__MODULE__{payload: term()}
end

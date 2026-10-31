defmodule ReqLLM.JSON.Codec do
  @moduledoc """
  Contract for the JSON library that ReqLLM uses.

  This is the same three-function contract that Phoenix uses for its JSON
  library configuration.
  """

  @doc "Decodes a JSON binary or raises."
  @callback decode!(binary()) :: term()

  @doc "Encodes a term to a JSON binary or raises."
  @callback encode!(term()) :: binary()

  @doc "Encodes a term to JSON iodata or raises."
  @callback encode_to_iodata!(term()) :: iodata()
end

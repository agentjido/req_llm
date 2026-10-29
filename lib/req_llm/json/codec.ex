defmodule ReqLLM.JSON.Codec do
  @moduledoc """
  Contract for the JSON codec used by `ReqLLM.JSON`.

  Jason implements `encode!/1`, `encode_to_iodata!/1`, `decode/1` and `decode!/1`, so
  it can be configured as is. Any other module has to implement at least the required
  callbacks.

  The optional callbacks cover the two things a JSON library cannot express through
  the required ones:

    * `c:encode_ordered_to_iodata!/1` - encode an `ReqLLM.JSON.OrderedObject`, which
      keeps structured-output property order. Without it, ordered bodies fall back to
      Jason.
    * `c:decode_error_position/1` - report the byte offset of a syntax error. Without
      it, streaming callers that split frames on partial JSON treat the error as fatal.

  ## Example

      defmodule MyApp.JSON do
        @behaviour ReqLLM.JSON.Codec

        def encode!(term), do: JSON.encode!(term)
        def encode_to_iodata!(term), do: JSON.encode_to_iodata!(term)
        def decode(binary), do: JSON.decode(binary)
      end
  """

  @doc "Encodes a term to a JSON binary."
  @callback encode!(term()) :: binary()

  @doc "Encodes a term to JSON iodata."
  @callback encode_to_iodata!(term()) :: iodata()

  @doc "Decodes a JSON binary."
  @callback decode(binary()) :: {:ok, term()} | {:error, term()}

  @doc "Decodes a JSON binary, raising on invalid input."
  @callback decode!(binary()) :: term()

  @doc "Encodes a body that carries ordered objects, preserving property order."
  @callback encode_ordered_to_iodata!(term()) :: iodata()

  @doc "Returns the byte offset of a decode error, when the codec can report one."
  @callback decode_error_position(term()) :: non_neg_integer() | nil

  @optional_callbacks decode!: 1, encode_ordered_to_iodata!: 1, decode_error_position: 1
end

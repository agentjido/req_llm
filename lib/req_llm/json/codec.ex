defmodule ReqLLM.JSON.Codec do
  @moduledoc """
  Jason-compatible entry point for ReqLLM's JSON encoding and decoding, so the codec can be
  swapped for a faster one:

      config :req_llm, json_library: MyApp.JSON

  The library must export `encode/1`, returning `{:ok, iodata}` or `{:error, reason}`, and
  `decode/1`, returning `{:ok, term}` or `{:error, reason}`. Request bodies carry values only Jason
  knows how to encode (`Jason.OrderedObject`, structs deriving `Jason.Encoder`), so an encode the
  library rejects is retried with Jason. Calls passing Jason options always go to Jason.
  """

  @doc """
  The configured JSON library, Jason by default or while the configured one can't be loaded: ReqLLM
  decodes JSON at compile time, before the application configuring the library is compiled.
  """
  @spec library() :: module()
  def library do
    library = Application.get_env(:req_llm, :json_library, Jason)
    if Code.ensure_loaded?(library), do: library, else: Jason
  end

  @spec encode(term(), keyword()) :: {:ok, binary()} | {:error, term()}
  def encode(term, opts \\ [])

  def encode(term, []) do
    case library() do
      Jason -> Jason.encode(term)
      library -> library_encode(library, term)
    end
  end

  def encode(term, opts), do: Jason.encode(term, opts)

  @spec encode!(term(), keyword()) :: binary()
  def encode!(term, opts \\ []) do
    case encode(term, opts) do
      {:ok, json} -> json
      {:error, error} -> raise error
    end
  end

  @spec encode_to_iodata!(term(), keyword()) :: iodata()
  def encode_to_iodata!(term, opts \\ [])

  def encode_to_iodata!(term, []) do
    case library() do
      Jason -> Jason.encode_to_iodata!(term)
      _ -> encode!(term)
    end
  end

  def encode_to_iodata!(term, opts), do: Jason.encode_to_iodata!(term, opts)

  @spec decode(iodata(), keyword()) :: {:ok, term()} | {:error, term()}
  def decode(json, opts \\ [])

  def decode(json, []) do
    case library() do
      Jason -> Jason.decode(json)
      library -> library.decode(IO.iodata_to_binary(json))
    end
  end

  def decode(json, opts), do: Jason.decode(json, opts)

  @doc "Raises `Jason.DecodeError` on invalid input whichever library is configured."
  @spec decode!(iodata(), keyword()) :: term()
  def decode!(json, opts \\ []) do
    case decode(json, opts) do
      {:ok, term} -> term
      {:error, _} -> Jason.decode!(json, opts)
    end
  end

  defp library_encode(library, term) do
    case library.encode(term) do
      {:ok, json} -> {:ok, IO.iodata_to_binary(json)}
      {:error, _} -> Jason.encode(term)
    end
  rescue
    _ -> Jason.encode(term)
  end
end

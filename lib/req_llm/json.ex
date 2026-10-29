defmodule ReqLLM.JSON do
  @moduledoc """
  JSON codec and decode helpers.

  ReqLLM encodes and decodes JSON with Jason by default. Set `:json_library` to any
  module implementing `ReqLLM.JSON.Codec` to replace it:

      config :req_llm, json_library: MyApp.JSON

  The codec is read from the application environment on every call, so it can be
  changed at runtime. A module that does not export `encode!/1`,
  `encode_to_iodata!/1` and `decode/1` raises `ArgumentError` on first use.

  ## Decoding model output

  `decode/2` decodes JSON that a model produced. It repairs the common failure modes
  (code fences, BOM, smart quotes, trailing commas, unbalanced delimiters) before
  giving up, and `:json_repair` turns that off.

  ## Structured output ordering

  Structured-output schemas carry `ReqLLM.JSON.OrderedObject` values, because
  property order has to survive encoding. Ordered bodies are encoded with
  `c:ReqLLM.JSON.Codec.encode_ordered_to_iodata!/1` when the codec exports it, through
  the codec's protocol implementation when it ships one (Jason and the Elixir `JSON`
  module do), and through Jason otherwise.

  ## Other codecs

      defmodule MyApp.JSON do
        @behaviour ReqLLM.JSON.Codec

        def encode!(term), do: JSON.encode!(term)
        def encode_to_iodata!(term), do: JSON.encode_to_iodata!(term)
        def decode(binary), do: JSON.decode(binary)
      end

  For Torque, convert ordered bodies to its jiffy-style proplist first:

      defmodule MyApp.TorqueJSON do
        @behaviour ReqLLM.JSON.Codec

        def encode!(term), do: term |> ReqLLM.JSON.to_jiffy_ordered() |> Torque.encode!()

        def encode_to_iodata!(term) do
          term |> ReqLLM.JSON.to_jiffy_ordered() |> Torque.encode_to_iodata() |> IO.iodata_to_binary()
        end

        def decode(binary), do: Torque.decode(binary)

        def encode_ordered_to_iodata!(term), do: term |> encode!() |> IO.iodata_to_binary()
      end
  """

  alias ReqLLM.JSON.OrderedObject

  @default_codec Jason
  @required_callbacks [encode!: 1, encode_to_iodata!: 1, decode: 1]

  @doc """
  Returns the configured JSON codec, raising when it cannot be used.

  ## Examples

      iex> ReqLLM.JSON.json_library()
      Jason

  """
  @spec json_library() :: module()
  def json_library do
    Application.get_env(:req_llm, :json_library, @default_codec)
    |> validate_codec!()
  end

  @doc """
  Encodes a term to a JSON binary with the configured codec.
  """
  @spec encode!(term()) :: binary()
  def encode!(term), do: json_library().encode!(term)

  @doc """
  Encodes a term to JSON iodata with the configured codec.
  """
  @spec encode_to_iodata!(term()) :: iodata()
  def encode_to_iodata!(term), do: json_library().encode_to_iodata!(term)

  @doc """
  Decodes JSON produced by a model, repairing common malformed output.

  Options:

    * `:json_repair` - repairs malformed JSON before retrying (default `true`)

  Returns `{:ok, term}` or `{:error, reason}`.
  """
  @spec decode(iodata(), keyword()) :: {:ok, term()} | {:error, term()}
  def decode(json, opts \\ [])

  def decode(json, opts) when is_binary(json) or is_list(json) do
    json = IO.iodata_to_binary(json)

    case decode_once(json) do
      {:ok, _parsed} = ok ->
        ok

      {:error, error} ->
        if json_repair_enabled?(opts) do
          repaired = repair(json)

          if repaired == json do
            {:error, error}
          else
            decode_once(repaired)
          end
        else
          {:error, error}
        end
    end
  end

  def decode(_json, _opts), do: {:error, :invalid_json}

  @doc """
  Decodes a JSON binary with the configured codec, raising on invalid input.

  Uses the codec's own `decode!/1` when it exports one, so the default keeps raising
  `Jason.DecodeError`.
  """
  @spec decode!(iodata()) :: term()
  def decode!(json) when is_binary(json) or is_list(json) do
    codec = json_library()
    json = IO.iodata_to_binary(json)

    if function_exported?(codec, :decode!, 1) do
      codec.decode!(json)
    else
      case codec.decode(json) do
        {:ok, term} -> term
        {:error, reason} -> raise ReqLLM.Error.Unknown.Unknown, error: reason
      end
    end
  end

  @doc """
  Encodes a request body, keeping structured-output property order.

  Applies `ReqLLM.Schema.apply_property_ordering/1` and then encodes with the
  configured codec. Returns a binary, because providers hand the result straight to
  `Finch` and `Req`.
  """
  @spec encode_request_body(term()) :: binary()
  def encode_request_body(body) do
    body
    |> ReqLLM.Schema.apply_property_ordering()
    |> encode_body_value()
  end

  @doc """
  Encodes a body value that is already in wire shape.

  Providers often keep the body as a map in `Req`'s `:json` option and let `Req`
  encode it. This encodes that value with the configured codec without applying
  property ordering, which Google must not do.
  """
  @spec encode_body_value(term()) :: binary()
  def encode_body_value(value) do
    value
    |> encode_ordered_body()
    |> IO.iodata_to_binary()
  end

  @doc """
  Moves a pending `:json` option onto the request body when the codec is not Jason.

  `Req` encodes its `:json` option with Jason, so requests that rely on it have to be
  materialized before execution, and response decoding has to go through the codec
  as well. Jason requests are returned untouched, keeping the default path identical.
  """
  @spec materialize_request(Req.Request.t()) :: Req.Request.t()
  def materialize_request(%Req.Request{} = request) do
    if json_library() == Jason do
      request
    else
      case pending_json(request) do
        nil -> request
        body -> put_request_body(request, body)
      end
    end
  end

  @doc """
  Request options that carry a JSON body and decode responses with the configured codec.

  Returns `:body`, a JSON content type, and `:decoders` for Req.
  """
  @spec request_options(term()) :: keyword()
  def request_options(body) do
    [
      body: encode_request_body(body),
      headers: [{"content-type", "application/json"}],
      decoders: decoders()
    ]
  end

  @doc """
  Req `:decoders` option that routes JSON response bodies through the configured codec.
  """
  @spec decoders() :: keyword()
  def decoders do
    decoder = fn json -> json_library().decode(json) end
    [json: decoder, json_api: decoder]
  end

  @doc """
  Returns the byte offset of a decode error, or `nil` when the codec cannot report one.

  Codecs may implement `c:ReqLLM.JSON.Codec.decode_error_position/1`. Jason errors are
  understood out of the box so the default keeps working.
  """
  @spec decode_error_position(term()) :: non_neg_integer() | nil
  def decode_error_position(%{__struct__: codec} = error) do
    cond do
      function_exported?(codec, :decode_error_position, 1) ->
        codec.decode_error_position(error)

      jason_decode_error?(error) ->
        Map.get(error, :position)

      true ->
        nil
    end
  end

  def decode_error_position(_error), do: nil

  @doc """
  Converts ordered objects to Torque's jiffy-style `{[{key, value}]}` proplist.

  Recurses through maps, lists and ordered objects; other terms are returned as is.
  """
  @spec to_jiffy_ordered(term()) :: term()
  def to_jiffy_ordered(%OrderedObject{values: values}) do
    {Enum.map(values, fn {key, value} -> {key, to_jiffy_ordered(value)} end)}
  end

  def to_jiffy_ordered(%{__struct__: _} = struct), do: struct

  def to_jiffy_ordered(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, to_jiffy_ordered(value)} end)
  end

  def to_jiffy_ordered(list) when is_list(list), do: Enum.map(list, &to_jiffy_ordered/1)

  def to_jiffy_ordered(other), do: other

  defp decode_once(json), do: json_library().decode(json)

  defp encode_ordered_body(body) do
    codec = json_library()

    if function_exported?(codec, :encode_ordered_to_iodata!, 1) do
      codec.encode_ordered_to_iodata!(body)
    else
      codec.encode_to_iodata!(body)
    end
  end

  defp pending_json(%Req.Request{options: options}) when is_map(options),
    do: Map.get(options, :json)

  defp pending_json(%Req.Request{options: options}) when is_list(options),
    do: Keyword.get(options, :json)

  defp pending_json(_request), do: nil

  defp put_request_body(%Req.Request{options: options} = request, body) when is_map(options) do
    request
    |> Map.put(:body, encode_body_value(body))
    |> Map.put(:options, options |> Map.delete(:json) |> Map.put(:decoders, decoders()))
  end

  defp put_request_body(%Req.Request{options: options} = request, body) when is_list(options) do
    request
    |> Map.put(:body, encode_body_value(body))
    |> Map.put(:options, options |> Keyword.delete(:json) |> Keyword.put(:decoders, decoders()))
  end

  defp jason_decode_error?(%Jason.DecodeError{} = error),
    do: is_integer(Map.get(error, :position))

  defp jason_decode_error?(_error), do: false

  defp validate_codec!(codec) when is_atom(codec) and not is_nil(codec) do
    loaded? = Code.ensure_loaded?(codec)

    missing =
      Enum.reject(@required_callbacks, fn {function, arity} ->
        loaded? and function_exported?(codec, function, arity)
      end)

    if missing == [] do
      codec
    else
      raise ArgumentError, """
      #{inspect(codec)} cannot be used as config :req_llm, json_library: it does not \
      implement #{Enum.map_join(missing, ", ", fn {function, arity} -> "#{function}/#{arity}" end)}.

      See ReqLLM.JSON.Codec for the contract.\
      """
    end
  end

  defp validate_codec!(other) do
    raise ArgumentError, """
    config :req_llm, json_library: expects a module, got: #{inspect(other)}.

    See ReqLLM.JSON.Codec for the contract.\
    """
  end

  defp json_repair_enabled?(opts) when is_list(opts), do: Keyword.get(opts, :json_repair, true)
  defp json_repair_enabled?(opts) when is_map(opts), do: Map.get(opts, :json_repair, true)
  defp json_repair_enabled?(_opts), do: true

  defp repair(json) do
    json
    |> strip_bom()
    |> normalize_quotes()
    |> strip_code_fences()
    |> extract_json_payload()
    |> remove_trailing_commas()
    |> close_unbalanced_delimiters()
  end

  defp strip_bom(<<239, 187, 191, rest::binary>>), do: rest
  defp strip_bom(json), do: json

  defp normalize_quotes(json) do
    json
    |> String.replace(["\u201c", "\u201d"], "\"")
    |> String.replace(["\u2018", "\u2019"], "'")
  end

  defp strip_code_fences(json) do
    case Regex.run(~r/\A```(?:json)?\s*(.*?)\s*```\z/s, String.trim(json),
           capture: :all_but_first
         ) do
      [inner] -> inner
      _ -> json
    end
  end

  defp extract_json_payload(json) do
    trimmed = String.trim(json)

    case first_json_boundary(trimmed) do
      nil ->
        trimmed

      {start_index, _opening, closing} ->
        candidate = String.slice(trimmed, start_index..-1//1)

        case last_grapheme_index(candidate, closing) do
          nil -> candidate
          end_index -> String.slice(candidate, 0, end_index + 1)
        end
    end
  end

  defp first_json_boundary(json) do
    json
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.find_value(fn
      {"{", index} -> {index, "{", "}"}
      {"[", index} -> {index, "[", "]"}
      _ -> nil
    end)
  end

  defp last_grapheme_index(json, target) do
    json
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {^target, index}, _acc -> index
      _, acc -> acc
    end)
  end

  defp remove_trailing_commas(json) do
    Regex.replace(~r/,\s*([}\]])/, json, "\\1")
  end

  defp close_unbalanced_delimiters(json) do
    {stack, _in_string?, _escaped?} =
      json
      |> String.graphemes()
      |> Enum.reduce({[], false, false}, &track_delimiters/2)

    closing =
      stack
      |> Enum.map_join(fn
        "{" -> "}"
        "[" -> "]"
      end)

    json <> closing
  end

  defp track_delimiters("\\", {stack, true, false}), do: {stack, true, true}
  defp track_delimiters(_char, {stack, true, true}), do: {stack, true, false}
  defp track_delimiters("\"", {stack, true, false}), do: {stack, false, false}
  defp track_delimiters("\"", {stack, false, false}), do: {stack, true, false}
  defp track_delimiters("{", {stack, false, false}), do: {["{" | stack], false, false}
  defp track_delimiters("[", {stack, false, false}), do: {["[" | stack], false, false}
  defp track_delimiters("}", {["{" | rest], false, false}), do: {rest, false, false}
  defp track_delimiters("]", {["[" | rest], false, false}), do: {rest, false, false}
  defp track_delimiters(_char, state), do: state
end

defmodule ReqLLM.JSON do
  @moduledoc """
  JSON encoding, decoding, and model-output repair.

  Jason is the default codec. You can configure a module that implements the
  Phoenix JSON contract:

      config :req_llm, :json_library, MyApp.JSON

  The module must export `decode!/1`, `encode!/1`, and `encode_to_iodata!/1`.
  """

  @default_library Jason
  @required_functions [decode!: 1, encode!: 1, encode_to_iodata!: 1]

  @doc "Returns the configured JSON library."
  @spec json_library() :: module()
  def json_library do
    Application.get_env(:req_llm, :json_library, @default_library)
    |> validate_library!()
  end

  @doc "Encodes a term to a JSON binary."
  @spec encode!(term()) :: binary()
  def encode!(term), do: json_library().encode!(term)

  @doc "Encodes a term to JSON iodata."
  @spec encode_to_iodata!(term()) :: iodata()
  def encode_to_iodata!(term), do: json_library().encode_to_iodata!(term)

  @doc "Decodes JSON and raises when it is invalid."
  @spec decode!(iodata()) :: term()
  def decode!(json) when is_binary(json) or is_list(json) do
    json_library().decode!(IO.iodata_to_binary(json))
  end

  @doc "Prepares a request value while preserving the default Jason output."
  @spec prepare_request_value(term()) :: term()
  def prepare_request_value(body) do
    if json_library() == @default_library do
      ReqLLM.Schema.apply_property_ordering(body)
    else
      body
    end
  end

  @doc "Encodes a request body with the configured JSON library."
  @spec encode_request_body(term()) :: binary()
  def encode_request_body(body) do
    body
    |> prepare_request_value()
    |> encode_to_iodata!()
    |> IO.iodata_to_binary()
  end

  @doc "Materializes a pending Req JSON body when a non-default codec is configured."
  @spec materialize_request(Req.Request.t()) :: Req.Request.t()
  def materialize_request(%Req.Request{} = request) do
    if json_library() == @default_library do
      request
    else
      materialize_pending_json(request)
    end
  end

  @doc "Returns Req decoders that use the configured JSON library."
  @spec decoders() :: keyword()
  def decoders do
    decoder = &decode_once/1
    [json: decoder, json_api: decoder]
  end

  @doc "Decodes wire JSON without model-output repair."
  @spec decode_wire(iodata()) :: {:ok, term()} | {:error, term()}
  def decode_wire(json) when is_binary(json) or is_list(json) do
    json
    |> IO.iodata_to_binary()
    |> decode_once()
  end

  def decode_wire(_json), do: {:error, :invalid_json}

  @doc "Returns the byte position from a JSON decode error when available."
  @spec decode_error_position(term()) :: non_neg_integer() | nil
  def decode_error_position(%Jason.DecodeError{position: position}), do: position

  def decode_error_position(error) do
    library = json_library()

    if function_exported?(library, :decode_error_position, 1) do
      library.decode_error_position(error)
    end
  end

  @spec decode(term(), keyword()) :: {:ok, term()} | {:error, term()}
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

  defp decode_once(json) do
    {:ok, json_library().decode!(json)}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp materialize_pending_json(%Req.Request{options: options} = request)
       when is_map(options) do
    case Map.fetch(options, :json) do
      {:ok, body} ->
        request
        |> Map.put(:body, encode_request_body(body))
        |> Map.put(:options, options |> Map.delete(:json) |> Map.put(:decoders, decoders()))
        |> Req.Request.put_header("content-type", "application/json")

      :error ->
        Map.put(request, :options, Map.put(options, :decoders, decoders()))
    end
  end

  defp materialize_pending_json(request), do: request

  defp validate_library!(library) when is_atom(library) and not is_nil(library) do
    loaded? = Code.ensure_loaded?(library)

    missing =
      Enum.reject(@required_functions, fn {function, arity} ->
        loaded? and function_exported?(library, function, arity)
      end)

    if missing == [] do
      library
    else
      callbacks =
        Enum.map_join(missing, ", ", fn {function, arity} -> "#{function}/#{arity}" end)

      raise ArgumentError,
            "#{inspect(library)} cannot be used as config :req_llm, :json_library; missing #{callbacks}"
    end
  end

  defp validate_library!(library) do
    raise ArgumentError,
          "config :req_llm, :json_library expects a module, got: #{inspect(library)}"
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

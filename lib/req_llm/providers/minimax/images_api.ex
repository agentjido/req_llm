defmodule ReqLLM.Providers.Minimax.ImagesAPI do
  @moduledoc """
  MiniMax Images API driver.

  Implements request/response handling for MiniMax image generation via the
  native `POST /v1/image_generation` endpoint. MiniMax is not OpenAI-compatible
  for images: the response is a flat `data.image_urls[]` / `data.image_base64[]`
  shape and the request uses `response_format: "url" | "base64"`.
  """

  @behaviour ReqLLM.Providers.OpenAI.API

  import ReqLLM.Provider.Utils, only: [ensure_parsed_body: 1]

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response

  @known_size_to_aspect_ratio %{
    "1024x1024" => "1:1",
    "1280x720" => "16:9",
    "720x1280" => "9:16",
    "1248x832" => "3:2",
    "832x1248" => "2:3",
    "1152x864" => "4:3",
    "864x1152" => "3:4",
    "1344x576" => "21:9"
  }

  @impl true
  def path, do: "/image_generation"

  @impl true
  def encode_body(request) do
    opts = if is_map(request.options), do: request.options, else: Map.new(request.options)

    provider_opts =
      case Map.get(opts, :provider_options, []) do
        opts when is_list(opts) -> opts
        opts when is_map(opts) -> opts
        _ -> []
      end

    {aspect_ratio, width, height} = resolve_dimensions(opts[:aspect_ratio], opts[:size])

    body =
      %{
        "model" => opts[:model],
        "prompt" => opts[:prompt]
      }
      |> maybe_put_integer("n", opts[:n])
      |> maybe_put_string("aspect_ratio", aspect_ratio)
      |> maybe_put_integer("width", width)
      |> maybe_put_integer("height", height)
      |> maybe_put_integer("seed", opts[:seed])
      |> maybe_put_string("response_format", minimax_response_format(opts[:response_format]))
      |> maybe_put_boolean("prompt_optimizer", provider_opts[:prompt_optimizer])
      |> maybe_put_subject_reference(provider_opts[:subject_reference])

    request
    |> put_in([Access.key!(:options), :json], body)
  end

  @impl true
  def decode_response({req, resp}) do
    body = ensure_parsed_body(resp.body)

    case minimax_error?(body) do
      {:error, error} ->
        {req, error}

      :ok ->
        case resp.status do
          200 ->
            merged_response = decode_images_response(req, body)
            {req, %{resp | body: merged_response}}

          status ->
            err =
              ReqLLM.Error.API.Response.exception(
                reason: "MiniMax Images API error",
                status: status,
                response_body: resp.body
              )

            {req, err}
        end
    end
  end

  @impl true
  def decode_stream_event(_event, _model), do: []

  @impl true
  def attach_stream(_model, _context, _opts, _finch_name) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(parameter: "streaming not supported for :image")}
  end

  defp decode_images_response(req, %{} = body) do
    data = Map.get(body, "data") || %{}

    url_parts =
      data
      |> Map.get("image_urls")
      |> Kernel.||([])
      |> Enum.map(&decode_url_item/1)

    b64_parts =
      data
      |> Map.get("image_base64")
      |> Kernel.||([])
      |> Enum.map(&decode_b64_item/1)

    parts = Enum.reject(url_parts ++ b64_parts, &is_nil/1)

    message = %Message{role: :assistant, content: parts}
    image_usage = ReqLLM.Usage.Image.build_generated(length(parts))

    usage =
      if map_size(image_usage) > 0 do
        %{image_usage: image_usage}
      end

    base_response = %Response{
      id: Map.get(body, "id") || image_response_id(),
      model: req.options[:model] || "unknown",
      context: req.options[:context] || %Context{messages: []},
      message: message,
      object: nil,
      stream?: false,
      stream: nil,
      usage: usage,
      finish_reason: :stop,
      provider_meta: %{"minimax" => Map.delete(body, "data")},
      error: nil
    }

    Context.merge_response(base_response.context, base_response)
  end

  defp decode_b64_item(b64) when is_binary(b64) do
    data = Base.decode64!(b64)

    %ContentPart{
      type: :image,
      data: data,
      media_type: image_media_type(data)
    }
  end

  defp decode_b64_item(_b64), do: nil

  defp decode_url_item(url) when is_binary(url) do
    %ContentPart{type: :image_url, url: url}
  end

  defp decode_url_item(_url), do: nil

  defp minimax_error?(body) when is_map(body) do
    case get_in(body, ["base_resp", "status_code"]) do
      code when is_integer(code) and code != 0 ->
        status_msg =
          get_in(body, ["base_resp", "status_msg"]) || "MiniMax image generation failed"

        {:error,
         ReqLLM.Error.API.Response.exception(
           reason: "MiniMax error #{code}: #{status_msg}",
           status: code,
           response_body: body
         )}

      _ ->
        :ok
    end
  end

  defp minimax_error?(_body), do: :ok

  defp resolve_dimensions(nil, size) when is_binary(size) do
    case Map.fetch(@known_size_to_aspect_ratio, size) do
      {:ok, aspect_ratio} -> {aspect_ratio, nil, nil}
      :error -> parse_dimensions(size)
    end
  end

  defp resolve_dimensions(nil, {width, height})
       when is_integer(width) and is_integer(height) do
    resolve_dimensions(nil, "#{width}x#{height}")
  end

  defp resolve_dimensions(aspect_ratio, _size), do: {aspect_ratio, nil, nil}

  defp parse_dimensions(size) do
    with [width, height] <- String.split(size, "x", parts: 2),
         {width, ""} <- Integer.parse(width),
         {height, ""} <- Integer.parse(height) do
      {nil, width, height}
    else
      _ -> {nil, nil, nil}
    end
  end

  defp minimax_response_format(:url), do: "url"
  defp minimax_response_format(:binary), do: "base64"
  defp minimax_response_format(other) when is_binary(other), do: other
  defp minimax_response_format(_), do: "base64"

  defp image_media_type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"

  defp image_media_type(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>),
    do: "image/png"

  defp image_media_type(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  defp image_media_type(<<"GIF87a", _::binary>>), do: "image/gif"
  defp image_media_type(<<"GIF89a", _::binary>>), do: "image/gif"
  defp image_media_type(_data), do: "application/octet-stream"

  defp maybe_put_string(body, _key, nil), do: body

  defp maybe_put_string(body, key, value) when is_atom(value) do
    Map.put(body, key, Atom.to_string(value))
  end

  defp maybe_put_string(body, key, value) when is_binary(value) do
    Map.put(body, key, value)
  end

  defp maybe_put_string(body, _key, _), do: body

  defp maybe_put_integer(body, _key, nil), do: body
  defp maybe_put_integer(body, key, value) when is_integer(value), do: Map.put(body, key, value)
  defp maybe_put_integer(body, _key, _), do: body

  defp maybe_put_boolean(body, _key, nil), do: body
  defp maybe_put_boolean(body, key, value) when is_boolean(value), do: Map.put(body, key, value)
  defp maybe_put_boolean(body, _key, _), do: body

  defp maybe_put_subject_reference(body, nil), do: body

  defp maybe_put_subject_reference(body, reference) when is_map(reference) do
    Map.put(body, "subject_reference", [reference_to_wire(reference)])
  end

  defp maybe_put_subject_reference(body, references) when is_list(references) do
    wire_refs =
      if Keyword.keyword?(references) do
        [reference_to_wire(references)]
      else
        Enum.map(references, &reference_to_wire/1)
      end

    Map.put(body, "subject_reference", wire_refs)
  end

  defp maybe_put_subject_reference(body, _), do: body

  defp reference_to_wire(ref) when is_list(ref) do
    %{
      "type" => to_string(Keyword.get(ref, :type, "character")),
      "image_file" => Keyword.get(ref, :image_file)
    }
  end

  defp reference_to_wire(ref) when is_map(ref) do
    %{
      "type" => Map.get(ref, "type", Map.get(ref, :type, "character")),
      "image_file" => Map.get(ref, "image_file", Map.get(ref, :image_file))
    }
  end

  defp image_response_id do
    "img_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end
end

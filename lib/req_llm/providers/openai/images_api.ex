defmodule ReqLLM.Providers.OpenAI.ImagesAPI do
  @moduledoc """
  OpenAI Images API driver.

  Implements request/response handling for OpenAI image generation.
  """

  @behaviour ReqLLM.Providers.OpenAI.API

  import ReqLLM.Provider.Utils, only: [ensure_parsed_body: 1]

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response

  @impl true
  def path, do: "/images/generations"

  @impl true
  def encode_body(request) do
    opts = if is_map(request.options), do: request.options, else: Map.new(request.options)

    body =
      %{
        "model" => opts[:model],
        "prompt" => opts[:prompt],
        "n" => opts[:n] || 1
      }
      |> maybe_put_response_format(opts[:model], opts[:response_format])
      |> maybe_put_size(opts[:size])
      |> maybe_put_string("quality", opts[:quality])
      |> maybe_put_string("style", opts[:style])
      |> maybe_put_string("user", opts[:user])
      |> maybe_put_output_format(opts[:output_format])
      |> maybe_put_integer("seed", opts[:seed])
      |> maybe_put_string("negative_prompt", opts[:negative_prompt])

    request
    |> Map.put(:body, Jason.encode!(body))
  end

  @impl true
  def decode_response({req, resp}) do
    case resp.status do
      200 ->
        body = ensure_parsed_body(resp.body)
        merged_response = decode_images_response(req, body)
        {req, %{resp | body: merged_response}}

      status ->
        err =
          ReqLLM.Error.API.Response.exception(
            reason: "OpenAI Images API error",
            status: status,
            response_body: resp.body
          )

        {req, err}
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
    data = Map.get(body, "data", [])

    media_type =
      case req.options[:output_format] do
        :jpeg -> "image/jpeg"
        :webp -> "image/webp"
        _ -> "image/png"
      end

    parts =
      data
      |> Enum.map(&decode_image_item(&1, media_type))
      |> Enum.reject(&is_nil/1)

    message = %Message{role: :assistant, content: parts}
    size_class = openai_image_size_class(req.options[:size], req.options[:quality])
    image_usage = ReqLLM.Usage.Image.build_generated(length(parts), size_class)

    usage =
      if map_size(image_usage) > 0 do
        %{image_usage: image_usage}
      end

    base_response = %Response{
      id: image_response_id(),
      model: req.options[:model] || "unknown",
      context: req.options[:context] || %Context{messages: []},
      message: message,
      object: nil,
      stream?: false,
      stream: nil,
      usage: usage,
      finish_reason: :stop,
      provider_meta: %{"openai" => Map.delete(body, "data")},
      error: nil
    }

    Context.merge_response(base_response.context, base_response)
  end

  defp decode_image_item(%{"b64_json" => b64} = item, media_type) when is_binary(b64) do
    revised_prompt = Map.get(item, "revised_prompt")
    metadata = if is_binary(revised_prompt), do: %{revised_prompt: revised_prompt}, else: %{}

    %ContentPart{
      type: :image,
      data: Base.decode64!(b64),
      media_type: media_type,
      metadata: metadata
    }
  end

  defp decode_image_item(%{"url" => url} = item, _media_type) when is_binary(url) do
    revised_prompt = Map.get(item, "revised_prompt")
    metadata = if is_binary(revised_prompt), do: %{revised_prompt: revised_prompt}, else: %{}
    %ContentPart{type: :image_url, url: url, metadata: metadata}
  end

  defp decode_image_item(_, _media_type), do: nil

  defp openai_response_format(:url), do: "url"
  defp openai_response_format(:binary), do: "b64_json"
  defp openai_response_format(other) when is_binary(other), do: other
  defp openai_response_format(_), do: "b64_json"

  defp maybe_put_response_format(body, model, response_format) do
    if openai_images_supports_response_format?(model) do
      Map.put(body, "response_format", openai_response_format(response_format || :binary))
    else
      body
    end
  end

  defp openai_images_supports_response_format?(model) when is_binary(model) do
    String.starts_with?(model, "dall-e-")
  end

  defp openai_images_supports_response_format?(_), do: false

  defp maybe_put_size(body, nil), do: body

  defp maybe_put_size(body, {w, h}) when is_integer(w) and is_integer(h) do
    Map.put(body, "size", "#{w}x#{h}")
  end

  defp maybe_put_size(body, size) when is_binary(size) do
    Map.put(body, "size", size)
  end

  defp maybe_put_size(body, _), do: body

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

  defp maybe_put_output_format(body, nil), do: body
  defp maybe_put_output_format(body, :png), do: Map.put(body, "output_format", "png")
  defp maybe_put_output_format(body, :jpeg), do: Map.put(body, "output_format", "jpeg")
  defp maybe_put_output_format(body, :webp), do: Map.put(body, "output_format", "webp")

  defp maybe_put_output_format(body, other) when is_binary(other),
    do: Map.put(body, "output_format", other)

  defp maybe_put_output_format(body, _), do: body

  defp openai_image_size_class(size, quality) do
    size_value = normalize_image_size(size)
    quality_value = normalize_image_quality(quality)

    "#{size_value}:#{quality_value}"
  end

  defp normalize_image_size(nil), do: "1024x1024"
  defp normalize_image_size("auto"), do: "1024x1024"

  defp normalize_image_size({w, h}) when is_integer(w) and is_integer(h) do
    "#{w}x#{h}"
  end

  defp normalize_image_size(size) when is_binary(size) do
    size
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_image_size(_), do: "1024x1024"

  defp normalize_image_quality(nil), do: "medium"

  defp normalize_image_quality(quality) when is_atom(quality) do
    quality |> Atom.to_string() |> normalize_image_quality()
  end

  defp normalize_image_quality(quality) when is_binary(quality) do
    case String.downcase(quality) do
      "low" -> "low"
      "medium" -> "medium"
      "standard" -> "medium"
      "high" -> "high"
      "hd" -> "high"
      _ -> "medium"
    end
  end

  defp normalize_image_quality(_), do: "medium"

  defp image_response_id do
    "img_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end
end

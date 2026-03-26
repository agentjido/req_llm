defmodule ReqLLM.Providers.XAI.ImagesAPI do
  @moduledoc """
  xAI Images API driver.

  Implements request/response handling for xAI image generation.
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
        "n" => opts[:n] || 1,
        "response_format" => xai_response_format(opts[:response_format])
      }
      |> maybe_put_string("aspect_ratio", opts[:aspect_ratio])

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
            reason: "xAI Images API error",
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

    parts =
      data
      |> Enum.map(&decode_image_item/1)
      |> Enum.reject(&is_nil/1)

    message = %Message{role: :assistant, content: parts}
    image_usage = ReqLLM.Usage.Image.build_generated(length(parts))

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
      provider_meta: %{"xai" => Map.delete(body, "data")},
      error: nil
    }

    Context.merge_response(base_response.context, base_response)
  end

  defp decode_image_item(%{"b64_json" => b64} = item) when is_binary(b64) do
    revised_prompt = Map.get(item, "revised_prompt")
    metadata = if is_binary(revised_prompt), do: %{revised_prompt: revised_prompt}, else: %{}

    %ContentPart{
      type: :image,
      data: Base.decode64!(b64),
      media_type: "image/png",
      metadata: metadata
    }
  end

  defp decode_image_item(%{"url" => url} = item) when is_binary(url) do
    revised_prompt = Map.get(item, "revised_prompt")
    metadata = if is_binary(revised_prompt), do: %{revised_prompt: revised_prompt}, else: %{}
    %ContentPart{type: :image_url, url: url, metadata: metadata}
  end

  defp decode_image_item(_), do: nil

  defp xai_response_format(:url), do: "url"
  defp xai_response_format(:binary), do: "b64_json"
  defp xai_response_format(other) when is_binary(other), do: other
  defp xai_response_format(_), do: "b64_json"

  defp maybe_put_string(body, _key, nil), do: body

  defp maybe_put_string(body, key, value) when is_atom(value) do
    Map.put(body, key, Atom.to_string(value))
  end

  defp maybe_put_string(body, key, value) when is_binary(value) do
    Map.put(body, key, value)
  end

  defp maybe_put_string(body, _key, _), do: body

  defp image_response_id do
    "img_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end
end

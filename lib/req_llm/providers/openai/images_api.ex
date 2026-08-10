defmodule ReqLLM.Providers.OpenAI.ImagesAPI do
  @moduledoc """
  OpenAI Images API driver.

  Implements request/response handling for OpenAI image generation.

  Also serves as the shared image codec for providers that expose the same wire
  format (currently Azure OpenAI). Those providers reuse `image_context/2`,
  `normalize_options/2`, `build_generation_body/1`, `edit_image_form_multipart/1`,
  `image_edit?/1` and `decode_response/1` rather than duplicating the encoding
  rules.
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
  def path(:edit), do: "/images/edits"

  @impl true
  def encode_body(%{options: %{form_multipart: _}} = request), do: request

  def encode_body(request) do
    opts = if is_map(request.options), do: request.options, else: Map.new(request.options)

    request
    |> put_in([Access.key!(:options), :json], build_generation_body(opts))
  end

  @doc """
  Builds the JSON body map for the `/images/generations` endpoint.

  Accepts a map or keyword list with `:model`, `:prompt`, and the optional
  image generation options (`:n`, `:size`, `:quality`, `:style`, `:user`,
  `:output_format`, `:response_format`).

  Expects options that have already been through `normalize_options/2`, which
  resolves `:aspect_ratio` into `:size` and rejects options the Images API has
  no field for.

  `:model` must be the catalog model id rather than a provider-side alias: it
  decides whether `response_format` is a legal field for the target model.
  Callers that send a different identifier on the wire (e.g. an Azure
  deployment name) should replace `"model"` in the returned map afterwards.
  """
  def build_generation_body(opts) when is_list(opts), do: build_generation_body(Map.new(opts))

  def build_generation_body(opts) when is_map(opts) do
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
  end

  # The Images API exposes orientation through a fixed set of sizes rather than a
  # free-form aspect ratio, so a requested ratio is resolved to the square,
  # landscape or portrait size the model actually offers.
  @sizes_by_family %{
    "gpt-image" => %{square: "1024x1024", landscape: "1536x1024", portrait: "1024x1536"},
    "dall-e-3" => %{square: "1024x1024", landscape: "1792x1024", portrait: "1024x1792"},
    "dall-e-2" => %{square: "1024x1024", landscape: "1024x1024", portrait: "1024x1024"}
  }

  # Generic image options with no Images API equivalent. Sending them anyway
  # makes the API reject the whole request with `unknown_parameter`, so they are
  # refused up front where the message can say what to do instead.
  @unsupported_options [
    seed: "OpenAI image models do not accept a random seed",
    negative_prompt:
      "OpenAI image models have no negative prompt - describe what to avoid in the prompt itself"
  ]

  @doc """
  Normalizes generic image options into what the OpenAI Images API accepts.

  Resolves `:aspect_ratio` into the closest `:size` the model offers, and
  rejects options the API has no field for. An explicit `:size` always wins over
  `:aspect_ratio`.

  `model_id` must be the catalog model id, since the available sizes differ
  between the gpt-image and DALL-E families.
  """
  @spec normalize_options(keyword(), String.t() | nil) ::
          {:ok, keyword()} | {:error, Exception.t()}
  def normalize_options(opts, model_id) when is_list(opts) do
    with :ok <- reject_unsupported_options(opts) do
      resolve_aspect_ratio(opts, model_id)
    end
  end

  defp reject_unsupported_options(opts) do
    Enum.reduce_while(@unsupported_options, :ok, fn {key, reason}, :ok ->
      if is_nil(Keyword.get(opts, key)) do
        {:cont, :ok}
      else
        {:halt,
         {:error, ReqLLM.Error.Invalid.Parameter.exception(parameter: "#{key}: #{reason}")}}
      end
    end)
  end

  defp resolve_aspect_ratio(opts, model_id) do
    case {Keyword.get(opts, :aspect_ratio), Keyword.get(opts, :size)} do
      {nil, _size} ->
        {:ok, Keyword.delete(opts, :aspect_ratio)}

      {_ratio, size} when not is_nil(size) ->
        {:ok, Keyword.delete(opts, :aspect_ratio)}

      {ratio, nil} ->
        case aspect_ratio_size(ratio, model_id) do
          {:ok, size} ->
            {:ok, opts |> Keyword.delete(:aspect_ratio) |> Keyword.put(:size, size)}

          :error ->
            {:error,
             ReqLLM.Error.Invalid.Parameter.exception(
               parameter:
                 "aspect_ratio: expected a ratio like \"16:9\" or \"1:1\", got #{inspect(ratio)}"
             )}
        end
    end
  end

  defp aspect_ratio_size(ratio, model_id) do
    with {:ok, {width, height}} <- parse_aspect_ratio(ratio) do
      orientation =
        cond do
          width == height -> :square
          width > height -> :landscape
          true -> :portrait
        end

      {:ok, sizes_for_model(model_id)[orientation]}
    end
  end

  defp parse_aspect_ratio(ratio) when is_binary(ratio) do
    with [width, height] <- String.split(ratio, ":", parts: 2),
         {width, ""} <- Integer.parse(String.trim(width)),
         {height, ""} <- Integer.parse(String.trim(height)),
         true <- width > 0 and height > 0 do
      {:ok, {width, height}}
    else
      _ -> :error
    end
  end

  defp parse_aspect_ratio(_ratio), do: :error

  # Unknown ids fall back to the gpt-image sizes: new image models join that
  # family, and the DALL-E ones are frozen.
  defp sizes_for_model(model_id) when is_binary(model_id) do
    Enum.find_value(@sizes_by_family, @sizes_by_family["gpt-image"], fn {prefix, sizes} ->
      if String.starts_with?(model_id, prefix), do: sizes
    end)
  end

  defp sizes_for_model(_model_id), do: @sizes_by_family["gpt-image"]

  @doc """
  Returns true when the options describe an image *edit* rather than a generation.

  An edit is signalled by a non-nil `:source_image`. An explicitly nil
  `:source_image` is treated as a generation, since a multipart edit request
  cannot be built without image bytes.
  """
  @spec image_edit?(keyword() | map()) :: boolean()
  def image_edit?(opts) when is_list(opts), do: Keyword.get(opts, :source_image) != nil
  def image_edit?(opts) when is_map(opts), do: Map.get(opts, :source_image) != nil

  @doc """
  Normalizes image generation input into a `{:ok, context, prompt}` tuple.

  Uses an existing `:context` option when present, otherwise normalizes the
  prompt/messages input. The prompt is the text content of the last user
  message; an empty prompt is an error.
  """
  @spec image_context(term(), keyword()) ::
          {:ok, Context.t(), String.t()} | {:error, term()}
  def image_context(prompt_or_messages, opts) do
    context_result =
      case Keyword.get(opts, :context) do
        %Context{} = context -> {:ok, context}
        _ -> Context.normalize(prompt_or_messages, opts)
      end

    with {:ok, context} <- context_result,
         {:ok, prompt} <- extract_image_prompt(context) do
      {:ok, context, prompt}
    end
  end

  defp extract_image_prompt(%Context{messages: messages}) do
    last_user =
      messages
      |> Enum.reverse()
      |> Enum.find(&(&1.role == :user))

    prompt =
      case last_user do
        nil ->
          ""

        %Message{content: content} when is_list(content) ->
          content
          |> Enum.filter(&(&1.type == :text))
          |> Enum.map_join("", & &1.text)

        %Message{content: content} when is_binary(content) ->
          content

        _ ->
          ""
      end
      |> String.trim()

    if prompt == "" do
      {:error,
       ReqLLM.Error.Invalid.Parameter.exception(
         parameter: "image generation requires a non-empty user text prompt"
       )}
    else
      {:ok, prompt}
    end
  end

  @doc """
  Builds the Req `:form_multipart` keyword list for the `/images/edits` endpoint.

  Required keys in `opts`: `:model`, `:prompt`, `:source_image`. Optional keys
  (`:mask`, `:n`, `:size`, `:quality`, `:output_format`, `:user`, and the
  `*_media_type` companions) are added only when present.
  """
  def edit_image_form_multipart(opts) do
    model = Keyword.fetch!(opts, :model)
    prompt = Keyword.fetch!(opts, :prompt)
    source_image = Keyword.fetch!(opts, :source_image)
    source_image_media_type = Keyword.get(opts, :source_image_media_type, "image/png")
    mask_media_type = Keyword.get(opts, :mask_media_type, "image/png")

    [
      model: model,
      prompt: prompt,
      image:
        {source_image,
         filename: image_filename("source_image", source_image_media_type),
         content_type: source_image_media_type}
    ]
    |> maybe_add_file_part(:mask, Keyword.get(opts, :mask), "mask", mask_media_type)
    |> maybe_add_form_part(:n, Keyword.get(opts, :n))
    |> maybe_add_form_part(:size, Keyword.get(opts, :size))
    |> maybe_add_form_part(:quality, Keyword.get(opts, :quality))
    |> maybe_add_form_part(:output_format, Keyword.get(opts, :output_format))
    |> maybe_add_form_part(:user, Keyword.get(opts, :user))
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

  # This codec is shared with providers that reuse the OpenAI Images wire
  # format, so provider_meta is keyed by whichever provider actually served the
  # request (e.g. "azure") instead of always "openai".
  defp provider_meta_key(req) do
    case req.private[:model] do
      %LLMDB.Model{provider: provider} when is_atom(provider) and not is_nil(provider) ->
        Atom.to_string(provider)

      _ ->
        "openai"
    end
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
    usage = image_response_usage(body, image_usage)

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
      provider_meta: %{provider_meta_key(req) => Map.delete(body, "data")},
      error: nil
    }

    Context.merge_response(base_response.context, base_response)
  end

  # gpt-image models report token usage in the response body, and providers do
  # not agree on how images are priced: some bill per generated image (keyed by
  # size class), others - Azure among them - bill the underlying tokens. Report
  # both so cost calculation can use whichever the model's pricing defines.
  defp image_response_usage(body, image_usage) do
    usage = body |> Map.get("usage") |> image_token_usage()

    usage =
      if map_size(image_usage) > 0 do
        Map.put(usage, :image_usage, image_usage)
      else
        usage
      end

    if map_size(usage) > 0, do: usage
  end

  defp image_token_usage(%{} = usage) do
    %{input_tokens: "input_tokens", output_tokens: "output_tokens", total_tokens: "total_tokens"}
    |> Enum.reduce(%{}, fn {key, wire_key}, acc ->
      case Map.get(usage, wire_key) do
        count when is_integer(count) -> Map.put(acc, key, count)
        _ -> acc
      end
    end)
  end

  defp image_token_usage(_), do: %{}

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

  defp maybe_put_output_format(body, nil), do: body
  defp maybe_put_output_format(body, :png), do: Map.put(body, "output_format", "png")
  defp maybe_put_output_format(body, :jpeg), do: Map.put(body, "output_format", "jpeg")
  defp maybe_put_output_format(body, :webp), do: Map.put(body, "output_format", "webp")

  defp maybe_put_output_format(body, other) when is_binary(other),
    do: Map.put(body, "output_format", other)

  defp maybe_put_output_format(body, _), do: body

  defp maybe_add_file_part(parts, _key, nil, _filename_root, _media_type), do: parts

  defp maybe_add_file_part(parts, key, data, filename_root, media_type) when is_binary(data) do
    parts ++
      [
        {key,
         {data, filename: image_filename(filename_root, media_type), content_type: media_type}}
      ]
  end

  defp maybe_add_form_part(parts, _key, nil), do: parts

  defp maybe_add_form_part(parts, key, value) do
    parts ++ [{key, form_part_value(value)}]
  end

  defp form_part_value({w, h}) when is_integer(w) and is_integer(h), do: "#{w}x#{h}"
  defp form_part_value(value) when is_atom(value), do: Atom.to_string(value)
  defp form_part_value(value) when is_integer(value), do: Integer.to_string(value)
  defp form_part_value(value), do: value

  defp image_filename(root, media_type) do
    extension = image_extension(media_type)
    "#{root}.#{extension}"
  end

  defp image_extension("image/jpeg"), do: "jpg"
  defp image_extension("image/jpg"), do: "jpg"
  defp image_extension("image/webp"), do: "webp"
  defp image_extension(_), do: "png"

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

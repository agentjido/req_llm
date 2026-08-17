defmodule ReqLLM.Images.OpenAICompatible do
  @moduledoc """
  Shared codec for providers that speak the OpenAI Images wire format.

  Currently used by `ReqLLM.Providers.OpenAI` (via
  `ReqLLM.Providers.OpenAI.ImagesAPI`) and `ReqLLM.Providers.Azure`. It owns the
  encoding rules — option translation, body/multipart construction, and response
  decoding — so no provider has to restate them.

  ## Option pipeline

  Options flow through two steps in a fixed order, and each step has exactly one
  job:

      1. validate_options/1   reject what no translation can express
      2. translate_options/2  resolve, drop, and warn on validated input

  `validate_options/1` runs *before* `ReqLLM.Provider.Options.process/4`, so
  `translate_options/2` — which `process/4` invokes through the provider's
  `c:ReqLLM.Provider.translate_options/3` callback — only ever sees input it can
  express. That ordering is why `translate_options/2` may return `{opts,
  warnings}` and never an error: everything unrepresentable was already
  rejected, and everything else is a lossy-but-valid transformation reported as
  a warning through `:on_unsupported`.

  ## Wire format

  Generation is a JSON POST to `path(:generation)`; editing is a multipart POST
  to `path(:edit)`, signalled by a non-nil `:source_image`.
  """

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Response

  # The Images API exposes orientation through a fixed set of sizes rather than a
  # free-form aspect ratio, so a requested ratio is resolved to the nearest size
  # the model family actually offers.
  @sizes_by_family %{
    "gpt-image" => ["1024x1024", "1536x1024", "1024x1536"],
    "dall-e-3" => ["1024x1024", "1792x1024", "1024x1792"],
    "dall-e-2" => ["256x256", "512x512", "1024x1024"]
  }

  # Generic image options with no Images API equivalent. Sending them anyway
  # makes the API reject the whole request with `unknown_parameter`, so they are
  # dropped up front with a warning that says what to do instead.
  @unsupported_options [
    seed: "the Images API does not accept a random seed",
    negative_prompt:
      "the Images API has no negative prompt - describe what to avoid in the prompt itself"
  ]

  # Image parameters that can reach the wire, listed explicitly rather than
  # derived by subtracting plumbing keys from the schema. A denylist would make
  # any new plumbing option added to ReqLLM.Images silently become a request
  # option; an allowlist keeps that decision deliberate.
  @wire_option_keys [
    :n,
    :size,
    :aspect_ratio,
    :output_format,
    :response_format,
    :quality,
    :style,
    :seed,
    :negative_prompt,
    :source_image,
    :source_image_media_type,
    :mask,
    :mask_media_type,
    :user
  ]

  @plumbing_option_keys [
    :provider_options,
    :req_http_options,
    :telemetry,
    :receive_timeout,
    :total_timeout,
    :max_retries,
    :on_unsupported,
    :fixture
  ]

  @image_schema_keys ReqLLM.Images.schema().schema |> Keyword.keys()
  @unknown_option_keys (@wire_option_keys ++ @plumbing_option_keys) -- @image_schema_keys
  @unclassified_option_keys @image_schema_keys -- (@wire_option_keys ++ @plumbing_option_keys)

  case {@unknown_option_keys, @unclassified_option_keys} do
    {[], []} ->
      :ok

    {unknown, unclassified} ->
      raise CompileError,
        description:
          "#{inspect(__MODULE__)} image option classification is out of date; " <>
            "unknown: #{inspect(unknown)}, unclassified: #{inspect(unclassified)}"
  end

  # :prompt is derived from the context rather than passed as an option, so it
  # is not in the Images schema but still has to be registered on the request.
  @request_option_keys [:prompt | @wire_option_keys]

  @doc """
  Endpoint path for an image `:generation` or `:edit`.

  Providers that mount the Images API under a different prefix (Azure's
  deployment-scoped routes) build on top of these suffixes.
  """
  @spec path(:generation | :edit) :: String.t()
  def path(:generation), do: "/images/generations"
  def path(:edit), do: "/images/edits"

  @doc """
  Image option keys providers should register on the Req request.

  Covers every option that can reach the wire, plus `:prompt`. Plumbing options
  (`:provider_options`, `:receive_timeout`, …) are deliberately excluded —
  request-building layers register and merge those themselves.
  """
  @spec request_option_keys() :: [atom()]
  def request_option_keys, do: @request_option_keys

  @doc """
  Rejects image options the Images API cannot express under any translation.

  Run this *before* `ReqLLM.Provider.Options.process/4`, so that
  `translate_options/2` receives only representable input. Rejects a malformed
  `:aspect_ratio` and a `:mask` without a `:source_image`; a well-formed
  `:aspect_ratio` is left for `translate_options/2` to resolve.
  """
  @spec validate_options(keyword()) :: :ok | {:error, Exception.t()}
  def validate_options(opts) when is_list(opts) do
    with :ok <- validate_mask(opts) do
      validate_aspect_ratio(opts)
    end
  end

  defp validate_mask(opts) do
    if not is_nil(Keyword.get(opts, :mask)) and is_nil(Keyword.get(opts, :source_image)) do
      {:error,
       ReqLLM.Error.Invalid.Parameter.exception(
         parameter: "mask: :mask requires a :source_image to edit"
       )}
    else
      :ok
    end
  end

  defp validate_aspect_ratio(opts) do
    case Keyword.get(opts, :aspect_ratio) do
      nil ->
        :ok

      ratio ->
        case parse_aspect_ratio(ratio) do
          {:ok, _dimensions} ->
            :ok

          :error ->
            {:error,
             ReqLLM.Error.Invalid.Parameter.exception(
               parameter:
                 "aspect_ratio: expected a ratio like \"16:9\" or \"1:1\", got #{inspect(ratio)}"
             )}
        end
    end
  end

  @doc """
  Translates generic image options into what the Images API accepts.

  Returns `{opts, warnings}` in the shape the `c:ReqLLM.Provider.translate_options/3`
  callback expects, so providers sharing this codec route through it and the
  transformations surface through `:on_unsupported`.

  Drops options the API has no field for (`:seed`, `:negative_prompt`, and
  `:style` outside DALL-E 3), maps the DALL-E quality names (`:standard`/`:hd`)
  onto the gpt-image ones, and resolves `:aspect_ratio` into the nearest `:size`
  the model offers — the only place that resolution happens.

  Assumes `validate_options/1` has already run: a malformed `:aspect_ratio` is
  left untouched rather than raising, since it should never get this far.

  `model_id` must be the catalog model id, since the accepted fields and sizes
  differ between the gpt-image and DALL-E families.
  """
  @spec translate_options(keyword(), String.t() | nil) :: {keyword(), [String.t()]}
  def translate_options(opts, model_id) when is_list(opts) do
    {opts, []}
    |> drop_unsupported_options()
    |> translate_quality(model_id)
    |> drop_unsupported_style(model_id)
    |> translate_aspect_ratio(model_id)
  end

  defp drop_unsupported_options({opts, warnings}) do
    Enum.reduce(@unsupported_options, {opts, warnings}, fn {key, reason}, {opts, warnings} ->
      if is_nil(Keyword.get(opts, key)) do
        {opts, warnings}
      else
        {Keyword.delete(opts, key), warnings ++ [":#{key} dropped - #{reason}"]}
      end
    end)
  end

  # gpt-image models take low/medium/high, not the DALL-E standard/hd names the
  # generic schema also allows; map them the same way the usage decoder does.
  defp translate_quality({opts, warnings}, model_id) do
    quality = Keyword.get(opts, :quality)
    mapped = dall_e_quality_to_gpt_image(quality)

    if model_family(model_id) == "gpt-image" and not is_nil(mapped) do
      {Keyword.put(opts, :quality, mapped),
       warnings ++
         [
           ":quality #{inspect(quality)} translated to #{inspect(mapped)} - gpt-image models take low/medium/high"
         ]}
    else
      {opts, warnings}
    end
  end

  defp dall_e_quality_to_gpt_image(quality) when quality in [:standard, "standard"], do: "medium"
  defp dall_e_quality_to_gpt_image(quality) when quality in [:hd, "hd"], do: "high"
  defp dall_e_quality_to_gpt_image(_quality), do: nil

  defp drop_unsupported_style({opts, warnings}, model_id) do
    if is_nil(Keyword.get(opts, :style)) or model_family(model_id) == "dall-e-3" do
      {opts, warnings}
    else
      {Keyword.delete(opts, :style),
       warnings ++ [":style dropped - only DALL-E 3 models accept a style"]}
    end
  end

  defp translate_aspect_ratio({opts, warnings}, model_id) do
    case {Keyword.get(opts, :aspect_ratio), Keyword.get(opts, :size)} do
      {nil, _size} ->
        {opts, warnings}

      {ratio, nil} ->
        case nearest_size(ratio, model_id) do
          {:ok, size, size_warnings} ->
            {opts |> Keyword.delete(:aspect_ratio) |> Keyword.put(:size, size),
             warnings ++ size_warnings}

          :error ->
            {opts, warnings}
        end

      {_ratio, _size} ->
        {Keyword.delete(opts, :aspect_ratio), warnings}
    end
  end

  # Nearest offered size by aspect ratio (log-scale so 4:3 and 3:4 are equally
  # far from square), preferring the larger size on ties. Warns when the family
  # cannot match the requested orientation at all (DALL-E 2 only offers squares).
  defp nearest_size(ratio, model_id) do
    with {:ok, {width, height}} <- parse_aspect_ratio(ratio) do
      family = model_family(model_id)
      offered = Map.fetch!(@sizes_by_family, family) |> Enum.map(&{&1, parse_size(&1)})
      requested = :math.log(width / height)

      {size, {w, h}} =
        Enum.min_by(offered, fn {_size, {w, h}} ->
          {abs(requested - :math.log(w / h)), -(w * h)}
        end)

      wanted = orientation(width, height)

      warnings =
        cond do
          orientation(w, h) == wanted ->
            []

          Enum.any?(offered, fn {_size, {w, h}} -> orientation(w, h) == wanted end) ->
            [
              "aspect_ratio #{inspect(ratio)} resolved to #{size}, the nearest size " <>
                "#{family} offers - pass :size directly for an exact shape"
            ]

          true ->
            [
              "#{family} models offer no #{wanted} size - " <>
                "using #{size} for aspect_ratio #{inspect(ratio)}"
            ]
        end

      {:ok, size, warnings}
    end
  end

  defp orientation(width, height) do
    cond do
      width == height -> :square
      width > height -> :landscape
      true -> :portrait
    end
  end

  defp parse_size(size) do
    [width, height] = String.split(size, "x")
    {String.to_integer(width), String.to_integer(height)}
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

  # Unknown ids fall back to the gpt-image family: new image models join it,
  # and the DALL-E ones are frozen.
  defp model_family(model_id) when is_binary(model_id) do
    Enum.find(Map.keys(@sizes_by_family), "gpt-image", &String.starts_with?(model_id, &1))
  end

  defp model_family(_model_id), do: "gpt-image"

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
  Builds the JSON body map for the generations endpoint.

  Accepts a map or keyword list with `:model`, `:prompt`, and the optional
  image generation options (`:n`, `:size`, `:quality`, `:style`, `:user`,
  `:output_format`, `:response_format`).

  Expects options that have already been through `translate_options/2`, which
  resolves `:aspect_ratio` into `:size` and drops options the Images API has no
  field for.

  `:model` must be the catalog model id rather than a provider-side alias: it
  decides whether `response_format` is a legal field for the target model.
  Callers that send a different identifier on the wire (e.g. an Azure
  deployment name) should replace `"model"` in the returned map afterwards.
  """
  @spec build_generation_body(keyword() | map()) :: map()
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

  @doc """
  Builds the Req `:form_multipart` keyword list for the edits endpoint.

  Required keys in `opts`: `:model`, `:prompt`, `:source_image`. Optional keys
  (`:mask`, `:n`, `:size`, `:quality`, `:output_format`, `:user`, and the
  `*_media_type` companions) are added only when present.
  """
  @spec edit_image_form_multipart(keyword()) :: keyword()
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

  @doc """
  Decodes an Images API response into a canonical `ReqLLM.Response`.

  Non-2xx statuses are returned as a `ReqLLM.Error.API.Response` for the caller
  to surface; providers with their own error extraction should route those
  through it before reaching here.
  """
  @spec decode_response({Req.Request.t(), Req.Response.t()}) ::
          {Req.Request.t(), Req.Response.t() | Exception.t()}
  def decode_response({req, resp}) do
    case resp.status do
      status when status in 200..299 ->
        body = ReqLLM.Provider.Utils.ensure_parsed_body(resp.body)
        merged_response = decode_images_response(req, body)
        {req, %{resp | body: merged_response}}

      status ->
        err =
          ReqLLM.Error.API.Response.exception(
            reason: "Images API error",
            status: status,
            response_body: resp.body
          )

        {req, err}
    end
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

    size_class =
      image_size_class(
        echoed_option(body, "size") || req.options[:size],
        echoed_option(body, "quality") || req.options[:quality]
      )

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
  #
  # This relies on no catalog model carrying both token and image pricing
  # components - one that did would be billed on both by ReqLLM.Billing.
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

  defp response_format_value(:url), do: "url"
  defp response_format_value(:binary), do: "b64_json"
  defp response_format_value(other) when is_binary(other), do: other
  defp response_format_value(_), do: "b64_json"

  defp maybe_put_response_format(body, model, response_format) do
    if supports_response_format?(model) do
      Map.put(body, "response_format", response_format_value(response_format || :binary))
    else
      body
    end
  end

  defp supports_response_format?(model) when is_binary(model) do
    String.starts_with?(model, "dall-e-")
  end

  defp supports_response_format?(_), do: false

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

  defp image_size_class(size, quality) do
    "#{normalize_image_size(size)}:#{normalize_image_quality(quality)}"
  end

  # Image-priced models bill per `image.<size>.<quality>` component, and the
  # rendered dimensions need not match what was asked for: `size: "auto"` (or no
  # size at all) resolves server-side. The response echoes what was actually
  # produced, so bill from that and fall back to the request only when the body
  # is silent or still says "auto".
  defp echoed_option(body, key) do
    case Map.get(body, key) do
      value when is_binary(value) -> reject_auto(value)
      _ -> nil
    end
  end

  defp reject_auto(value) do
    case value |> String.trim() |> String.downcase() do
      "auto" -> nil
      "" -> nil
      resolved -> resolved
    end
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

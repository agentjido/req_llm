defmodule ReqLLM.Kino.Image do
  @moduledoc """
  Generate images from a Livebook prompt. Choose an image model with
  `ReqLLM.Kino.ModelPicker` or supply a model spec. Click Generate to send the
  request. Use `ReqLLM.Kino.result/1` to read the response and image data.

  See the [Livebook Tools example](livebook-model-picker.livemd).
  """

  alias ReqLLM.Kino, as: Notebook
  alias ReqLLM.Kino.Request
  alias ReqLLM.Response

  @compile {:no_warn_undefined, [Kino.Image, Kino.Input, Kino.Layout, Kino.Text]}

  @doc """
  Creates an image generation form. Pass `:default_prompt` to set the initial
  prompt and `:request_options` to set options such as size or output format.

  For OpenAI, Azure, Google, and xAI, the form offers an aspect ratio field. A
  `:size` supplied in the request options takes precedence and hides that field.
  The form previews image bytes. When the provider returns only image URLs, get
  them from the response with `ReqLLM.Response.images/1`.
  """
  @spec new(ReqLLM.model_input(), keyword()) :: ReqLLM.Kino.form()
  def new(model_spec, opts \\ []) do
    Notebook.ensure_kino!()
    opts = Keyword.validate!(opts, default_prompt: "", request_options: [])
    {model, request_opts} = Request.resolve!(model_spec, :image, opts[:request_options])

    fields =
      [prompt: Kino.Input.textarea("Prompt", default: opts[:default_prompt])] ++
        aspect_ratio_field(model.provider, request_opts)

    Notebook.new(
      LLMDB.Model.spec(model),
      fields,
      "Generate",
      fn data ->
        options = put_aspect_ratio(request_opts, data[:aspect_ratio])
        Request.run(&ReqLLM.generate_image/3, {model, options}, data.prompt)
      end,
      &render/1
    )
  end

  defp aspect_ratio_field(provider, options) when provider in [:openai, :azure, :google, :xai] do
    if is_nil(options[:size]) do
      [
        aspect_ratio:
          Kino.Input.text("Aspect ratio (optional)", default: options[:aspect_ratio] || "")
      ]
    else
      []
    end
  end

  defp aspect_ratio_field(_provider, _options), do: []

  defp put_aspect_ratio(options, nil), do: options

  defp put_aspect_ratio(options, ratio) do
    case String.trim(ratio) do
      "" -> Keyword.delete(options, :aspect_ratio)
      ratio -> Keyword.put(options, :aspect_ratio, ratio)
    end
  end

  defp render(response) do
    case Enum.map(Response.images(response), &render_part/1) do
      [] -> Kino.Text.new("The model returned no images.")
      images -> Kino.Layout.grid(images, columns: min(length(images), 3))
    end
  end

  defp render_part(%{type: :image, data: data, media_type: "image/" <> _ = media_type})
       when is_binary(data) do
    Kino.Image.new(data, media_type)
  end

  defp render_part(%{type: :image_url}) do
    Kino.Text.new("Read the response to get the image URL.")
  end

  defp render_part(_part), do: Kino.Text.new("This image format cannot be displayed.")
end

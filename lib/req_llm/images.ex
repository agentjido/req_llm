defmodule ReqLLM.Images do
  @moduledoc """
  Image generation functionality for ReqLLM.

  This module provides image generation capabilities with support for:
  - Prompt-based image generation (`generate_image/3`)
  - Model validation for image support
  - The full gpt-image parameter set on OpenAI and Azure: quality tiers,
    `:background`, `:moderation`, `:output_compression`, and `:input_fidelity`
    (see `schema/0` for the per-option rules)

  Image results are returned as canonical `ReqLLM.Response` structs where the
  assistant message contains `ReqLLM.Message.ContentPart` entries of type
  `:image` and/or `:image_url`.
  """

  alias LLMDB.Model
  alias ReqLLM.Response

  @output_formats [:png, :jpeg, :webp]
  @response_formats [:binary, :url]
  @backgrounds [:auto, :transparent, :opaque]
  @moderations [:auto, :low]
  @input_fidelities [:high, :low]
  @gpt_image_qualities [:auto, :low, :medium, :high]
  @dall_e_qualities [:standard, :hd]
  @openai_only_options [:background, :moderation, :output_compression, :input_fidelity]

  @base_schema NimbleOptions.new!(
                 n: [
                   type: :pos_integer,
                   doc:
                     "Number of images to generate (provider/model dependent; gemini-2.5-flash-image and gemini-3-pro-image-preview reject :n and require prompting)"
                 ],
                 size: [
                   type: {:or, [:string, {:tuple, [:pos_integer, :pos_integer]}]},
                   doc:
                     "Requested pixel size, e.g. \"1024x1024\" or {1024, 1024}; gpt-image models also accept \"auto\""
                 ],
                 aspect_ratio: [
                   type: :string,
                   doc:
                     ~s(Requested aspect ratio, e.g. "1:1" or "16:9"; OpenAI and Azure resolve it to the nearest size they offer - warning when the model family cannot match the orientation - and an explicit :size wins)
                 ],
                 output_format: [
                   type: {:in, @output_formats},
                   default: :png,
                   doc:
                     "Requested output image encoding (provider dependent; Azure supports :png and :jpeg, :webp is OpenAI only)"
                 ],
                 response_format: [
                   type: {:in, @response_formats},
                   default: :binary,
                   doc: "Whether to return bytes (:binary) or a URL (:url)"
                 ],
                 seed: [
                   type: :integer,
                   doc:
                     "Random seed for deterministic image generation (provider dependent; dropped with a warning by OpenAI and Azure image models, subject to :on_unsupported)"
                 ],
                 quality: [
                   type: {:or, [{:in, @dall_e_qualities ++ @gpt_image_qualities}, :string]},
                   doc:
                     "Requested quality (provider dependent; gpt-image models take :auto/:low/:medium/:high and translate :standard/:hd with a warning, DALL-E 3 takes :standard/:hd)"
                 ],
                 background: [
                   type:
                     {:or,
                      [{:in, @backgrounds}, {:in, Enum.map(@backgrounds, &Atom.to_string/1)}]},
                   doc:
                     "Background handling for gpt-image models: :auto, :transparent, or :opaque. :transparent requires output_format :png or :webp (OpenAI and Azure image models only; Azure offers :png)"
                 ],
                 moderation: [
                   type:
                     {:or,
                      [{:in, @moderations}, {:in, Enum.map(@moderations, &Atom.to_string/1)}]},
                   doc:
                     "Content moderation strictness for gpt-image generation: :auto or :low (OpenAI image models; forwarded unchanged on Azure; dropped with a warning for image edits and DALL-E)"
                 ],
                 output_compression: [
                   type: {:in, 0..100},
                   doc:
                     "Compression level (0-100) for :jpeg and :webp output; dropped with a warning when output_format is :png (OpenAI and Azure image models only)"
                 ],
                 input_fidelity: [
                   type:
                     {:or,
                      [
                        {:in, @input_fidelities},
                        {:in, Enum.map(@input_fidelities, &Atom.to_string/1)}
                      ]},
                   doc:
                     "How closely image edits preserve the source image: :high or :low. Edits only (requires :source_image); gpt-image-1 and gpt-image-1.5, not gpt-image-1-mini (OpenAI and Azure image models only)"
                 ],
                 style: [
                   type: {:or, [{:in, [:vivid, :natural]}, :string]},
                   doc:
                     "Requested style (provider dependent; only DALL-E 3 accepts it, other OpenAI/Azure image models drop it with a warning)"
                 ],
                 negative_prompt: [
                   type: :string,
                   doc:
                     "Negative prompt text (provider dependent; dropped with a warning by OpenAI and Azure image models, which have no such field, subject to :on_unsupported)"
                 ],
                 source_image: [
                   type: {:custom, __MODULE__, :validate_binary, []},
                   doc:
                     "Source image bytes for image editing or reference generation (OpenAI and Azure image models only)"
                 ],
                 source_image_media_type: [
                   type: :string,
                   doc:
                     "MIME type for source_image, defaults to image/png when source_image is set (OpenAI and Azure image models only)"
                 ],
                 mask: [
                   type: {:custom, __MODULE__, :validate_binary, []},
                   doc:
                     "Optional mask image bytes for inpainting/editing (OpenAI and Azure image models only)"
                 ],
                 mask_media_type: [
                   type: :string,
                   doc:
                     "MIME type for mask, defaults to image/png when mask is set (OpenAI and Azure image models only)"
                 ],
                 user: [
                   type: :string,
                   doc: "User identifier for tracking and abuse detection"
                 ],
                 provider_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "Provider-specific options (keyword list or map)",
                   default: []
                 ],
                 req_http_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "Req-specific options (keyword list or map)",
                   default: []
                 ],
                 telemetry: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "ReqLLM telemetry options (for example, [payloads: :raw])",
                   default: []
                 ],
                 receive_timeout: [
                   type: :pos_integer,
                   doc: "Timeout for receiving HTTP responses in milliseconds"
                 ],
                 total_timeout: [
                   type: {:or, [:pos_integer, {:in, [:infinity]}]},
                   doc: "Optional total model-call timeout in milliseconds, including retries"
                 ],
                 max_retries: [
                   type: :non_neg_integer,
                   default: 3,
                   doc:
                     "Maximum number of retry attempts for transient network errors. Set to 0 to disable retries."
                 ],
                 on_unsupported: [
                   type: {:in, [:warn, :error, :ignore]},
                   default: :warn,
                   doc: "How to handle provider option translation warnings"
                 ],
                 fixture: [
                   type: {:or, [:string, {:tuple, [:atom, :string]}]},
                   doc: "HTTP fixture for testing (provider inferred from model if string)"
                 ]
               )

  @doc """
  Returns the base image generation options schema.
  """
  @spec schema :: NimbleOptions.t()
  def schema, do: @base_schema

  @doc """
  Drops the options only the OpenAI Images wire format has fields for.

  `:background`, `:moderation`, `:output_compression`, and `:input_fidelity` are
  part of this shared schema, so every provider's image path accepts them. A
  provider whose endpoint has no such field must drop them in its
  `c:ReqLLM.Provider.translate_options/3` image clause: an option that survives
  translation reaches the Req pipeline unregistered and raises there, instead of
  surfacing through `:on_unsupported` like any other lossy translation.

  Returns `{opts, warnings}`, with `provider_label` naming the provider in each
  warning.
  """
  @spec drop_openai_only_options(keyword(), String.t()) :: {keyword(), [String.t()]}
  def drop_openai_only_options(opts, provider_label) when is_list(opts) do
    Enum.reduce(@openai_only_options, {opts, []}, fn key, {acc_opts, warnings} ->
      case Keyword.pop(acc_opts, key) do
        {nil, remaining} ->
          {remaining, warnings}

        {_value, remaining} ->
          {remaining,
           warnings ++ [":#{key} dropped - #{provider_label} image models have no such field"]}
      end
    end)
  end

  @doc false
  def validate_binary(value) when is_binary(value), do: {:ok, value}
  def validate_binary(_value), do: {:error, "expected binary"}

  @doc """
  Generates images using an AI model with full response metadata.

  Returns a canonical `ReqLLM.Response` where images are represented as message content parts.
  """
  @spec generate_image(
          ReqLLM.model_input(),
          String.t() | list() | ReqLLM.Context.t(),
          keyword()
        ) :: {:ok, Response.t()} | {:error, term()}
  def generate_image(model_spec, prompt_or_messages, opts \\ []) do
    opts = ReqLLM.ModelInput.merge_tuple_defaults(model_spec, :image, opts)
    deadline = ReqLLM.TimeoutBudget.deadline(opts)

    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, opts} <-
           ReqLLM.Provider.Options.normalize_namespaced_provider_options(
             provider_module,
             :image,
             model,
             opts
           ),
         {:ok, request} <-
           provider_module.prepare_request(:image, model, prompt_or_messages, opts),
         {:ok, %Req.Response{status: status, body: response}} when status in 200..299 <-
           ReqLLM.TimeoutBudget.request(request, deadline) do
      {:ok, response}
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Request failed",
           status: status,
           response_body: body
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Returns a list of model specs that likely support image generation.

  Uses capability metadata when present, otherwise falls back to a conservative
  name-based heuristic (models containing "image" or "imagen").
  """
  @spec supported_models() :: [String.t()]
  def supported_models do
    ReqLLM.Providers.list()
    |> Enum.flat_map(fn provider ->
      LLMDB.models(provider)
      |> Enum.filter(&image_capable_model?/1)
      |> Enum.map(&LLMDB.Model.spec/1)
    end)
  end

  @doc """
  Validates that a model supports image generation operations.
  """
  @spec validate_model(ReqLLM.model_input()) ::
          {:ok, Model.t()} | {:error, term()}
  def validate_model(model_spec) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, _provider_module} <- ReqLLM.provider(model.provider) do
      model_string = LLMDB.Model.spec(model)

      if image_capable_model?(model) do
        {:ok, model}
      else
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter: "model: #{model_string} does not appear to support image generation"
         )}
      end
    end
  end

  defp image_capable_model?(%Model{} = model) do
    capabilities = model.capabilities

    if is_map(capabilities) and Map.get(capabilities, :images) == true do
      true
    else
      id = to_string(model.provider_model_id || model.id || "")

      String.contains?(id, "image") or
        String.contains?(id, "imagen") or
        String.contains?(id, "dall-e")
    end
  end
end

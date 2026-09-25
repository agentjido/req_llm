defmodule ReqLLM.Images do
  @moduledoc """
  Image generation functionality for ReqLLM.

  This module provides image generation capabilities with support for:
  - Prompt-based image generation (`generate_image/3`)
  - Streaming generation with preview frames (`stream_image/3`, OpenAI and
    Azure gpt-image models)
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
  @gpt_image_qualities [:auto, :low, :medium, :high, :xhigh, :max]
  @dall_e_qualities [:standard, :hd]
  @openai_only_options [:background, :moderation, :output_compression, :input_fidelity]
  @image_streaming_providers [:openai, :azure]

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
                     "Requested quality (provider dependent; gpt-image models take :auto/:low/:medium/:high, gpt-image-2.5 also :xhigh/:max, and translate :standard/:hd with a warning; DALL-E 3 takes :standard/:hd)"
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
                     "How closely image edits preserve the source image: :high or :low. Edits only (requires :source_image); dropped with a warning for gpt-image-1-mini, and gpt-image-2 ignores it (OpenAI and Azure image models only)"
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
                 stream: [
                   type: :boolean,
                   default: false,
                   doc:
                     "Stream partial frames and the final image as SSE; set by stream_image/3, rejected by generate_image/3 (OpenAI and Azure gpt-image models only)"
                 ],
                 partial_images: [
                   type: {:in, 0..3},
                   doc:
                     "Maximum preview frames to stream before the final image (0-3, provider default when unset; fast generations may send fewer or none; stream_image/3 on OpenAI and Azure gpt-image models only)"
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
                 stream_idle_timeout: [
                   type: {:or, [:pos_integer, {:in, [:infinity]}]},
                   doc: "Optional timeout between semantic streaming updates in milliseconds"
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

    with :ok <- reject_stream_options(opts),
         {:ok, model} <- ReqLLM.model(model_spec),
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
  Streams image generation, yielding preview frames before the final image.

  See `ReqLLM.stream_image/3` for the chunk contract. Supported for OpenAI and
  Azure gpt-image models; other providers return `ReqLLM.Error.Invalid.Parameter`.
  """
  @spec stream_image(
          ReqLLM.model_input(),
          String.t() | list() | ReqLLM.Context.t(),
          keyword()
        ) :: {:ok, ReqLLM.StreamResponse.t()} | {:error, term()}
  def stream_image(model_spec, prompt_or_messages, opts \\ []) do
    opts = ReqLLM.ModelInput.merge_tuple_defaults(model_spec, :image, opts)

    with {:ok, model} <- ReqLLM.model(model_spec),
         :ok <- validate_streaming_model(model),
         :ok <- ReqLLM.Images.OpenAICompatible.validate_stream_options(opts),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, opts} <-
           ReqLLM.Provider.Options.normalize_namespaced_provider_options(
             provider_module,
             :image,
             model,
             opts
           ),
         {:ok, context, _prompt} <-
           ReqLLM.Images.OpenAICompatible.image_context(prompt_or_messages, opts),
         {:ok, stream_response} <-
           ReqLLM.Streaming.start_stream(provider_module, model, context, stream_opts(opts)) do
      {:ok, stream_response}
    else
      {:error, {:http_streaming_failed, {:provider_build_failed, %{__exception__: true} = error}}} ->
        {:error, error}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Streams image generation, raising on error.

  Same as `stream_image/3` but raises the error struct instead of returning
  `{:error, error}`. Only errors raised before the request starts are surfaced
  here; failures mid-stream still surface while enumerating or through
  `ReqLLM.StreamResponse.to_response/1`.
  """
  @spec stream_image!(
          ReqLLM.model_input(),
          String.t() | list() | ReqLLM.Context.t(),
          keyword()
        ) :: ReqLLM.StreamResponse.t() | no_return()
  def stream_image!(model_spec, prompt_or_messages, opts \\ []) do
    case stream_image(model_spec, prompt_or_messages, opts) do
      {:ok, stream_response} -> stream_response
      {:error, error} -> raise error
    end
  end

  defp validate_streaming_model(%Model{provider: provider} = model) do
    if provider in @image_streaming_providers and
         ReqLLM.Images.OpenAICompatible.gpt_image_model?(model) do
      :ok
    else
      {:error,
       ReqLLM.Error.Invalid.Parameter.exception(
         parameter:
           "model: image streaming is only supported for OpenAI and Azure gpt-image models, got #{LLMDB.Model.spec(model)}"
       )}
    end
  end

  @doc false
  @spec stream_opts(keyword()) :: keyword()
  def stream_opts(opts) do
    opts
    |> Keyword.put(:operation, :image)
    |> Keyword.put(:stream, true)
    |> Keyword.put_new(
      :receive_timeout,
      Application.get_env(:req_llm, :image_receive_timeout, 120_000)
    )
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

  defp reject_stream_options(opts) do
    cond do
      Keyword.get(opts, :stream) == true ->
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter: "stream: use stream_image/3 to stream image generation"
         )}

      not is_nil(Keyword.get(opts, :partial_images)) ->
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter: "partial_images: preview frames are only streamed; use stream_image/3"
         )}

      true ->
        :ok
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

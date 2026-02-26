defmodule ReqLLM.Images do
  @moduledoc """
  Image generation functionality for ReqLLM.

  This module provides image generation capabilities with support for:
  - Prompt-based image generation (`generate_image/3`)
  - Model validation for image support

  Image results are returned as canonical `ReqLLM.Response` structs where the
  assistant message contains `ReqLLM.Message.ContentPart` entries of type
  `:image` and/or `:image_url`.
  """

  alias LLMDB.Model
  alias ReqLLM.Response

  @output_formats [:png, :jpeg, :webp]
  @response_formats [:binary, :url]

  @base_schema NimbleOptions.new!(
                 n: [
                   type: :pos_integer,
                   doc:
                     "Number of images to generate (provider/model dependent; gemini-2.5-flash-image and gemini-3-pro-image-preview reject :n and require prompting)"
                 ],
                 size: [
                   type: {:or, [:string, {:tuple, [:pos_integer, :pos_integer]}]},
                   doc: "Requested pixel size, e.g. \"1024x1024\" or {1024, 1024}"
                 ],
                 aspect_ratio: [
                   type: :string,
                   doc: ~s(Requested aspect ratio, e.g. "1:1" or "16:9")
                 ],
                 output_format: [
                   type: {:in, @output_formats},
                   default: :png,
                   doc: "Requested output image encoding"
                 ],
                 response_format: [
                   type: {:in, @response_formats},
                   default: :binary,
                   doc: "Whether to return bytes (:binary) or a URL (:url)"
                 ],
                 seed: [
                   type: :integer,
                   doc: "Random seed for deterministic image generation (provider dependent)"
                 ],
                 quality: [
                   type: {:or, [{:in, [:standard, :hd]}, :string]},
                   doc: "Requested quality (provider dependent)"
                 ],
                 style: [
                   type: {:or, [{:in, [:vivid, :natural]}, :string]},
                   doc: "Requested style (provider dependent)"
                 ],
                 negative_prompt: [
                   type: :string,
                   doc: "Negative prompt text (provider dependent)"
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
                 receive_timeout: [
                   type: :pos_integer,
                   doc: "Timeout for receiving HTTP responses in milliseconds"
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
  Generates images using an AI model with full response metadata.

  Returns a canonical `ReqLLM.Response` where images are represented as message content parts.
  """
  @spec generate_image(
          String.t() | {atom(), keyword()} | struct(),
          String.t() | list() | ReqLLM.Context.t(),
          keyword()
        ) :: {:ok, Response.t()} | {:error, term()}
  def generate_image(model_spec, prompt_or_messages, opts \\ []) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, request} <-
           provider_module.prepare_request(:image, model, prompt_or_messages, opts),
         {:ok, %Req.Response{status: status, body: response}} when status in 200..299 <-
           Req.request(request) do
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
  @spec validate_model(String.t() | {atom(), keyword()} | struct()) ::
          {:ok, Model.t()} | {:error, term()}
  def validate_model(model_spec) do
    with {:ok, model} <- ReqLLM.model(model_spec) do
      model_string = LLMDB.Model.spec(model)

      if model_string in supported_models() do
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
      id = to_string(model.id || "")

      String.contains?(id, "image") or
        String.contains?(id, "imagen") or
        String.contains?(id, "dall-e")
    end
  end
end

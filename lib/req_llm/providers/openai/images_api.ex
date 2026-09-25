defmodule ReqLLM.Providers.OpenAI.ImagesAPI do
  @moduledoc """
  OpenAI Images API driver.

  A thin `ReqLLM.Providers.OpenAI.API` adapter over
  `ReqLLM.Images.OpenAICompatible`, which owns the encoding rules shared with
  every provider that speaks the same wire format. Option translation,
  validation, and body construction live there; this module only binds them to
  the OpenAI provider's endpoint driver contract.

  Streaming (`ReqLLM.stream_image/3`) is served by `attach_stream/4`, which
  posts to `/images/generations` with `"stream": true`, and by
  `decode_stream_event/2`, which delegates to the shared SSE decoder.
  """

  @behaviour ReqLLM.Providers.OpenAI.API

  alias ReqLLM.Images.OpenAICompatible

  @impl true
  def path, do: OpenAICompatible.path(:generation)

  @impl true
  def path(:edit), do: OpenAICompatible.path(:edit)

  @impl true
  def encode_body(%{options: %{form_multipart: _}} = request), do: request

  def encode_body(request) do
    opts = if is_map(request.options), do: request.options, else: Map.new(request.options)

    put_in(request, [Access.key!(:options), :json], OpenAICompatible.build_generation_body(opts))
  end

  @doc """
  Builds the Req `:form_multipart` keyword list for the `/images/edits` endpoint.

  This function keeps the existing OpenAI adapter API while the shared codec
  owns the implementation.
  """
  defdelegate edit_image_form_multipart(opts), to: OpenAICompatible

  @impl true
  defdelegate decode_response(request_response), to: OpenAICompatible

  @impl true
  defdelegate decode_stream_event(event, model), to: OpenAICompatible

  @doc """
  Builds the Finch request for a streaming `/images/generations` call.

  Expects options already processed by `ReqLLM.Provider.Options.process_stream!/5`
  for the `:image` operation and already checked by
  `ReqLLM.Images.OpenAICompatible.validate_stream_options/1`; the provider's
  `attach_stream/4` does both before delegating here.
  """
  @impl true
  def attach_stream(model, context, opts, _finch_name) do
    with {:ok, prompt} <- OpenAICompatible.prompt_from_context(context) do
      base_url = ReqLLM.Provider.Options.effective_base_url(ReqLLM.Providers.OpenAI, model, opts)

      auth_headers =
        ReqLLM.Providers.OpenAI.auth_header_list(
          ReqLLM.Providers.OpenAI.resolve_request_credential!(model, opts)
        )

      headers = OpenAICompatible.stream_request_headers(auth_headers, opts)

      body =
        OpenAICompatible.stream_generation_body(opts, prompt, model.provider_model_id || model.id)

      {:ok, Finch.build(:post, base_url <> path(), headers, Jason.encode!(body))}
    end
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build streaming image request: #{Exception.message(error)}"
       )}
  end
end

defmodule ReqLLM.Providers.OpenAI.ImagesAPI do
  @moduledoc """
  OpenAI Images API driver.

  A thin `ReqLLM.Providers.OpenAI.API` adapter over
  `ReqLLM.Images.OpenAICompatible`, which owns the encoding rules shared with
  every provider that speaks the same wire format. Option translation,
  validation, and body construction live there; this module only binds them to
  the OpenAI provider's endpoint driver contract.
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

  @impl true
  defdelegate decode_response(request_response), to: OpenAICompatible

  @impl true
  def decode_stream_event(_event, _model), do: []

  @impl true
  def attach_stream(_model, _context, _opts, _finch_name) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(parameter: "streaming not supported for :image")}
  end
end

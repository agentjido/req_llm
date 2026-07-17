defmodule ReqLLM.Response.OutputItem do
  @moduledoc """
  A computed, canonical view of one value produced by a model call.

  Output items are projections over values already retained by
  `ReqLLM.Response`; they are not stored on the response and do not change its
  serialization. The `data` field contains the existing value, such as text,
  a `ReqLLM.Message.ContentPart`, or a `ReqLLM.ToolCall`.
  """

  @derive Jason.Encoder

  @schema Zoi.struct(__MODULE__, %{
            type:
              Zoi.enum([
                :text,
                :thinking,
                :image,
                :image_url,
                :video_url,
                :file,
                :tool_call,
                :source,
                :annotation,
                :refusal,
                :provider_item
              ]),
            data: Zoi.any() |> Zoi.default(nil),
            metadata: Zoi.map() |> Zoi.default(%{})
          })

  @type t :: unquote(Zoi.type_spec(@schema))

  @type channel ::
          :message
          | :reasoning
          | :tools
          | :media
          | :sources
          | :annotations
          | :refusals
          | :provider

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for output item projections."
  def schema, do: @schema

  @doc "Returns the stable result channel for an output item."
  @spec channel(t()) :: channel()
  def channel(%__MODULE__{type: :thinking}), do: :reasoning
  def channel(%__MODULE__{type: :tool_call}), do: :tools

  def channel(%__MODULE__{type: type}) when type in [:image, :image_url, :video_url, :file],
    do: :media

  def channel(%__MODULE__{type: :source}), do: :sources
  def channel(%__MODULE__{type: :annotation}), do: :annotations
  def channel(%__MODULE__{type: :refusal}), do: :refusals
  def channel(%__MODULE__{type: :provider_item}), do: :provider
  def channel(%__MODULE__{}), do: :message

  @doc "Returns all stable output channels in display order."
  @spec channels() :: [channel()]
  def channels do
    [:message, :reasoning, :tools, :media, :sources, :annotations, :refusals, :provider]
  end
end

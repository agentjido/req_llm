defmodule ReqLLM.Billing.Component do
  @moduledoc false

  alias ReqLLM.MapAccess
  alias ReqLLM.Usage.Tool

  defstruct [
    :id,
    :kind,
    :per,
    :rate,
    :meter,
    :tool,
    :unit,
    :size_class,
    :min_input_tokens,
    :max_input_tokens
  ]

  @type t :: %__MODULE__{
          id: any(),
          kind: :tokens | :tools | :images | :storage | nil,
          per: any(),
          rate: any(),
          meter: any(),
          tool: any(),
          unit: String.t() | nil,
          size_class: any(),
          min_input_tokens: non_neg_integer() | nil,
          max_input_tokens: non_neg_integer() | nil
        }

  @spec from(map()) :: t()
  def from(component) when is_map(component) do
    %__MODULE__{
      id: MapAccess.get(component, :id),
      kind: normalize_kind(MapAccess.get(component, :kind)),
      per: MapAccess.get(component, :per),
      rate: MapAccess.get(component, :rate),
      meter: MapAccess.get(component, :meter),
      tool: MapAccess.get(component, :tool),
      unit: Tool.normalize_unit(MapAccess.get(component, :unit)),
      size_class: MapAccess.get(component, :size_class),
      min_input_tokens: MapAccess.get(component, :min_input_tokens),
      max_input_tokens: MapAccess.get(component, :max_input_tokens)
    }
  end

  def from(_), do: %__MODULE__{}

  @spec id_string(t()) :: String.t() | nil
  def id_string(%__MODULE__{id: id}) when is_binary(id), do: id
  def id_string(%__MODULE__{id: id}) when is_atom(id), do: Atom.to_string(id)
  def id_string(_), do: nil

  defp normalize_kind(:token), do: :tokens
  defp normalize_kind("token"), do: :tokens
  defp normalize_kind(:tool), do: :tools
  defp normalize_kind("tool"), do: :tools
  defp normalize_kind(:image), do: :images
  defp normalize_kind("image"), do: :images
  defp normalize_kind(:storage), do: :storage
  defp normalize_kind("storage"), do: :storage
  defp normalize_kind(_), do: nil
end

defmodule ReqLLM.Message do
  @moduledoc """
  Message represents a single conversation message with multi-modal content support.

  Content is always a list of `ContentPart` structs, never a string.
  This ensures consistent handling across all providers and eliminates polymorphism.
  """

  use TypedStruct

  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall

  @derive Jason.Encoder
  typedstruct enforce: true do
    field(:role, :user | :assistant | :system | :tool, enforce: true)
    field(:content, [ContentPart.t()], default: [])
    field(:name, String.t() | nil, default: nil)
    field(:tool_call_id, String.t() | nil, default: nil)
    field(:tool_calls, [ToolCall.t()] | nil, default: nil)
    field(:metadata, map(), default: %{})
  end

  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{content: content}) when is_list(content), do: true
  def valid?(_), do: false

  defimpl Inspect do
    def inspect(%{role: role, content: parts}, opts) do
      summary =
        parts
        |> Enum.map_join(",", & &1.type)

      Inspect.Algebra.concat(["#Message<", Inspect.Algebra.to_doc(role, opts), " ", summary, ">"])
    end
  end
end

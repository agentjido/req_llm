defmodule ReqLLM.Message do
  @moduledoc """
  Message represents a single conversation message with multi-modal content support.

  Content is always a list of `ContentPart` structs, never a string.
  This ensures consistent handling across all providers and eliminates polymorphism.

  ## Reasoning Details

  The `reasoning_details` field contains provider-specific reasoning metadata that must
  be preserved across conversation turns for reasoning models. This field is:
  - `nil` for non-reasoning models or models that don't provide structured reasoning metadata
  - A list of maps for reasoning models (format varies by provider)

  ### OpenRouter Format

  OpenRouter returns reasoning details for models like Gemini 3, DeepSeek R1:
  ```elixir
  [
    %{
      "type" => "reasoning.text",
      "format" => "google-gemini-v1",  # or "unknown"
      "index" => 0,
      "text" => "Step-by-step reasoning..."
    }
  ]
  ```

  These details are automatically:
  - Extracted from provider responses
  - Preserved and re-sent in multi-turn conversations

  For multi-turn reasoning continuity, include the previous assistant message
  (with its reasoning_details) in subsequent requests.
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
    field(:reasoning_details, [map()] | nil, default: nil)
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

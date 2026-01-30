defmodule ReqLLM.Message do
  @moduledoc """
  Message represents a single conversation message with multi-modal content support.

  Content is always a list of `ContentPart` structs, never a string.
  This ensures consistent handling across all providers and eliminates polymorphism.

  ## Reasoning Details

  The `reasoning_details` field contains provider-specific reasoning metadata that must
  be preserved across conversation turns for reasoning models. This field is:
  - `nil` for non-reasoning models or models that don't provide structured reasoning metadata
  - A list of normalized ReasoningDetails for reasoning models

  For multi-turn reasoning continuity, include the previous assistant message
  (with its reasoning_details) in subsequent requests.
  """

  defmodule ReasoningDetails do
    @moduledoc """
    Normalized reasoning/thinking data from LLM providers.

    ## Fields
    - `text` - Human-readable reasoning/thinking text (may be summarized)
    - `signature` - Opaque signature/token for multi-turn continuity
    - `encrypted?` - Whether the signature contains encrypted reasoning tokens
    - `provider` - Source provider (:anthropic, :google, :openai, :openrouter)
    - `format` - Provider-specific format version identifier
    - `index` - Position index for ordered reasoning blocks
    - `provider_data` - Raw provider-specific fields for lossless round-trips
    """
    @derive Jason.Encoder

    @schema Zoi.struct(__MODULE__, %{
              text: Zoi.string() |> Zoi.nullable() |> Zoi.default(nil),
              signature: Zoi.string() |> Zoi.nullable() |> Zoi.default(nil),
              encrypted?: Zoi.boolean() |> Zoi.default(false),
              provider: Zoi.atom() |> Zoi.nullable() |> Zoi.default(nil),
              format: Zoi.string() |> Zoi.nullable() |> Zoi.default(nil),
              index: Zoi.integer() |> Zoi.default(0),
              provider_data: Zoi.map() |> Zoi.default(%{})
            })

    @type t :: unquote(Zoi.type_spec(@schema))

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)

    def schema, do: @schema
  end

  @derive Jason.Encoder

  @schema Zoi.struct(__MODULE__, %{
            role: Zoi.enum([:user, :assistant, :system, :tool]),
            content: Zoi.list(Zoi.any()) |> Zoi.default([]),
            name: Zoi.string() |> Zoi.nullable() |> Zoi.default(nil),
            tool_call_id: Zoi.string() |> Zoi.nullable() |> Zoi.default(nil),
            tool_calls: Zoi.list(Zoi.any()) |> Zoi.nullable() |> Zoi.default(nil),
            metadata: Zoi.map() |> Zoi.default(%{}),
            reasoning_details: Zoi.list(Zoi.any()) |> Zoi.nullable() |> Zoi.default(nil)
          })

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema

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

defmodule ReqLLM.ToolResult do
  @moduledoc """
  ToolResult represents structured and multi-part tool outputs.

  Tool outputs can include structured data via `output` and/or multimodal
  content parts via `content`.
  """

  @metadata_key :tool_output

  @schema Zoi.struct(__MODULE__, %{
            content: Zoi.list(Zoi.any()) |> Zoi.optional(),
            output: Zoi.any() |> Zoi.optional(),
            metadata: Zoi.map() |> Zoi.default(%{})
          })

  @type t :: unquote(Zoi.type_spec(@schema))

  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for this module"
  def schema, do: @schema

  @spec metadata_key() :: atom()
  def metadata_key, do: @metadata_key

  @spec output_from_message(ReqLLM.Message.t() | map()) :: term() | nil
  def output_from_message(%ReqLLM.Message{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, @metadata_key)
  end

  def output_from_message(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, @metadata_key) || Map.get(metadata, to_string(@metadata_key))
  end

  def output_from_message(_), do: nil

  @spec put_output_metadata(map(), term() | nil) :: map()
  def put_output_metadata(metadata, nil) when is_map(metadata), do: metadata

  def put_output_metadata(metadata, output) when is_map(metadata) do
    Map.put(metadata, @metadata_key, output)
  end
end

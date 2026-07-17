defmodule ReqLLM.ToolResult do
  @moduledoc """
  ToolResult represents structured and multi-part tool outputs while keeping
  application-visible data separate from model-facing content.

  * `output` is the original application value. Maps and lists remain available
    to local code and provider adapters without a text round trip.
  * `content` is the content sent back to the model. It may contain text or
    `ReqLLM.Message.ContentPart` values for images and files. When omitted,
    `ReqLLM.Context` derives model-facing text from `output`.
  * `metadata` carries supplementary application or provider-native data. It is
    not a substitute for model-facing error or result content.

  These fields may intentionally differ. For example, an application can keep a
  rich JSON result in `output` while returning a concise explanation, an error,
  or a multimodal file/image payload in `content`:

      %ReqLLM.ToolResult{
        output: %{document_id: "doc_123", page_count: 4},
        content: [
          ReqLLM.Message.ContentPart.text("The requested document is attached."),
          ReqLLM.Message.ContentPart.file_id("file_123")
        ],
        metadata: %{provider_native: %{request_id: "req_123"}}
      }

  Tool callbacks retain their existing contract: return `{:ok, result}` for a
  successful result or `{:error, result}` for an error. Either result may be a
  plain text/JSON value or a `ToolResult`.
  """

  @metadata_key :tool_output
  @content_source_key :req_llm_tool_result_content_source

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

  @doc "Preserves a tool result's output and explicit-content provenance in message metadata."
  @spec put_message_metadata(map(), t()) :: map()
  def put_message_metadata(metadata, %__MODULE__{} = result) when is_map(metadata) do
    metadata
    |> Map.delete(@content_source_key)
    |> Map.delete(to_string(@content_source_key))
    |> put_output_metadata(result.output)
    |> maybe_mark_explicit_content(result.content)
  end

  @doc "Returns whether a normalized tool message contains explicitly supplied result content."
  @spec explicit_content?(ReqLLM.Message.t() | map()) :: boolean()
  def explicit_content?(%ReqLLM.Message{metadata: metadata}) when is_map(metadata) do
    explicit_content_metadata?(metadata)
  end

  def explicit_content?(%{metadata: metadata}) when is_map(metadata) do
    explicit_content_metadata?(metadata)
  end

  def explicit_content?(_), do: false

  defp maybe_mark_explicit_content(metadata, nil), do: metadata
  defp maybe_mark_explicit_content(metadata, []), do: metadata

  defp maybe_mark_explicit_content(metadata, _content) do
    Map.put(metadata, @content_source_key, :explicit)
  end

  defp explicit_content_metadata?(metadata) do
    Map.get(metadata, @content_source_key) in [:explicit, "explicit"] or
      Map.get(metadata, to_string(@content_source_key)) in [:explicit, "explicit"]
  end
end

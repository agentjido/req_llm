defmodule ReqLLM.Providers.Anthropic.ResponseBuilder do
  @moduledoc """
  Anthropic-specific ResponseBuilder implementation.

  Handles Anthropic's specific requirements:
  - Content blocks must be non-empty when tool_calls are present
  - Maps `tool_use` finish reason to `:tool_calls`

  This fixes bug #269 where streaming tool-call-only responses
  produced empty content blocks that Anthropic's API rejected.
  """

  @behaviour ReqLLM.Provider.ResponseBuilder

  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Provider.Defaults.ResponseBuilder, as: DefaultBuilder

  @impl true
  def build_response(chunks, metadata, opts) do
    with {:ok, response} <- DefaultBuilder.build_response(chunks, metadata, opts) do
      {:ok, ensure_non_empty_content(response)}
    end
  end

  @doc false
  @spec build_buffered_response([ReqLLM.StreamChunk.t()], map(), keyword()) ::
          {:ok, ReqLLM.Response.t()} | {:error, term()}
  def build_buffered_response(chunks, metadata, opts) do
    with {:ok, response} <- DefaultBuilder.build_buffered_response(chunks, metadata, opts) do
      {:ok, preserve_empty_message(response, chunks, opts)}
    end
  end

  defp ensure_non_empty_content(%{message: %{tool_calls: tc, content: []}} = response)
       when is_list(tc) and tc != [] do
    content = [ContentPart.text("")]
    put_in(response.message.content, content)
  end

  defp ensure_non_empty_content(response), do: response

  defp preserve_empty_message(response, chunks, opts) do
    if Enum.any?(chunks, &message_chunk?/1) do
      response
    else
      %{response | message: nil, context: Keyword.fetch!(opts, :context)}
    end
  end

  defp message_chunk?(%ReqLLM.StreamChunk{type: type})
       when type in [:content, :thinking, :tool_call],
       do: true

  defp message_chunk?(_chunk), do: false
end

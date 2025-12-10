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
    # Build base response using default implementation
    case DefaultBuilder.build_response(chunks, metadata, opts) do
      {:ok, response} ->
        # Apply Anthropic-specific post-processing
        {:ok, ensure_non_empty_content(response)}

      error ->
        error
    end
  end

  # Anthropic requires non-empty content blocks when tool_calls are present.
  # If we have tool calls but no text content, add an empty text part.
  defp ensure_non_empty_content(%{message: %{tool_calls: tc, content: []}} = response)
       when is_list(tc) and tc != [] do
    content = [ContentPart.text("")]
    put_in(response.message.content, content)
  end

  defp ensure_non_empty_content(response), do: response
end

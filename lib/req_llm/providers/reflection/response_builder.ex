defmodule ReqLLM.Providers.Reflection.ResponseBuilder do
  @moduledoc false

  @behaviour ReqLLM.Provider.ResponseBuilder

  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Provider.ChunkAccumulator
  alias ReqLLM.Provider.Defaults.ResponseBuilder, as: DefaultBuilder

  @impl true
  def build_response(chunks, metadata, opts) do
    with {:ok, response} <- DefaultBuilder.build_response(chunks, metadata, opts) do
      if Enum.any?(response.message.content, &match?(%{type: :object}, &1)) do
        acc = ChunkAccumulator.reduce(ChunkAccumulator.new(), chunks)
        text = ChunkAccumulator.finalize_text(acc)
        thinking = ChunkAccumulator.finalize_thinking(acc)
        content = [ContentPart.text(text)]

        content =
          if thinking == "", do: content, else: content ++ [ContentPart.thinking(thinking)]

        message = %{response.message | content: content}

        response =
          ReqLLM.Context.merge_response(Keyword.fetch!(opts, :context), %{
            response
            | message: message
          })

        {:ok, response}
      else
        {:ok, response}
      end
    end
  end
end

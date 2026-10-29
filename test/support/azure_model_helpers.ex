defmodule ReqLLM.Test.AzureModelHelpers do
  @moduledoc false

  def chat_model(id, attrs \\ []) do
    model(id, %{chat: true}, attrs)
  end

  def embedding_model(id, attrs \\ []) do
    model(id, %{embeddings: true}, attrs)
  end

  def traditional_openai_model do
    chat_model("gpt-4o", extra: %{})
  end

  defp model(id, capabilities, attrs) do
    struct!(
      LLMDB.Model,
      Keyword.merge([id: id, provider: :azure, capabilities: capabilities], attrs)
    )
  end
end

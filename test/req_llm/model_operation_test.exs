defmodule ReqLLM.ModelOperationTest do
  use ExUnit.Case, async: true

  alias ReqLLM.ModelOperation

  describe "normalize/1" do
    test "normalizes known operation strings" do
      assert ModelOperation.normalize("image") == :image
      assert ModelOperation.normalize("speech") == :speech
      assert ModelOperation.normalize("transcription") == :transcription
      assert ModelOperation.normalize("rerank") == :rerank
      assert ModelOperation.normalize("ocr") == :ocr
    end
  end

  describe "supported?/2" do
    test "classifies image models by output modality" do
      model =
        model("gpt-image-1.5", provider: :openai, modalities: %{input: [:text], output: [:image]})

      assert ModelOperation.supported?(model, :image)
      refute ModelOperation.supported?(model, :text)
    end

    test "classifies speech models by audio output" do
      model =
        model("eleven_multilingual_v2",
          provider: :elevenlabs,
          modalities: %{input: [:text], output: [:audio]}
        )

      assert ModelOperation.supported?(model, :speech)
      refute ModelOperation.supported?(model, :text)
    end

    test "classifies transcription models by audio input" do
      model =
        model("whisper-large-v3",
          provider: :groq,
          modalities: %{input: [:audio], output: [:text]}
        )

      assert ModelOperation.supported?(model, :transcription)
      refute ModelOperation.supported?(model, :text)
    end

    test "classifies rerank models by capability" do
      model = model("rerank-v3.5", provider: :cohere, capabilities: %{rerank: true})

      assert ModelOperation.supported?(model, :rerank)
      refute ModelOperation.supported?(model, :text)
    end

    test "classifies embeddings without treating ordinary chat as embedding" do
      embedding = model("text-embedding-3-small", capabilities: %{embeddings: %{enabled: true}})
      chat = model("gpt-4o-mini", capabilities: %{chat: true, embeddings: false})

      assert ModelOperation.supported?(embedding, :embedding)
      refute ModelOperation.supported?(chat, :embedding)
      assert ModelOperation.supported?(chat, :text)
    end

    test "keeps multimodal chat models in text coverage" do
      model =
        model("gemini-2.0-flash",
          capabilities: %{chat: true},
          modalities: %{input: [:text, :image, :audio], output: [:text]}
        )

      assert ModelOperation.supported?(model, :text)
      refute ModelOperation.supported?(model, :transcription)
    end
  end

  defp model(id, attrs) do
    attrs
    |> Keyword.put_new(:provider, :test)
    |> Keyword.merge(id: id)
    |> Map.new()
    |> then(&struct!(LLMDB.Model, &1))
  end
end

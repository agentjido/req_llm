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

    test "returns unknown for unsupported operation values" do
      assert ModelOperation.normalize("not-an-operation") == :unknown
      assert ModelOperation.normalize(:not_an_operation) == :unknown
      refute ModelOperation.known?(:unknown)
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
      disabled = model("gpt-4o-mini", capabilities: %{chat: true, embeddings: %{enabled: false}})
      chat = model("gpt-4o-mini", capabilities: %{chat: true, embeddings: false})

      assert ModelOperation.supported?(embedding, :embedding)
      refute ModelOperation.supported?(disabled, :embedding)
      assert ModelOperation.supported?(disabled, :text)
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

    test "keeps image-generation models out of text coverage" do
      model =
        model("gemini-2.5-flash-image",
          provider: :google,
          capabilities: %{chat: true},
          modalities: %{input: [:text, :image], output: [:text, :image]}
        )

      assert ModelOperation.supported?(model, :image)
      refute ModelOperation.supported?(model, :text)
    end

    test "keeps unsupported specialty provider models out of text coverage" do
      transcription =
        model("qwen3-asr-flash",
          provider: :alibaba,
          modalities: %{input: [:audio], output: [:text]}
        )

      speech =
        model("canopylabs/orpheus-v1-english",
          provider: :groq,
          modalities: %{input: [:text], output: [:audio]}
        )

      refute ModelOperation.supported?(transcription, :text)
      refute ModelOperation.supported?(transcription, :transcription)
      assert ModelOperation.type(transcription) == "transcription"

      refute ModelOperation.supported?(speech, :text)
      refute ModelOperation.supported?(speech, :speech)
      assert ModelOperation.type(speech) == "speech"
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

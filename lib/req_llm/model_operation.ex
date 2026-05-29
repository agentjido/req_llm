defmodule ReqLLM.ModelOperation do
  @moduledoc false

  @operations ~w(text embedding image speech transcription rerank ocr all)a
  @image_providers ~w(openai google xai)a
  @speech_providers ~w(openai elevenlabs)a
  @transcription_providers ~w(openai groq elevenlabs)a
  @rerank_providers ~w(cohere)a
  @operation_map for operation <- @operations,
                     into: %{},
                     do: {Atom.to_string(operation), operation}

  @spec operations() :: [atom()]
  def operations, do: @operations

  @spec known?(atom()) :: boolean()
  def known?(operation), do: operation in @operations

  @spec names() :: [String.t()]
  def names, do: Map.keys(@operation_map) |> Enum.sort()

  @spec normalize(atom() | String.t() | nil) :: atom()
  def normalize(nil), do: :text
  def normalize(operation) when operation in @operations, do: operation
  def normalize(operation) when is_atom(operation), do: :unknown

  def normalize(operation) when is_binary(operation) do
    Map.get(@operation_map, String.downcase(String.trim(operation)), :unknown)
  end

  @spec supported?(LLMDB.Model.t() | map(), atom()) :: boolean()
  def supported?(_model, :all), do: true
  def supported?(model, :embedding), do: embedding?(model)
  def supported?(model, :image), do: image?(model)
  def supported?(model, :speech), do: speech?(model)
  def supported?(model, :transcription), do: transcription?(model)
  def supported?(model, :rerank), do: rerank?(model)
  def supported?(model, :ocr), do: ocr?(model)
  def supported?(model, :text), do: text?(model)
  def supported?(_model, _operation), do: false

  @spec category(atom()) :: String.t()
  def category(:embedding), do: "embedding"
  def category(:image), do: "image"
  def category(:speech), do: "speech"
  def category(:transcription), do: "transcription"
  def category(:rerank), do: "rerank"
  def category(:ocr), do: "ocr"
  def category(_operation), do: "core"

  @spec config_key(atom()) :: atom()
  def config_key(:all), do: :sample_text_models
  def config_key(operation), do: :"sample_#{operation}_models"

  @spec type(LLMDB.Model.t() | map()) :: String.t()
  def type(model) do
    cond do
      embedding?(model) -> "embedding"
      image_model?(model) -> "image"
      speech_model?(model) -> "speech"
      transcription_model?(model) -> "transcription"
      rerank_model?(model) -> "rerank"
      ocr_model?(model) -> "ocr"
      true -> "text"
    end
  end

  defp text?(model) do
    chat_enabled?(model) and
      not embedding?(model) and
      not image_model?(model) and
      not speech_model?(model) and
      not transcription_model?(model) and
      not rerank_model?(model) and
      not ocr_model?(model)
  end

  defp chat_enabled?(model) do
    case capability(model, [:chat]) do
      false -> false
      _ -> modality?(model, :output, :text) or not image?(model)
    end
  end

  defp embedding?(model) do
    capability_present?(model, [:embeddings]) or
      field(model, :type) == "embedding" or
      modality?(model, :output, :embedding)
  end

  defp image?(model) do
    provider?(model, @image_providers) and image_model?(model)
  end

  defp speech?(model) do
    provider?(model, @speech_providers) and speech_model?(model)
  end

  defp transcription?(model) do
    provider?(model, @transcription_providers) and transcription_model?(model)
  end

  defp rerank?(model) do
    provider?(model, @rerank_providers) and rerank_model?(model)
  end

  defp ocr?(model) do
    field(model, :provider) == :google_vertex and ocr_model?(model)
  end

  defp image_model?(model) do
    capability_truthy?(model, [:images]) or
      id_contains?(model, ["image", "imagen", "dall-e"]) or
      (modality?(model, :output, :image) and not modality?(model, :output, :text))
  end

  defp speech_model?(model) do
    (modality?(model, :input, :text) and modality?(model, :output, :audio) and
       not modality?(model, :output, :text)) or
      id_contains?(model, ["tts", "eleven", "orpheus"])
  end

  defp transcription_model?(model) do
    (modality?(model, :input, :audio) and modality?(model, :output, :text) and
       not modality?(model, :input, :text)) or
      id_contains?(model, ["whisper", "scribe", "asr", "transcribe"])
  end

  defp rerank_model?(model) do
    capability_truthy?(model, [:rerank]) or id_contains?(model, ["rerank"])
  end

  defp ocr_model?(model) do
    capability_truthy?(model, [:ocr]) or
      field(model, :family) == "mistral-ocr" or
      id_contains?(model, ["ocr"])
  end

  defp capability_present?(model, path) do
    case capability(model, path) do
      nil -> false
      false -> false
      %{enabled: false} -> false
      %{"enabled" => false} -> false
      _ -> true
    end
  end

  defp capability_truthy?(model, path) do
    case capability(model, path) do
      true -> true
      %{enabled: true} -> true
      %{"enabled" => true} -> true
      _ -> false
    end
  end

  defp capability(model, path) do
    model
    |> field(:capabilities)
    |> get_path(path)
  end

  defp modality?(model, direction, modality) do
    model
    |> field(:modalities)
    |> map_value(direction)
    |> List.wrap()
    |> Enum.any?(&(to_string(&1) == to_string(modality)))
  end

  defp id_contains?(model, needles) do
    id =
      (field(model, :provider_model_id) || field(model, :id) || "")
      |> to_string()
      |> String.downcase()

    Enum.any?(needles, &String.contains?(id, &1))
  end

  defp provider?(model, providers) do
    provider = field(model, :provider)
    provider in providers or to_string(provider) in Enum.map(providers, &Atom.to_string/1)
  end

  defp get_path(nil, _path), do: nil

  defp get_path(value, []) do
    value
  end

  defp get_path(value, [key | rest]) do
    value
    |> map_value(key)
    |> get_path(rest)
  end

  defp field(%LLMDB.Model{} = model, key), do: Map.get(model, key)
  defp field(%{} = model, key), do: map_value(model, key)
  defp field(_model, _key), do: nil

  defp map_value(%{} = map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp map_value(_value, _key), do: nil
end

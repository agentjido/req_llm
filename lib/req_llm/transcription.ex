defmodule ReqLLM.Transcription do
  @moduledoc """
  Speech-to-text transcription functionality for ReqLLM.

  Inspired by the Vercel AI SDK's `transcribe()` function, this module provides
  audio transcription capabilities with support for:

  - Audio file transcription from binary data or file paths
  - Transcript segments with timing information
  - Language detection
  - Duration extraction
  - Provider-specific options

  ## Usage

      # Transcribe from a file path
      {:ok, result} = ReqLLM.transcribe("openai:whisper-1", "/path/to/audio.mp3")

      result.text
      #=> "Hello, this is a transcription test."

      result.segments
      #=> [%{text: "Hello, this is a transcription test.", start_second: 0.0, end_second: 2.5}]

      result.language
      #=> "en"

      result.duration_in_seconds
      #=> 2.5

      # Transcribe from binary audio data
      audio_data = File.read!("/path/to/audio.mp3")
      {:ok, result} = ReqLLM.transcribe("openai:whisper-1", {:binary, audio_data, "audio/mpeg"})

      # With provider-specific options
      {:ok, result} = ReqLLM.transcribe("openai:whisper-1", "/path/to/audio.mp3",
        language: "en",
        provider_options: [prompt: "ZyntriQix, Currentex, Reiterwood"]
      )

  """

  alias ReqLLM.Transcription.Result

  @base_schema NimbleOptions.new!(
                 language: [
                   type: :string,
                   doc:
                     "Language of the audio in ISO-639-1 format (e.g., \"en\"). Helps improve accuracy and speed."
                 ],
                 provider_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "Provider-specific transcription options (keyword list or map)",
                   default: []
                 ],
                 req_http_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "Req-specific options (keyword list or map)",
                   default: []
                 ],
                 receive_timeout: [
                   type: :pos_integer,
                   doc: "Timeout for receiving HTTP responses in milliseconds",
                   default: 120_000
                 ],
                 max_retries: [
                   type: :non_neg_integer,
                   default: 3,
                   doc:
                     "Maximum number of retry attempts for transient network errors. Set to 0 to disable retries."
                 ],
                 on_unsupported: [
                   type: {:in, [:warn, :error, :ignore]},
                   default: :warn,
                   doc: "How to handle provider option translation warnings"
                 ],
                 fixture: [
                   type: {:or, [:string, {:tuple, [:atom, :string]}]},
                   doc: "HTTP fixture for testing (provider inferred from model if string)"
                 ]
               )

  @doc """
  Returns the base transcription options schema.
  """
  @spec schema :: NimbleOptions.t()
  def schema, do: @base_schema

  @doc """
  Transcribes audio using an AI model.

  Returns a `ReqLLM.Transcription.Result` containing the transcribed text,
  segments with timing, detected language, and duration.

  ## Parameters

    * `model_spec` - Model specification (e.g., `"openai:whisper-1"`, `"groq:whisper-large-v3"`)
    * `audio` - Audio input in one of these formats:
      - `String.t()` - File path to an audio file
      - `{:binary, binary(), String.t()}` - Raw audio binary with media type (e.g., `{:binary, data, "audio/mpeg"}`)
      - `{:base64, String.t(), String.t()}` - Base64-encoded audio with media type
    * `opts` - Additional options (keyword list)

  ## Options

    * `:language` - Language hint in ISO-639-1 format (e.g., "en")
    * `:provider_options` - Provider-specific options
    * `:receive_timeout` - HTTP timeout in milliseconds (default: 120_000)

  ## Examples

      # From file path
      {:ok, result} = ReqLLM.transcribe("openai:whisper-1", "speech.mp3")
      result.text #=> "Hello world"

      # From binary data
      data = File.read!("speech.mp3")
      {:ok, result} = ReqLLM.transcribe("openai:whisper-1", {:binary, data, "audio/mpeg"})

      # With language hint
      {:ok, result} = ReqLLM.transcribe("openai:whisper-1", "speech.mp3", language: "en")

  """
  @spec transcribe(
          ReqLLM.model_input(),
          String.t() | {:binary, binary(), String.t()} | {:base64, String.t(), String.t()},
          keyword()
        ) :: {:ok, Result.t()} | {:error, term()}
  def transcribe(model_spec, audio, opts \\ []) do
    with {:ok, audio_data, media_type} <- resolve_audio(audio),
         {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, request} <-
           provider_module.prepare_request(:transcription, model, audio_data, [
             {:media_type, media_type} | opts
           ]),
         {:ok, %Req.Response{status: status, body: body}} when status in 200..299 <-
           Req.request(request) do
      parse_transcription_response(body)
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Transcription request failed",
           status: status,
           response_body: body
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Transcribes audio, raising on error.

  Same as `transcribe/3` but raises on error.
  """
  @spec transcribe!(
          ReqLLM.model_input(),
          String.t() | {:binary, binary(), String.t()} | {:base64, String.t(), String.t()},
          keyword()
        ) :: Result.t() | no_return()
  def transcribe!(model_spec, audio, opts \\ []) do
    case transcribe(model_spec, audio, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp resolve_audio(path) when is_binary(path) do
    case File.read(path) do
      {:ok, data} ->
        media_type = media_type_from_path(path)
        {:ok, data, media_type}

      {:error, reason} ->
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(
           parameter: "audio: could not read file #{path} (#{reason})"
         )}
    end
  end

  defp resolve_audio({:binary, data, media_type})
       when is_binary(data) and is_binary(media_type) do
    {:ok, data, media_type}
  end

  defp resolve_audio({:base64, encoded, media_type})
       when is_binary(encoded) and is_binary(media_type) do
    case Base.decode64(encoded) do
      {:ok, data} ->
        {:ok, data, media_type}

      :error ->
        {:error,
         ReqLLM.Error.Invalid.Parameter.exception(parameter: "audio: invalid base64 encoding")}
    end
  end

  defp resolve_audio(other) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "audio: expected a file path string, {:binary, data, media_type}, or {:base64, data, media_type}, got: #{inspect(other)}"
     )}
  end

  @media_types %{
    ".mp3" => "audio/mpeg",
    ".mp4" => "audio/mp4",
    ".mpeg" => "audio/mpeg",
    ".mpga" => "audio/mpeg",
    ".m4a" => "audio/mp4",
    ".wav" => "audio/wav",
    ".webm" => "audio/webm",
    ".ogg" => "audio/ogg",
    ".flac" => "audio/flac",
    ".opus" => "audio/opus"
  }

  defp media_type_from_path(path) do
    ext = Path.extname(path) |> String.downcase()
    Map.get(@media_types, ext, "application/octet-stream")
  end

  defp parse_transcription_response(%Result{} = result), do: {:ok, result}

  defp parse_transcription_response(body) when is_map(body) do
    text = body["text"] || parse_multichannel_text(body["transcripts"]) || ""

    segments =
      parse_segments(body["segments"]) ++
        parse_word_segments(body["words"]) ++
        parse_multichannel_segments(body["transcripts"])

    language =
      normalize_language(
        body["language"] || body["language_code"] ||
          parse_multichannel_language(body["transcripts"])
      )

    duration = body["duration"] || infer_duration(segments)

    {:ok,
     %Result{
       text: text,
       segments: segments,
       language: language,
       duration_in_seconds: duration
     }}
  end

  defp parse_transcription_response(body) when is_binary(body) do
    # Some providers may return plain text with response_format: "text"
    {:ok, %Result{text: body, segments: [], language: nil, duration_in_seconds: nil}}
  end

  defp parse_transcription_response(other) do
    {:error,
     ReqLLM.Error.API.Response.exception(
       reason: "Unexpected transcription response format",
       response_body: other
     )}
  end

  defp parse_segments(nil), do: []

  defp parse_segments(segments) when is_list(segments) do
    Enum.map(segments, fn seg ->
      %{
        text: seg["text"] || "",
        start_second: seg["start"] || 0.0,
        end_second: seg["end"] || 0.0
      }
    end)
  end

  defp parse_word_segments(nil), do: []

  defp parse_word_segments(words) when is_list(words) do
    Enum.map(words, fn word ->
      %{
        text: word["word"] || word["text"] || "",
        start_second: word["start"] || 0.0,
        end_second: word["end"] || 0.0
      }
    end)
  end

  defp parse_multichannel_segments(nil), do: []

  defp parse_multichannel_segments(transcripts) when is_list(transcripts) do
    Enum.flat_map(transcripts, fn transcript ->
      parse_word_segments(transcript["words"])
    end)
  end

  defp parse_multichannel_text(nil), do: nil

  defp parse_multichannel_text(transcripts) when is_list(transcripts) do
    texts =
      transcripts
      |> Enum.map(&(&1["text"] || ""))
      |> Enum.reject(&(&1 == ""))

    case texts do
      [] -> nil
      _ -> Enum.join(texts, "\n")
    end
  end

  defp parse_multichannel_language(nil), do: nil

  defp parse_multichannel_language(transcripts) when is_list(transcripts) do
    transcripts
    |> Enum.find_value(&(&1["language"] || &1["language_code"]))
  end

  defp infer_duration([]), do: nil

  defp infer_duration(segments) do
    Enum.max_by(segments, &Map.get(&1, :end_second, 0.0), fn -> %{end_second: nil} end).end_second
  end

  # Map full language names (as returned by Whisper) to ISO-639-1 codes
  @language_map %{
    "afrikaans" => "af",
    "arabic" => "ar",
    "armenian" => "hy",
    "azerbaijani" => "az",
    "belarusian" => "be",
    "bosnian" => "bs",
    "bulgarian" => "bg",
    "catalan" => "ca",
    "chinese" => "zh",
    "croatian" => "hr",
    "czech" => "cs",
    "danish" => "da",
    "dutch" => "nl",
    "english" => "en",
    "estonian" => "et",
    "finnish" => "fi",
    "french" => "fr",
    "galician" => "gl",
    "german" => "de",
    "greek" => "el",
    "hebrew" => "he",
    "hindi" => "hi",
    "hungarian" => "hu",
    "icelandic" => "is",
    "indonesian" => "id",
    "italian" => "it",
    "japanese" => "ja",
    "kannada" => "kn",
    "kazakh" => "kk",
    "korean" => "ko",
    "latvian" => "lv",
    "lithuanian" => "lt",
    "macedonian" => "mk",
    "malay" => "ms",
    "marathi" => "mr",
    "maori" => "mi",
    "nepali" => "ne",
    "norwegian" => "no",
    "persian" => "fa",
    "polish" => "pl",
    "portuguese" => "pt",
    "romanian" => "ro",
    "russian" => "ru",
    "serbian" => "sr",
    "slovak" => "sk",
    "slovenian" => "sl",
    "spanish" => "es",
    "swahili" => "sw",
    "swedish" => "sv",
    "tagalog" => "tl",
    "tamil" => "ta",
    "thai" => "th",
    "turkish" => "tr",
    "ukrainian" => "uk",
    "urdu" => "ur",
    "vietnamese" => "vi",
    "welsh" => "cy"
  }

  defp normalize_language(nil), do: nil

  defp normalize_language(lang) when is_binary(lang) do
    # If already a 2-letter code, return as-is
    if String.length(lang) == 2 do
      lang
    else
      # Try to map from full name
      Map.get(@language_map, String.downcase(lang), lang)
    end
  end
end

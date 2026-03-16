defmodule ReqLLM.Speech.Result do
  @moduledoc """
  Result of a text-to-speech generation operation.

  Contains the generated audio binary, media type, format, and optional duration.
  Inspired by the Vercel AI SDK's `SpeechResult`.

  ## Fields

    * `:audio` - The generated audio as raw binary data
    * `:media_type` - The IANA media type of the audio (e.g., "audio/mpeg")
    * `:format` - The audio format as a string (e.g., "mp3", "wav")
    * `:duration_in_seconds` - The duration of the generated audio, or `nil`

  ## Examples

      %ReqLLM.Speech.Result{
        audio: <<...binary data...>>,
        media_type: "audio/mpeg",
        format: "mp3",
        duration_in_seconds: nil
      }

  """

  @type t :: %__MODULE__{
          audio: binary(),
          media_type: String.t(),
          format: String.t(),
          duration_in_seconds: float() | nil
        }

  defstruct audio: <<>>,
            media_type: "audio/mpeg",
            format: "mp3",
            duration_in_seconds: nil
end

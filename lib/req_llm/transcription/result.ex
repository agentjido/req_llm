defmodule ReqLLM.Transcription.Result do
  @moduledoc """
  Result of an audio transcription operation.

  Contains the transcribed text, optional timing segments, detected language,
  and audio duration. Inspired by the Vercel AI SDK's `TranscriptionResult`.

  ## Fields

    * `:text` - The complete transcribed text from the audio input
    * `:segments` - List of transcript segments with timing information.
      Each segment is a map with:
      - `:text` - The text content of this segment
      - `:start_second` - Start time in seconds
      - `:end_second` - End time in seconds
    * `:language` - The detected language in ISO-639-1 format (e.g., "en"), or `nil`
    * `:duration_in_seconds` - The total duration of the audio in seconds, or `nil`

  ## Examples

      %ReqLLM.Transcription.Result{
        text: "Hello, how are you?",
        segments: [
          %{text: "Hello,", start_second: 0.0, end_second: 0.5},
          %{text: " how are you?", start_second: 0.5, end_second: 1.2}
        ],
        language: "en",
        duration_in_seconds: 1.2
      }

  """

  @type segment :: %{
          text: String.t(),
          start_second: float(),
          end_second: float()
        }

  @type t :: %__MODULE__{
          text: String.t(),
          segments: [segment()],
          language: String.t() | nil,
          duration_in_seconds: float() | nil
        }

  defstruct text: "",
            segments: [],
            language: nil,
            duration_in_seconds: nil
end

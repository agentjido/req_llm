# StepFun

ReqLLM supports StepFun chat, text streaming, tool calls, object generation,
speech generation, and speech transcription.

## Setup

Set `STEPFUN_API_KEY` in the environment or in the project's `.env` file.
Use the provider that matches the account which issued the key:

| Provider | API base URL |
| --- | --- |
| `stepfun_ai` (Global) | `https://api.stepfun.ai/v1` |
| `stepfun` (China) | `https://api.stepfun.com/v1` |

The examples use full model specifications. These work before the new LLMDB
catalog is released. With the updated catalog, you can also use strings such as
`"stepfun_ai:stepaudio-3-tts"`.

## Chat

```elixir
model = ReqLLM.model!(%{provider: :stepfun_ai, id: "step-3.5-flash"})

{:ok, response} = ReqLLM.generate_text(model, "Hello!", max_tokens: 512)
text = ReqLLM.Response.text(response)

{:ok, stream} = ReqLLM.stream_text(model, "Hello!", max_tokens: 512)
{:ok, response} = ReqLLM.StreamResponse.to_response(stream)
```

Set `reasoning_effort: :low`, `:medium`, or `:high` for models that support it.
`step-3.5-flash-2603` accepts only `:low` and `:high`.
The provider requests `reasoning_format: "deepseek-style"` by default.
To use the other response field, set
`provider_options: [reasoning_format: "general"]`.

`generate_object/4` uses tool calling. StepFun's JSON mode does not provide
strict JSON Schema validation.

For audio chat, use `stepaudio-3-chat-preview` or `stepaudio-2.5-chat` and
`ReqLLM.Message.ContentPart.file/3` with MP3 or WAV bytes. The provider encodes
these bytes as an `input_audio` data URI. Video inputs use
`ReqLLM.Message.ContentPart.video_url/1` on models that support video.

## Speech generation

Supported models: `stepaudio-3-tts` and `stepaudio-2.5-tts`.

```elixir
model = ReqLLM.model!(%{provider: :stepfun_ai, id: "stepaudio-3-tts"})

{:ok, result} = ReqLLM.speak(model, "Hello from StepFun.",
  output_format: :wav,
  voice: "soft-spoken-gentleman",
  provider_options: [instruction: "Speak slowly."]
)

File.write!("speech.wav", result.audio)
```

The default voice is `soft-spoken-gentleman`. Supported output formats are
`:wav`, `:mp3`, `:flac`, `:opus`, and `:pcm`. The default format is `:mp3`.
StepFun limits each input to 1,000 characters.

Use `speed:` and `language:` for the common options. StepFun options include
`instruction`, `volume`, `sample_rate`, `pronunciation_map`, and `markdown_filter`
inside `provider_options`.

`ReqLLM.speak/3` returns audio bytes. The provider rejects `return_url: true`
and `stream_format: "sse"`, which return different response types.

## Transcription

Supported models: `stepaudio-3-asr-max` and `stepaudio-2.5-asr`.

```elixir
model = ReqLLM.model!(%{provider: :stepfun_ai, id: "stepaudio-3-asr-max"})

{:ok, result} = ReqLLM.transcribe(model, "speech.wav", language: "en")
IO.puts(result.text)
```

The provider sends JSON with base64 audio to `/audio/asr/sse`. It reads the full
SSE response and returns the final transcript. It does not return partial text
if the final event is missing or the server reports an error. Segment times
are not supplied by this endpoint.

Supported input formats are OGG, MP3, WAV, M4A, and PCM. For PCM, specify the
sample rate, bit depth, and channel count:

```elixir
{:ok, result} = ReqLLM.transcribe(model, {:binary, pcm_bytes, "audio/pcm"},
  provider_options: [
    audio_format: %{
      type: "pcm",
      codec: "pcm_s16le",
      rate: 16_000,
      bits: 16,
      channel: 1
    },
    enable_itn: true
  ]
)
```

## Other audio models

LLMDB records the real-time, streaming ASR, music, and audio generation models.
ReqLLM does not yet support their WebSocket sessions or asynchronous generation
APIs. These models remain marked as catalog-only. Do not pass them to
`generate_text/3`, `speak/3`, or `transcribe/3`.

Global speech prices use billable characters. Global transcription prices use
audio duration. The catalog records these rates as separate pricing components.
ReqLLM does not calculate a cost from character or duration usage for this
provider. China prices are not inferred from Global prices.

See the official [chat API](https://platform.stepfun.ai/docs/en/api-reference/chat/chat-completion-create),
[speech API](https://platform.stepfun.ai/docs/en/api-reference/audio/create-audio),
[transcription API](https://platform.stepfun.ai/docs/en/api-reference/audio/asr-sse),
and [price list](https://platform.stepfun.ai/docs/en/guides/pricing/details).

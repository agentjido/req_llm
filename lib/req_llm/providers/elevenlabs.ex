defmodule ReqLLM.Providers.ElevenLabs do
  @moduledoc """
  ElevenLabs provider for text-to-speech and speech-to-text transcription.

  ## Implementation

  ElevenLabs uses different API formats from OpenAI-compatible providers:

  - Text-to-speech uses `/v1/text-to-speech/{voiceId}` with `xi-api-key`
  - Speech-to-text uses multipart `POST /v1/speech-to-text`
  - Authentication uses `xi-api-key` header instead of Bearer auth

  ## Supported Operations

  ElevenLabs supports:

  - `:speech` for text-to-speech
  - `:transcription` for speech-to-text

  Chat and embedding operations are not supported.

  ## Configuration

      # Add to .env file (automatically loaded)
      ELEVENLABS_API_KEY=sk_...

  ## Usage

      {:ok, result} = ReqLLM.speak(
        %{id: "eleven_multilingual_v2", provider: :elevenlabs},
        "Hello, world!",
        voice: "21m00Tcm4TlvDq8ikWAM"
      )

      {:ok, result} = ReqLLM.transcribe(
        %{id: "scribe_v2", provider: :elevenlabs},
        "/path/to/audio.mp3"
      )

  ## Provider Options

  ElevenLabs-specific options can be passed via `provider_options`:

  Speech options:

  - `stability` - Voice stability (0.0 to 1.0)
  - `similarity_boost` - Voice similarity boost (0.0 to 1.0)
  - `style` - Style exaggeration (0.0 to 1.0)
  - `speed` - Speech speed (0.5 to 2.0)

  Transcription options:

  - `enable_logging`
  - `tag_audio_events`
  - `num_speakers`
  - `timestamps_granularity`
  - `diarize`
  - `diarization_threshold`
  - `file_format`
  - `cloud_storage_url`
  - `webhook`
  - `webhook_id`
  - `temperature`
  - `seed`
  - `use_multi_channel`
  - `webhook_metadata`
  - `entity_detection`
  - `keyterms`
  """

  use ReqLLM.Provider,
    id: :elevenlabs,
    default_base_url: "https://api.elevenlabs.io",
    default_env_key: "ELEVENLABS_API_KEY"

  @default_voice "21m00Tcm4TlvDq8ikWAM"

  # https://elevenlabs.io/docs/api-reference/text-to-speech/convert
  @format_mapping %{
    mp3: "mp3_44100_128",
    pcm: "pcm_44100",
    opus: "opus_48000_64",
    wav: "wav_44100"
  }

  @impl ReqLLM.Provider
  def prepare_request(:speech, model_spec, text, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec) do
      http_opts = Keyword.get(opts, :req_http_options, [])
      voice = Keyword.get(opts, :voice, @default_voice)
      output_format = Keyword.get(opts, :output_format, :mp3)
      language = Keyword.get(opts, :language)
      provider_options = Keyword.get(opts, :provider_options, [])
      timeout = Keyword.get(opts, :receive_timeout, 120_000)

      api_key = ReqLLM.Keys.get!(model, opts)

      format_string = Map.get(@format_mapping, output_format, "mp3_44100_128")

      body =
        %{text: text, model_id: model.id}
        |> maybe_put(:language_code, language)
        |> maybe_put_voice_settings(provider_options)

      request =
        Req.new(
          [
            url: "/v1/text-to-speech/#{voice}",
            method: :post,
            base_url: Keyword.get(opts, :base_url, default_base_url()),
            params: [output_format: format_string],
            receive_timeout: timeout,
            pool_timeout: timeout,
            body: Jason.encode!(body),
            decode_body: false
          ] ++ http_opts
        )
        |> Req.Request.put_header("content-type", "application/json")
        |> Req.Request.put_header("xi-api-key", api_key)
        |> ReqLLM.Step.Retry.attach()
        |> ReqLLM.Step.Error.attach()
        |> ReqLLM.Step.Fixture.maybe_attach(model, opts)

      {:ok, request}
    end
  end

  def prepare_request(:transcription, model_spec, audio_data, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec) do
      http_opts = Keyword.get(opts, :req_http_options, [])
      media_type = Keyword.get(opts, :media_type, "audio/mpeg")
      language = Keyword.get(opts, :language)
      provider_options = normalize_provider_options(Keyword.get(opts, :provider_options, []))
      timeout = Keyword.get(opts, :receive_timeout, 120_000)

      ext = ReqLLM.Provider.Defaults.media_type_to_extension(media_type)
      filename = "audio.#{ext}"
      api_key = ReqLLM.Keys.get!(model, opts)

      form_parts =
        [
          file: {audio_data, filename: filename, content_type: media_type},
          model_id: model.id
        ]
        |> maybe_add_multipart_part(:language_code, language)
        |> maybe_add_transcription_parts(provider_options)

      request =
        Req.new(
          [
            url: "/v1/speech-to-text",
            method: :post,
            base_url: Keyword.get(opts, :base_url, default_base_url()),
            params: transcription_query_params(provider_options),
            receive_timeout: timeout,
            pool_timeout: timeout,
            form_multipart: form_parts
          ] ++ http_opts
        )
        |> Req.Request.put_header("xi-api-key", api_key)
        |> ReqLLM.Step.Retry.attach()
        |> ReqLLM.Step.Error.attach()
        |> ReqLLM.Step.Fixture.maybe_attach(model, opts)

      {:ok, request}
    end
  end

  def prepare_request(operation, _model_spec, _input, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: #{inspect(operation)} is not supported by ElevenLabs. Only :speech and :transcription are supported."
     )}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_provider_options(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_provider_options(opts) when is_list(opts), do: opts
  defp normalize_provider_options(_opts), do: []

  defp transcription_query_params(opts) do
    case List.keyfind(opts, :enable_logging, 0) do
      {:enable_logging, value} when not is_nil(value) -> [enable_logging: value]
      _ -> []
    end
  end

  defp maybe_add_multipart_part(parts, _key, nil), do: parts

  defp maybe_add_multipart_part(parts, key, value) when is_list(value) do
    Enum.reduce(value, parts, &maybe_add_multipart_part(&2, key, &1))
  end

  defp maybe_add_multipart_part(parts, key, value) when is_map(value) do
    parts ++ [{key, Jason.encode!(value)}]
  end

  defp maybe_add_multipart_part(parts, key, value), do: parts ++ [{key, to_string(value)}]

  defp maybe_add_transcription_parts(parts, opts) do
    Enum.reduce(opts, parts, fn
      {:enable_logging, _value}, acc ->
        acc

      {key, value}, acc ->
        maybe_add_multipart_part(acc, key, value)
    end)
  end

  defp maybe_put_voice_settings(body, opts) when is_list(opts) do
    maybe_put_voice_settings(body, Map.new(opts))
  end

  defp maybe_put_voice_settings(body, opts) when is_map(opts) do
    settings =
      %{}
      |> maybe_put(:stability, opts[:stability])
      |> maybe_put(:similarity_boost, opts[:similarity_boost])
      |> maybe_put(:style, opts[:style])
      |> maybe_put(:speed, opts[:speed])

    if map_size(settings) > 0 do
      Map.put(body, :voice_settings, settings)
    else
      body
    end
  end

  defp maybe_put_voice_settings(body, _), do: body
end

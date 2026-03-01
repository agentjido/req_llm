defmodule ReqLLM.Providers.ElevenLabs do
  @moduledoc """
  ElevenLabs provider – speech-only provider for high-quality text-to-speech.

  ## Implementation

  ElevenLabs uses a different API format from OpenAI's speech endpoint:

  - Voice ID is part of the URL path (`/v1/text-to-speech/{voiceId}`)
  - Authentication uses `xi-api-key` header (not Bearer token)
  - Output format is a query parameter (not a body field)
  - Body uses `text` and `model_id` (not `input` and `model`)

  ## Supported Operations

  Only `:speech` is supported. Chat, embedding, and transcription operations
  will return an error.

  ## Configuration

      # Add to .env file (automatically loaded)
      ELEVENLABS_API_KEY=sk_...

  ## Usage

      {:ok, result} = ReqLLM.speak(
        %{id: "eleven_multilingual_v2", provider: :elevenlabs},
        "Hello, world!",
        voice: "21m00Tcm4TlvDq8ikWAM"
      )

  ## Provider Options

  ElevenLabs-specific options can be passed via `provider_options`:

  - `stability` - Voice stability (0.0 to 1.0)
  - `similarity_boost` - Voice similarity boost (0.0 to 1.0)
  - `style` - Style exaggeration (0.0 to 1.0)
  - `speed` - Speech speed (0.5 to 2.0)
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

  def prepare_request(operation, _model_spec, _input, _opts) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: #{inspect(operation)} is not supported by ElevenLabs. Only :speech is supported."
     )}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

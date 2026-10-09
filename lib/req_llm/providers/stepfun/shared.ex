defmodule ReqLLM.Providers.StepFun.Shared do
  @moduledoc false

  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Provider.Defaults
  alias ReqLLM.Provider.Options
  alias ReqLLM.Streaming.SSE

  @speech_models ~w(stepaudio-3-tts stepaudio-2.5-tts)
  @transcription_models ~w(stepaudio-3-asr-max stepaudio-2.5-asr)

  def provider_schema do
    [
      reasoning_format: [type: {:in, ~w(general deepseek-style)}, doc: "Reasoning response field"],
      instruction: [type: :string, doc: "Speech delivery instructions"],
      volume: [type: :float, doc: "Speech volume multiplier"],
      sample_rate: [type: :pos_integer, doc: "Speech output sample rate"],
      pronunciation_map: [type: :map, doc: "Speech pronunciation rules"],
      markdown_filter: [type: :boolean, doc: "Filter Markdown from speech input"],
      stream_format: [type: {:in, ~w(audio sse)}, doc: "Speech response format"],
      return_url: [type: :boolean, doc: "Return an audio URL instead of audio bytes"],
      enable_itn: [type: :boolean, doc: "Normalize numbers and dates in transcripts"],
      audio_format: [type: :map, doc: "ASR input format, including PCM rate, bits, and channel"]
    ]
  end

  def prepare_request(provider, :speech, model_spec, text, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         :ok <- require_model(model, @speech_models, :speech),
         :ok <- require_binary_speech(opts) do
      provider_options =
        opts
        |> Keyword.get(:provider_options, [])
        |> Map.new()
        |> put_optional(:language, opts[:language])

      opts =
        opts
        |> Keyword.put_new(:voice, "soft-spoken-gentleman")
        |> Keyword.put(:provider_options, provider_options)
        |> Keyword.put(:base_url, Options.effective_base_url(provider, model, opts))

      Defaults.prepare_speech_request(provider, model, text, opts)
    end
  end

  def prepare_request(provider, :transcription, model_spec, audio, opts) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         :ok <- require_model(model, @transcription_models, :transcription),
         {:ok, format} <- input_format(opts) do
      provider_options = Map.new(Keyword.get(opts, :provider_options, []))

      transcription =
        %{model: model.provider_model_id || model.id}
        |> put_optional(:language, opts[:language])
        |> put_optional(:enable_itn, option(provider_options, :enable_itn))

      body = %{
        audio: %{
          data: Base.encode64(audio),
          input: %{transcription: transcription, format: format}
        }
      }

      timeout = Keyword.get(opts, :receive_timeout, 120_000)
      key = ReqLLM.Keys.get!(model, opts)
      http_opts = Keyword.get(opts, :req_http_options, [])

      request =
        Req.new(
          [
            url: "/audio/asr/sse",
            method: :post,
            base_url: Options.effective_base_url(provider, model, opts),
            receive_timeout: timeout,
            json: body,
            auth: {:bearer, key},
            decode_body: false
          ] ++ Defaults.merge_finch_options(http_opts, pool_timeout: timeout)
        )
        |> Req.Request.put_header("accept", "text/event-stream")
        |> Req.Request.put_header("authorization", "Bearer " <> key)
        |> ReqLLM.Step.Retry.attach(opts)
        |> ReqLLM.Step.Error.attach()
        |> Req.Request.append_response_steps(
          llm_decode_response: &decode_transcription_response/1
        )
        |> ReqLLM.Step.Telemetry.attach(
          model,
          opts
          |> Keyword.put(:operation, :transcription)
          |> Keyword.put(:audio_bytes, byte_size(audio))
        )
        |> ReqLLM.Step.Fixture.maybe_attach(model, opts)

      {:ok, request}
    end
  end

  def prepare_request(provider, operation, model_spec, input, opts)
      when operation in [:chat, :object] do
    with {:ok, model} <- ReqLLM.model(model_spec),
         :ok <- require_chat_model(model) do
      Defaults.prepare_request(provider, operation, model, input, opts)
    end
  end

  def prepare_request(_provider, operation, _model, _input, _opts) do
    invalid("StepFun does not support #{operation} through this provider")
  end

  def attach_stream(provider, model, context, opts, finch_name) do
    with :ok <- require_chat_model(model) do
      Defaults.default_attach_stream(provider, model, context, opts, finch_name)
    end
  end

  def build_body(request) do
    context = request.options[:context]
    wire_context = encode_media_context(context)

    request = %{request | options: Map.put(request.options, :context, wire_context)}

    request
    |> Defaults.default_build_body()
    |> ReqLLM.Providers.OpenAI.AdapterHelpers.translate_tool_choice_format()
    |> restore_media_content(context)
    |> Map.put(:reasoning_format, request.options[:reasoning_format] || "deepseek-style")
    |> put_optional(:reasoning_effort, reasoning_effort(request.options[:reasoning_effort]))
  end

  def decode_transcription_response(
        {request, %Req.Response{status: status, body: body} = response}
      )
      when status in 200..299 and is_binary(body) do
    case decode_transcript(body) do
      {:ok, transcript} -> {request, %{response | body: transcript}}
      {:error, error} -> {request, error}
    end
  end

  def decode_transcription_response(request_response), do: request_response

  defp decode_transcript(body) do
    body
    |> SSE.parse_sse_binary()
    |> Enum.reduce_while({:ok, nil}, fn event, {:ok, transcript} ->
      case event.data do
        %{"type" => "transcript.text.done", "text" => text} = data when is_binary(text) ->
          {:cont, {:ok, Map.take(data, ["text", "usage", "language", "duration"])}}

        %{"type" => "transcript.text.delta"} ->
          {:cont, {:ok, transcript}}

        %{"type" => type} = data when type in ["error", "transcript.text.error"] ->
          {:halt,
           {:error,
            ReqLLM.Error.API.Response.exception(
              reason: "StepFun transcription failed",
              status: 200,
              response_body: data
            )}}

        "[DONE]" ->
          {:cont, {:ok, transcript}}

        _ ->
          {:halt, invalid_response("StepFun returned an invalid transcription event")}
      end
    end)
    |> case do
      {:ok, nil} -> invalid_response("StepFun transcription ended without a final transcript")
      result -> result
    end
  end

  defp input_format(opts) do
    provider_options = Map.new(Keyword.get(opts, :provider_options, []))

    format =
      option(provider_options, :audio_format) ||
        %{type: media_format(Keyword.get(opts, :media_type, "audio/mpeg"))}

    type = option(format, :type)

    cond do
      type not in ~w(ogg mp3 wav pcm m4a) ->
        invalid("StepFun ASR requires ogg, mp3, wav, pcm, or m4a audio")

      type == "pcm" and
          not Enum.all?(
            [:rate, :bits, :channel],
            &(is_integer(option(format, &1)) and option(format, &1) > 0)
          ) ->
        invalid("StepFun PCM input requires audio_format rate, bits, and channel")

      true ->
        {:ok, format}
    end
  end

  defp media_format("audio/mpeg"), do: "mp3"
  defp media_format("audio/mp3"), do: "mp3"
  defp media_format("audio/wav"), do: "wav"
  defp media_format("audio/x-wav"), do: "wav"
  defp media_format("audio/ogg"), do: "ogg"
  defp media_format("audio/opus"), do: "ogg"
  defp media_format("audio/mp4"), do: "m4a"
  defp media_format("audio/m4a"), do: "m4a"
  defp media_format("audio/pcm"), do: "pcm"
  defp media_format(_), do: nil

  defp require_binary_speech(opts) do
    provider_options = Map.new(Keyword.get(opts, :provider_options, []))

    cond do
      option(provider_options, :return_url) == true ->
        invalid("ReqLLM.speak requires audio bytes; StepFun return_url is not supported")

      option(provider_options, :stream_format) == "sse" ->
        invalid("ReqLLM.speak requires audio bytes; StepFun SSE speech is not supported")

      Keyword.get(opts, :output_format, :mp3) not in [:wav, :mp3, :flac, :opus, :pcm] ->
        invalid("StepFun speech requires wav, mp3, flac, opus, or pcm output")

      true ->
        :ok
    end
  end

  defp require_model(model, supported, operation) do
    if (model.provider_model_id || model.id) in supported do
      :ok
    else
      invalid("StepFun #{operation} supports #{Enum.join(supported, ", ")}")
    end
  end

  defp require_chat_model(model) do
    id = model.provider_model_id || model.id

    if get_in(model.capabilities || %{}, [:chat]) == false or
         String.contains?(id, ["-tts", "-asr", "-realtime", "-gen-", "-music-"]) do
      invalid("StepFun model #{id} does not use the Chat Completions API")
    else
      :ok
    end
  end

  defp encode_media_context(%Context{messages: messages} = context) do
    %{context | messages: Enum.map(messages, &encode_media_message/1)}
  end

  defp encode_media_context(context), do: context

  defp encode_media_message(%Message{content: content} = message) when is_list(content) do
    content =
      Enum.map(content, fn part ->
        if media_part?(part), do: ContentPart.text(""), else: part
      end)

    %{message | content: content}
  end

  defp encode_media_message(message), do: message

  defp restore_media_content(%{messages: messages} = body, %Context{} = context) do
    %{body | messages: Enum.zip_with(messages, context.messages, &restore_media_message/2)}
  end

  defp restore_media_message(encoded, %Message{content: content}) when is_list(content) do
    if Enum.any?(content, &media_part?/1) do
      Map.put(encoded, :content, Enum.flat_map(content, &encode_content_part/1))
    else
      encoded
    end
  end

  defp restore_media_message(encoded, _original), do: encoded

  defp media_part?(%ContentPart{type: :video_url}), do: true

  defp media_part?(%ContentPart{type: :file, media_type: "audio/" <> _}), do: true

  defp media_part?(_), do: false

  defp encode_content_part(%ContentPart{type: :file, data: data, media_type: media_type})
       when is_binary(data) and
              media_type in ["audio/mpeg", "audio/mp3", "audio/wav", "audio/x-wav"] do
    media_type =
      if media_type in ["audio/wav", "audio/x-wav"], do: "audio/wav", else: "audio/mpeg"

    [
      %{
        type: "input_audio",
        input_audio: %{data: "data:#{media_type};base64,#{Base.encode64(data)}"}
      }
    ]
  end

  defp encode_content_part(%ContentPart{type: :file, media_type: "audio/" <> _}) do
    raise ReqLLM.Error.Invalid.Message.exception(
            reason: "StepFun chat requires MP3 or WAV audio bytes"
          )
  end

  defp encode_content_part(%ContentPart{type: :video_url, url: url}) do
    [%{type: "video_url", video_url: %{url: url}}]
  end

  defp encode_content_part(%ContentPart{type: :thinking}), do: []

  defp encode_content_part(part) do
    context = Context.new([%Message{role: :user, content: [part]}])
    %{messages: [%{content: content}]} = Defaults.encode_context_to_openai_format(context, "")

    case content do
      text when is_binary(text) -> [%{type: "text", text: text}]
      blocks when is_list(blocks) -> blocks
    end
  end

  defp reasoning_effort(nil), do: nil
  defp reasoning_effort(:default), do: nil
  defp reasoning_effort(effort), do: to_string(effort)

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp option(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp invalid(message) do
    {:error, ReqLLM.Error.Invalid.Parameter.exception(parameter: message)}
  end

  defp invalid_response(message) do
    {:error, ReqLLM.Error.API.Response.exception(reason: message, status: 200)}
  end
end

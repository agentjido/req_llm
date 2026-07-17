defmodule ReqLLM.Speech do
  @moduledoc """
  Text-to-speech generation functionality for ReqLLM.

  Inspired by the Vercel AI SDK's `generateSpeech()` function, this module provides
  speech synthesis capabilities with support for:

  - Multiple voices and output formats
  - Speed control
  - Provider-specific instructions (e.g., tone, style)
  - Language selection

  ## Usage

      # Basic speech generation
      {:ok, result} = ReqLLM.speak("openai:tts-1", "Hello, how are you?", voice: "alloy")
      File.write!("greeting.mp3", result.audio)

      # With options
      {:ok, result} = ReqLLM.speak("openai:tts-1-hd", "Welcome to our app!",
        voice: "nova",
        speed: 1.2,
        output_format: :wav
      )

      # With instructions (gpt-4o-mini-tts)
      {:ok, result} = ReqLLM.speak("openai:gpt-4o-mini-tts", "Breaking news!",
        voice: "coral",
        provider_options: [instructions: "Speak in an excited, energetic tone"]
      )

  """

  alias ReqLLM.Speech.DetailedResult
  alias ReqLLM.Speech.Result

  @output_formats ~w(mp3 opus aac flac wav pcm)a

  @base_schema NimbleOptions.new!(
                 voice: [
                   type: :string,
                   doc:
                     "Voice identifier for speech generation (e.g., \"alloy\", \"echo\", \"nova\")"
                 ],
                 speed: [
                   type: :float,
                   doc: "Speech speed multiplier (0.25 to 4.0, default 1.0)"
                 ],
                 output_format: [
                   type: {:in, @output_formats},
                   default: :mp3,
                   doc: "Audio output format: #{inspect(@output_formats)}"
                 ],
                 language: [
                   type: :string,
                   doc: "ISO-639-1 language code (e.g., \"en\", \"es\"). Provider support varies."
                 ],
                 provider_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc:
                     "Provider-specific options (e.g., [instructions: \"Speak slowly\"] for gpt-4o-mini-tts)",
                   default: []
                 ],
                 req_http_options: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "Req-specific options (keyword list or map)",
                   default: []
                 ],
                 telemetry: [
                   type: {:or, [:map, {:list, :any}]},
                   doc: "ReqLLM telemetry options (for example, [payloads: :raw])",
                   default: []
                 ],
                 receive_timeout: [
                   type: :pos_integer,
                   doc: "Timeout for receiving HTTP responses in milliseconds",
                   default: 120_000
                 ],
                 total_timeout: [
                   type: {:or, [:pos_integer, {:in, [:infinity]}]},
                   doc: "Optional total model-call timeout in milliseconds, including retries"
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
  Returns the base speech generation options schema.
  """
  @spec schema :: NimbleOptions.t()
  def schema, do: @base_schema

  @doc """
  Generates speech audio from text using an AI model.

  Returns a `ReqLLM.Speech.Result` containing the generated audio binary,
  media type, and format information.

  ## Parameters

    * `model_spec` - Model specification (e.g., `"openai:tts-1"`, `"openai:gpt-4o-mini-tts"`)
    * `text` - The text to convert to speech
    * `opts` - Additional options (keyword list)

  ## Options

    * `:voice` - Voice identifier (e.g., "alloy", "echo", "fable", "onyx", "nova", "shimmer")
    * `:speed` - Speech speed multiplier (0.25 to 4.0)
    * `:output_format` - Audio format: `:mp3`, `:opus`, `:aac`, `:flac`, `:wav`, `:pcm`
    * `:language` - ISO-639-1 language code
    * `:provider_options` - Provider-specific options (e.g., `[instructions: "Speak calmly"]`)
    * `:receive_timeout` - HTTP timeout in milliseconds (default: 120_000)
    * `:total_timeout` - Optional whole-call deadline in milliseconds, including retries

  ## Examples

      {:ok, result} = ReqLLM.speak("openai:tts-1", "Hello world", voice: "alloy")
      File.write!("hello.mp3", result.audio)

      {:ok, result} = ReqLLM.speak("openai:tts-1-hd", "High quality audio",
        voice: "nova",
        output_format: :wav
      )

  """
  @spec speak(
          ReqLLM.model_input(),
          String.t(),
          keyword()
        ) :: {:ok, Result.t()} | {:error, term()}
  def speak(model_spec, text, opts \\ []) do
    perform_speech(model_spec, text, opts, :result)
  end

  @doc """
  Generates speech and returns the unchanged speech result with sparse metadata
  for the same provider call.

  The returned `ReqLLM.Speech.DetailedResult` keeps the legacy result at
  `detailed.result`. Its `call_metadata` always identifies the model and provider,
  then includes status, usage and cost, correlation and provider request IDs,
  warnings, and timings only when the request pipeline supplied them.

  This function performs one provider request and preserves the provider's audio
  response without introducing another delivery path. Use `speak/3` when call
  metadata is not needed.
  """
  @spec speak_detailed(
          ReqLLM.model_input(),
          String.t(),
          keyword()
        ) :: {:ok, DetailedResult.t()} | {:error, term()}
  def speak_detailed(model_spec, text, opts \\ []) do
    perform_speech(model_spec, text, opts, :detailed)
  end

  defp perform_speech(model_spec, text, opts, return_mode) do
    opts = ReqLLM.ModelInput.merge_tuple_defaults(model_spec, :speech, opts)
    deadline = ReqLLM.TimeoutBudget.deadline(opts)

    with {:ok, model} <- ReqLLM.model(model_spec),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, opts} <-
           ReqLLM.Provider.Options.normalize_namespaced_provider_options(
             provider_module,
             :speech,
             model,
             opts
           ),
         {:ok, request} <-
           provider_module.prepare_request(:speech, model, text, opts) do
      request = maybe_attach_usage(request, model, return_mode)
      started_at = request_started_at(return_mode)

      case ReqLLM.TimeoutBudget.request(request, deadline) do
        {:ok, %Req.Response{status: status, body: body} = response} when status in 200..299 ->
          result = build_result(body, Keyword.get(opts, :output_format, :mp3))
          build_return(result, response, model, text, request_timings(started_at), return_mode)

        {:ok, %Req.Response{status: status, body: body}} ->
          error_body = parse_error_body(body)

          {:error,
           ReqLLM.Error.API.Request.exception(
             reason: "HTTP #{status}: Speech generation failed",
             status: status,
             response_body: error_body
           )}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Generates speech audio from text, raising on error.

  Same as `speak/3` but raises on error.
  """
  @spec speak!(
          ReqLLM.model_input(),
          String.t(),
          keyword()
        ) :: Result.t() | no_return()
  def speak!(model_spec, text, opts \\ []) do
    case speak(model_spec, text, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Generates speech with call metadata, raising on error.

  Same as `speak_detailed/3` but raises on error.
  """
  @spec speak_detailed!(
          ReqLLM.model_input(),
          String.t(),
          keyword()
        ) :: DetailedResult.t() | no_return()
  def speak_detailed!(model_spec, text, opts \\ []) do
    case speak_detailed(model_spec, text, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp maybe_attach_usage(request, model, :detailed) do
    request =
      request
      |> Req.Request.register_options([:operation])
      |> Req.Request.merge_options(operation: :speech)

    if Keyword.has_key?(request.response_steps, :llm_usage) do
      request
    else
      ReqLLM.Step.Usage.attach(request, model, before: :llm_telemetry_stop)
    end
  end

  defp maybe_attach_usage(request, _model, :result), do: request

  defp request_started_at(:detailed), do: System.monotonic_time()
  defp request_started_at(:result), do: nil

  defp build_result(body, output_format) do
    %Result{
      audio: body,
      media_type: format_to_media_type(output_format),
      format: to_string(output_format)
    }
  end

  defp build_return(result, _response, _model, _text, _timings, :result), do: {:ok, result}

  defp build_return(result, response, model, text, timings, :detailed) do
    call_metadata =
      ReqLLM.CallMetadata.from_req_response(response, model,
        include_status: true,
        timings: timings,
        sensitive_sources: [%{content: text}]
      )

    {:ok, %DetailedResult{result: result, call_metadata: call_metadata}}
  end

  defp request_timings(started_at) when is_integer(started_at) do
    duration = System.monotonic_time() - started_at
    microseconds = System.convert_time_unit(duration, :native, :microsecond)

    if microseconds > 0, do: %{request_ms: microseconds / 1_000}
  end

  defp request_timings(nil), do: nil

  @format_media_types %{
    mp3: "audio/mpeg",
    opus: "audio/opus",
    aac: "audio/aac",
    flac: "audio/flac",
    wav: "audio/wav",
    pcm: "audio/pcm"
  }

  defp format_to_media_type(format) when is_atom(format) do
    Map.get(@format_media_types, format, "audio/mpeg")
  end

  defp format_to_media_type(_), do: "audio/mpeg"

  # When the response is binary (raw audio), error responses might also be
  # JSON that got decoded by Req's auto-decode step.
  defp parse_error_body(body) when is_map(body), do: body

  defp parse_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp parse_error_body(body), do: body
end

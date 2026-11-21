defmodule ReqLLM.Bedrock.NovaSonic do
  @moduledoc """
  Amazon Nova Sonic speech-to-speech client over Bedrock bidirectional streaming.

  Nova Sonic is driven by an ordered sequence of JSON events on a single HTTP/2
  bidirectional stream (see `ReqLLM.Bedrock.BidiStream`). This module provides the
  event builders and a small orchestration API on top:

      {:ok, s} = NovaSonic.start("amazon.nova-2-sonic-v1:0",
                   system_prompt: "You are a terse assistant.",
                   region: "us-east-1")

      # Continuous input: open one audio block, stream frames into it, close it.
      {:ok, s} = NovaSonic.start_audio(s)
      :ok = NovaSonic.send_audio(s, pcm_16bit_mono_chunks)
      {:ok, s} = NovaSonic.end_audio(s)
      # (or, one-shot: {:ok, s} = NovaSonic.audio_turn(s, pcm_16bit_mono_chunks))

      :ok = NovaSonic.finish(s)   # closes any open audio, then promptEnd + sessionEnd

      # consume model output (transcription, text, base64 audio)
      Stream.repeatedly(fn -> NovaSonic.next(s) end)
      |> Enum.take_while(&match?({:ok, _}, &1))

  Event schemas follow the Nova 2 Sonic bidirectional API.
  See [input events](https://docs.aws.amazon.com/nova/latest/nova2-userguide/sonic-input-events.html)
  and [output events](https://docs.aws.amazon.com/nova/latest/nova2-userguide/sonic-output-events.html).
  """

  alias ReqLLM.Bedrock.BidiStream

  @default_voice "matthew"
  # Output audio is 24kHz LPCM; input mic audio is typically 16kHz.
  @output_sample_rate 24_000
  @input_sample_rate 16_000

  defmodule Session do
    @moduledoc "A running Nova Sonic conversation."
    @enforce_keys [:conn, :prompt_name]
    defstruct [:conn, :prompt_name, :audio_content_name]

    @type t :: %__MODULE__{
            conn: term(),
            prompt_name: String.t(),
            audio_content_name: String.t() | nil
          }
  end

  @doc """
  Opens a bidirectional stream and runs the opening handshake:
  `sessionStart`, `promptStart`, and the SYSTEM text prompt.

  The default model is `amazon.nova-2-sonic-v1:0`.

  Options: `:system_prompt`, `:voice_id`, `:max_tokens`, `:top_p`, `:temperature`,
  `:output_sample_rate`, plus anything `BidiStream.connect/2` accepts
  (`:credentials`, `:region`).
  """
  @spec start(String.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def start(model_id \\ "amazon.nova-2-sonic-v1:0", opts \\ []) do
    with {:ok, conn} <- BidiStream.connect(model_id, opts) do
      prompt = ReqLLM.ID.uuid7()
      sys = ReqLLM.ID.uuid7()
      system_prompt = Keyword.get(opts, :system_prompt, "You are a helpful assistant.")

      with :ok <- BidiStream.send_event(conn, session_start(opts)),
           :ok <- BidiStream.send_event(conn, prompt_start(prompt, opts)),
           :ok <- BidiStream.send_event(conn, content_start_text(prompt, sys, "SYSTEM")),
           :ok <- BidiStream.send_event(conn, text_input(prompt, sys, system_prompt)),
           :ok <- BidiStream.send_event(conn, content_end(prompt, sys)) do
        {:ok, %Session{conn: conn, prompt_name: prompt}}
      end
    end
  end

  @doc """
  Opens a single USER audio content block (`contentStart[USER/AUDIO]`) and
  remembers its `contentName` on the session.

  Nova Sonic models continuous microphone input as one audio container that
  stays open across the whole interaction — barge-in and multi-turn detection
  happen within it via the server's VAD. Open it once, stream frames with
  `send_audio/3`, and close it with `end_audio/1` (or `finish/1`).
  """
  @spec start_audio(Session.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def start_audio(%Session{conn: conn, prompt_name: prompt} = session, opts \\ []) do
    content = ReqLLM.ID.uuid7()

    with :ok <- BidiStream.send_event(conn, content_start_audio(prompt, content, opts)) do
      {:ok, %{session | audio_content_name: content}}
    end
  end

  @doc """
  Streams PCM frames (a binary or list of binaries, 16-bit mono LPCM) into the
  open audio content block. Use `:pace_ms` to pace frames at roughly mic cadence.
  """
  @spec send_audio(Session.t(), iodata() | [binary()], keyword()) :: :ok | {:error, term()}
  def send_audio(session, pcm, opts \\ [])

  def send_audio(%Session{audio_content_name: nil}, _pcm, _opts),
    do: {:error, :no_open_audio_content}

  def send_audio(
        %Session{conn: conn, prompt_name: prompt, audio_content_name: content},
        pcm,
        opts
      ) do
    send_audio_chunks(conn, prompt, content, List.wrap(pcm), Keyword.get(opts, :pace_ms, 0))
  end

  @doc "Closes the open audio content block (`contentEnd`). No-op if none is open."
  @spec end_audio(Session.t()) :: {:ok, Session.t()} | {:error, term()}
  def end_audio(%Session{audio_content_name: nil} = session), do: {:ok, session}

  def end_audio(%Session{conn: conn, prompt_name: prompt, audio_content_name: content} = session) do
    with :ok <- BidiStream.send_event(conn, content_end(prompt, content)) do
      {:ok, %{session | audio_content_name: nil}}
    end
  end

  @doc """
  One-shot convenience: open an audio content block, stream all `chunks`, and
  close it. For continuous/multi-turn input, use `start_audio/2` + `send_audio/3`
  and keep the block open.
  """
  @spec audio_turn(Session.t(), iodata() | [binary()], keyword()) ::
          {:ok, Session.t()} | {:error, term()}
  def audio_turn(session, chunks, opts \\ []) do
    with {:ok, session} <- start_audio(session, opts),
         :ok <- send_audio(session, List.wrap(chunks), opts) do
      end_audio(session)
    end
  end

  @doc """
  Ends the interaction: closes any open audio content block, then sends
  `promptEnd` + `sessionEnd` and half-closes the request stream.
  """
  @spec finish(Session.t()) :: :ok | {:error, term()}
  def finish(%Session{conn: conn, prompt_name: prompt} = session) do
    with {:ok, _session} <- end_audio(session),
         :ok <- BidiStream.send_event(conn, prompt_end(prompt)),
         :ok <- BidiStream.send_event(conn, session_end()) do
      BidiStream.done_sending(conn)
    end
  end

  @doc """
  Pull the next output event, normalized to `{type, body}` (e.g.
  `{"textOutput", %{...}}`), or `:halt` / `{:error, reason}`.
  """
  @spec next(Session.t(), non_neg_integer()) ::
          {:ok, {String.t(), map()}} | {:ok, map()} | :halt | {:error, term()}
  def next(%Session{conn: conn}, timeout \\ 30_000) do
    case BidiStream.next_event(conn, timeout) do
      {:ok, %{"event" => event}} when is_map(event) ->
        [{type, body}] = Map.to_list(event)
        {:ok, {type, body}}

      other ->
        other
    end
  end

  @spec close(Session.t()) :: :ok
  def close(%Session{conn: conn}), do: BidiStream.close(conn)

  # --- event builders (pure) ---

  @doc false
  def session_start(opts \\ []) do
    wrap("sessionStart", %{
      "inferenceConfiguration" => %{
        "maxTokens" => Keyword.get(opts, :max_tokens, 1024),
        "topP" => Keyword.get(opts, :top_p, 0.9),
        "temperature" => Keyword.get(opts, :temperature, 0.7)
      }
    })
  end

  @doc false
  def prompt_start(prompt_name, opts \\ []) do
    wrap("promptStart", %{
      "promptName" => prompt_name,
      "textOutputConfiguration" => %{"mediaType" => "text/plain"},
      "audioOutputConfiguration" => %{
        "mediaType" => "audio/lpcm",
        "sampleRateHertz" => Keyword.get(opts, :output_sample_rate, @output_sample_rate),
        "sampleSizeBits" => 16,
        "channelCount" => 1,
        "voiceId" => Keyword.get(opts, :voice_id, @default_voice),
        "encoding" => "base64",
        "audioType" => "SPEECH"
      }
    })
  end

  @doc false
  def content_start_text(prompt_name, content_name, role) do
    wrap("contentStart", %{
      "promptName" => prompt_name,
      "contentName" => content_name,
      "type" => "TEXT",
      "interactive" => false,
      "role" => role,
      "textInputConfiguration" => %{"mediaType" => "text/plain"}
    })
  end

  @doc false
  def content_start_audio(prompt_name, content_name, opts \\ []) do
    wrap("contentStart", %{
      "promptName" => prompt_name,
      "contentName" => content_name,
      "type" => "AUDIO",
      "interactive" => true,
      "role" => "USER",
      "audioInputConfiguration" => %{
        "mediaType" => "audio/lpcm",
        "sampleRateHertz" => Keyword.get(opts, :input_sample_rate, @input_sample_rate),
        "sampleSizeBits" => 16,
        "channelCount" => 1,
        "audioType" => "SPEECH",
        "encoding" => "base64"
      }
    })
  end

  @doc false
  def text_input(prompt_name, content_name, content) do
    wrap("textInput", %{
      "promptName" => prompt_name,
      "contentName" => content_name,
      "content" => content
    })
  end

  @doc false
  def audio_input(prompt_name, content_name, pcm) when is_binary(pcm) do
    wrap("audioInput", %{
      "promptName" => prompt_name,
      "contentName" => content_name,
      "content" => Base.encode64(pcm)
    })
  end

  @doc false
  def content_end(prompt_name, content_name) do
    wrap("contentEnd", %{"promptName" => prompt_name, "contentName" => content_name})
  end

  @doc false
  def prompt_end(prompt_name), do: wrap("promptEnd", %{"promptName" => prompt_name})

  @doc false
  def session_end, do: wrap("sessionEnd", %{})

  # --- helpers ---

  defp send_audio_chunks(_conn, _prompt, _content, [], _pace), do: :ok

  defp send_audio_chunks(conn, prompt, content, [chunk | rest], pace) do
    case BidiStream.send_event(conn, audio_input(prompt, content, IO.iodata_to_binary(chunk))) do
      :ok ->
        if pace > 0, do: Process.sleep(pace)
        send_audio_chunks(conn, prompt, content, rest, pace)

      error ->
        error
    end
  end

  defp wrap(type, body), do: %{"event" => %{type => body}}
end

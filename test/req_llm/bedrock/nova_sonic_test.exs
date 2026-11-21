defmodule ReqLLM.Bedrock.NovaSonicTest do
  @moduledoc """
  Offline tests for Nova Sonic model selection and event handling.

  The model selection test removes the AWS access key so the transport stops
  before opening a network connection.
  """
  use ExUnit.Case, async: false

  alias ReqLLM.Bedrock.BidiStream
  alias ReqLLM.Bedrock.NovaSonic

  describe "start" do
    test "passes the Nova 2 Sonic default and explicit model IDs to the transport" do
      key = "AWS_ACCESS_KEY_ID"
      previous_key = System.get_env(key)
      System.delete_env(key)

      pattern = {BidiStream, :connect, 2}
      Code.ensure_loaded!(BidiStream)
      :erlang.trace_pattern(pattern, true, [])

      on_exit(fn ->
        :erlang.trace_pattern(pattern, false, [])
        if previous_key, do: System.put_env(key, previous_key)
      end)

      explicit_model = "amazon.nova-sonic-v1:0"

      {worker, monitor} =
        spawn_monitor(fn ->
          Process.flag(:trap_exit, true)

          receive do
            :start ->
              NovaSonic.start()
              NovaSonic.start(explicit_model)
          end
        end)

      :erlang.trace(worker, true, [:call, {:tracer, self()}])
      send(worker, :start)

      assert_receive {:trace, ^worker, :call,
                      {BidiStream, :connect, ["amazon.nova-2-sonic-v1:0", []]}},
                     1_000

      assert_receive {:trace, ^worker, :call, {BidiStream, :connect, [^explicit_model, []]}}
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    end
  end

  describe "input event builders" do
    test "session_start carries inference configuration" do
      assert NovaSonic.session_start(max_tokens: 256, top_p: 0.8, temperature: 0.5) ==
               %{
                 "event" => %{
                   "sessionStart" => %{
                     "inferenceConfiguration" => %{
                       "maxTokens" => 256,
                       "topP" => 0.8,
                       "temperature" => 0.5
                     }
                   }
                 }
               }
    end

    test "prompt_start sets text + audio output configuration" do
      default_prompt = NovaSonic.prompt_start("p1")

      assert get_in(default_prompt, [
               "event",
               "promptStart",
               "audioOutputConfiguration",
               "voiceId"
             ]) ==
               "matthew"

      %{"event" => %{"promptStart" => ps}} = NovaSonic.prompt_start("p1", voice_id: "tiffany")

      assert ps["promptName"] == "p1"
      assert ps["textOutputConfiguration"] == %{"mediaType" => "text/plain"}
      assert ps["audioOutputConfiguration"]["voiceId"] == "tiffany"
      assert ps["audioOutputConfiguration"]["mediaType"] == "audio/lpcm"
      assert ps["audioOutputConfiguration"]["sampleRateHertz"] == 24_000
      assert ps["audioOutputConfiguration"]["encoding"] == "base64"
    end

    test "content_start_text marks a TEXT block with role" do
      %{"event" => %{"contentStart" => cs}} = NovaSonic.content_start_text("p1", "c1", "SYSTEM")

      assert cs == %{
               "promptName" => "p1",
               "contentName" => "c1",
               "type" => "TEXT",
               "interactive" => false,
               "role" => "SYSTEM",
               "textInputConfiguration" => %{"mediaType" => "text/plain"}
             }
    end

    test "content_start_audio marks an interactive USER AUDIO block at 16kHz" do
      %{"event" => %{"contentStart" => cs}} = NovaSonic.content_start_audio("p1", "c1")
      assert cs["type"] == "AUDIO"
      assert cs["role"] == "USER"
      assert cs["interactive"] == true
      assert cs["audioInputConfiguration"]["sampleRateHertz"] == 16_000
      assert cs["audioInputConfiguration"]["mediaType"] == "audio/lpcm"
    end

    test "audio_input base64-encodes the PCM" do
      pcm = <<0, 1, 2, 3, 4, 5>>
      %{"event" => %{"audioInput" => ai}} = NovaSonic.audio_input("p1", "c1", pcm)
      assert ai["content"] == Base.encode64(pcm)
      assert ai["promptName"] == "p1"
      assert ai["contentName"] == "c1"
    end

    test "text_input / content_end / prompt_end / session_end shapes" do
      assert NovaSonic.text_input("p", "c", "hi") ==
               %{
                 "event" => %{
                   "textInput" => %{"promptName" => "p", "contentName" => "c", "content" => "hi"}
                 }
               }

      assert NovaSonic.content_end("p", "c") ==
               %{"event" => %{"contentEnd" => %{"promptName" => "p", "contentName" => "c"}}}

      assert NovaSonic.prompt_end("p") == %{"event" => %{"promptEnd" => %{"promptName" => "p"}}}
      assert NovaSonic.session_end() == %{"event" => %{"sessionEnd" => %{}}}
    end
  end

  # Records the events NovaSonic sends, standing in for a BidiStream session.
  defmodule StubConn do
    use GenServer
    def start_link, do: GenServer.start_link(__MODULE__, [])
    @impl true
    def init(_), do: {:ok, []}
    @impl true
    def handle_call({:send_event, ev}, _from, acc), do: {:reply, :ok, [ev | acc]}
    def handle_call(:events, _from, acc), do: {:reply, Enum.reverse(acc), acc}
    def events(pid), do: GenServer.call(pid, :events)
  end

  describe "audio content lifecycle" do
    setup do
      {:ok, pid} = StubConn.start_link()
      conn = %BidiStream.Conn{pid: pid, model_id: "amazon.nova-2-sonic-v1:0"}
      {:ok, session: %NovaSonic.Session{conn: conn, prompt_name: "p1"}, pid: pid}
    end

    test "audio_turn opens, sends and closes a single audio block", %{session: s, pid: pid} do
      pcm = <<0, 1, 2, 3>>
      encoded = Base.encode64(pcm)

      assert {:ok, %NovaSonic.Session{audio_content_name: nil}} = NovaSonic.audio_turn(s, pcm)

      assert [
               %{"event" => %{"contentStart" => %{"type" => "AUDIO", "contentName" => content}}},
               %{
                 "event" => %{"audioInput" => %{"contentName" => content, "content" => ^encoded}}
               },
               %{"event" => %{"contentEnd" => %{"contentName" => content}}}
             ] = StubConn.events(pid)
    end

    test "one audio container stays open across many send_audio calls", %{session: s, pid: pid} do
      {:ok, s} = NovaSonic.start_audio(s)
      content = s.audio_content_name
      assert is_binary(content)

      :ok = NovaSonic.send_audio(s, <<0, 1, 2, 3>>)
      :ok = NovaSonic.send_audio(s, [<<4, 5>>, <<6, 7>>])
      {:ok, s} = NovaSonic.end_audio(s)
      assert s.audio_content_name == nil

      events = StubConn.events(pid)
      # contentStart(AUDIO) + 3 audioInput frames + contentEnd, all one content name
      types = Enum.map(events, fn %{"event" => e} -> e |> Map.keys() |> hd() end)
      assert types == ["contentStart", "audioInput", "audioInput", "audioInput", "contentEnd"]

      names =
        events
        |> Enum.map(fn %{"event" => e} -> e |> Map.values() |> hd() end)
        |> Enum.map(& &1["contentName"])

      assert Enum.uniq(names) == [content]
    end

    test "send_audio without an open block is an error", %{session: s} do
      assert NovaSonic.send_audio(s, <<0, 0>>) == {:error, :no_open_audio_content}
    end

    test "end_audio is a no-op when nothing is open", %{session: s} do
      assert {:ok, ^s} = NovaSonic.end_audio(s)
    end
  end
end

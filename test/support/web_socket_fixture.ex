defmodule ReqLLM.Test.WebSocketFixture do
  @moduledoc """
  Records public Responses session calls and raw server events in order.

  Replay uses a local WebSocket server and checks every client frame against
  the recording. No credentials or connection headers enter the transcript.
  A fixture is saved only after its test callback succeeds.
  """

  import ExUnit.Assertions

  alias ReqLLM.OpenAI.Responses
  alias ReqLLM.Test.Fixtures

  defmodule Replay do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts), do: WebSockAdapter.upgrade(conn, __MODULE__.Socket, opts, [])

    defmodule Socket do
      @moduledoc false
      @behaviour WebSock

      @impl true
      def init(state), do: {:ok, state}

      @impl true
      def handle_in({message, _opts}, %{frames: [expected | rest]} = state) do
        actual = %{"direction" => "client", "event" => Jason.decode!(message)}

        if actual == expected do
          {events, remaining} = Enum.split_while(rest, &(&1["direction"] == "server"))
          if remaining == [], do: send(state.owner, {state.ref, :consumed})
          messages = Enum.map(events, &{:text, Jason.encode!(&1["event"])})
          {:push, messages, %{state | frames: remaining}}
        else
          send(state.owner, {state.ref, {:mismatch, expected, actual}})
          {:stop, :normal, state}
        end
      end

      def handle_in({message, _opts}, state) do
        send(state.owner, {state.ref, {:unexpected_frame, Jason.decode!(message)}})
        {:stop, :normal, state}
      end

      @impl true
      def handle_info(_message, state), do: {:ok, state}
    end
  end

  def run(model, name, callback) do
    mode = Fixtures.mode()
    {:ok, capture} = Agent.start_link(fn -> [] end)
    {opts, server, ref} = connection_options(mode, model, name)

    try do
      {:ok, session} = Responses.connect(model, opts)

      try do
        result = callback.(%{session: session, capture: capture})
        frames = Agent.get(capture, &Enum.reverse/1)
        finish(mode, model, name, ref, frames)
        result
      after
        Responses.close(session)
      end
    after
      Agent.stop(capture)
      if server, do: Supervisor.stop(server)
    end
  end

  def create(connection, payload) do
    model = connection.session.model

    capture(
      connection,
      "client",
      Map.merge(payload, %{
        "type" => "response.create",
        "model" => model.provider_model_id || model.id
      })
    )

    assert :ok = Responses.response_create(connection.session, payload)
  end

  def steer(connection, response_id, input) do
    capture(connection, "client", %{
      "type" => "response.steer",
      "previous_response_id" => response_id,
      "input" => input
    })

    assert :ok = Responses.steer(connection.session, response_id, input)
  end

  def next(connection) do
    assert {:ok, event} = Responses.next_event(connection.session, 120_000)
    capture(connection, "server", event)
    refute event["type"] in ["error", "response.failed", "response.steer.failed"], inspect(event)
    event
  end

  def until(connection, predicate, events \\ []) do
    event = next(connection)

    if predicate.(event),
      do: Enum.reverse([event | events]),
      else: until(connection, predicate, [event | events])
  end

  defp capture(connection, direction, event) do
    Agent.update(connection.capture, &[%{"direction" => direction, "event" => event} | &1])
  end

  defp connection_options(:record, _model, _name), do: {[connect_timeout: 15_000], nil, nil}

  defp connection_options(:replay, model, name) do
    {:fixture, path} = Fixtures.replay_path(model, fixture: name)

    %{"format" => "responses_websocket_v1", "frames" => frames} =
      path |> File.read!() |> Jason.decode!()

    ref = make_ref()
    state = %{frames: frames, owner: self(), ref: ref}
    {:ok, server} = Bandit.start_link(plug: {Replay, state}, port: 0, ip: {127, 0, 0, 1})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    {[base_url: "http://127.0.0.1:#{port}/v1", api_key: "fixture-key"], server, ref}
  end

  defp finish(:record, model, name, _ref, frames) do
    path = Fixtures.capture_path(model, fixture: name)
    File.mkdir_p!(Path.dirname(path))

    fixture = %{
      "format" => "responses_websocket_v1",
      "request" => %{"url" => "wss://api.openai.com/v1/responses"},
      "frames" => frames
    }

    File.write!(path, Jason.encode!(fixture, pretty: true) <> "\n")
  end

  defp finish(:replay, model, name, ref, frames) do
    assert_receive {^ref, :consumed}, 1_000
    refute_received {^ref, {:mismatch, _, _}}
    refute_received {^ref, {:unexpected_frame, _}}
    {:fixture, path} = Fixtures.replay_path(model, fixture: name)
    fixture = path |> File.read!() |> Jason.decode!()
    assert frames == fixture["frames"]
  end
end

defmodule ReqLLM.OpenTelemetry.StorageTest do
  use ExUnit.Case, async: false

  alias ReqLLM.OpenTelemetry
  alias ReqLLM.OpenTelemetry.Storage

  defmodule Adapter do
    def available?, do: true

    def start_span(_, _, config) do
      span = make_ref()
      send(config[:test_pid], {:span_started, span})
      span
    end

    def set_attributes(_, _, _), do: :ok
    def add_event(_, _, _, _), do: :ok
    def set_status(_, _, _, _), do: :ok

    def end_span(span, config) do
      send(config[:test_pid], {:span_ended, span})
      :ok
    end
  end

  test "attach caller death preserves spans and the instrument cache" do
    owner = self()
    id = "storage-owner-test"
    on_exit(fn -> OpenTelemetry.detach(id) end)

    caller =
      spawn(fn ->
        :ok = OpenTelemetry.attach(id, adapter: Adapter, test_pid: owner)
        :ets.insert(:req_llm_open_telemetry_instruments, {:storage_probe, :instrument})
        send(owner, :attached)

        receive do
          :exit -> :ok
        end
      end)

    assert_receive :attached
    ref = Process.monitor(caller)
    metadata = %{request_id: "storage-probe", provider: :openai, model: "gpt-5", operation: :chat}

    :telemetry.execute(
      [:req_llm, :request, :start],
      %{system_time: System.system_time()},
      metadata
    )

    assert_receive {:span_started, span}
    send(caller, :exit)
    assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
    storage = Process.whereis(Storage)
    assert :ets.info(:req_llm_open_telemetry_spans, :owner) == storage
    assert :ets.info(:req_llm_open_telemetry_instruments, :owner) == storage

    assert :ets.lookup(:req_llm_open_telemetry_instruments, :storage_probe) == [
             {:storage_probe, :instrument}
           ]

    :telemetry.execute([:req_llm, :request, :stop], %{duration: 1}, metadata)
    assert_receive {:span_ended, ^span}
    :ets.delete(:req_llm_open_telemetry_instruments, :storage_probe)
  end

  test "owner restart resets storage and accepts new spans without handler errors" do
    id = "storage-restart-test"
    :ok = OpenTelemetry.attach(id, adapter: Adapter, test_pid: self())
    on_exit(fn -> OpenTelemetry.detach(id) end)

    metadata = %{
      request_id: "before-restart",
      provider: :openai,
      model: "gpt-5",
      operation: :chat
    }

    :telemetry.execute(
      [:req_llm, :request, :start],
      %{system_time: System.system_time()},
      metadata
    )

    assert_receive {:span_started, old_span}
    :ok = Supervisor.terminate_child(ReqLLM.Supervisor, Storage)
    assert {:ok, _pid} = Supervisor.restart_child(ReqLLM.Supervisor, Storage)
    assert :ets.lookup(:req_llm_open_telemetry_spans, {id, "before-restart"}) == []
    :telemetry.execute([:req_llm, :request, :stop], %{duration: 1}, metadata)
    refute_receive {:span_ended, ^old_span}, 10
    metadata = %{metadata | request_id: "after-restart"}

    :telemetry.execute(
      [:req_llm, :request, :start],
      %{system_time: System.system_time()},
      metadata
    )

    assert_receive {:span_started, new_span}
    :telemetry.execute([:req_llm, :request, :stop], %{duration: 1}, metadata)
    assert_receive {:span_ended, ^new_span}
    assert OpenTelemetry.prune_stale_spans(id, 0) == 0
  end
end

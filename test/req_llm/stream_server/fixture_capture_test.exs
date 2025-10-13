# Mock backend for testing fixture capture
# This intentionally redefines the module to intercept calls during tests
# credo:disable-for-this-file Credo.Check.Consistency.MultiAliasImportRequireUse
Code.compiler_options(ignore_module_conflict: true)

defmodule ReqLLM.Step.Fixture.Backend do
  @moduledoc false

  def save_streaming_fixture(http_context, fixture_path, canonical_json, model, raw_iodata) do
    if Process.whereis(:fixture_calls) do
      Agent.update(:fixture_calls, fn calls ->
        [{http_context, fixture_path, canonical_json, model, raw_iodata} | calls]
      end)
    end

    :ok
  end
end

Code.compiler_options(ignore_module_conflict: false)

defmodule ReqLLM.StreamServer.FixtureCaptureTest do
  use ExUnit.Case, async: false

  import ReqLLM.Test.StreamServerHelpers

  alias ReqLLM.StreamServer

  setup do
    # Stop any existing agent from previous tests
    if pid = Process.whereis(:fixture_calls) do
      Process.exit(pid, :kill)
      :timer.sleep(10)
    end

    {:ok, _pid} = Agent.start_link(fn -> [] end, name: :fixture_calls)

    on_exit(fn ->
      if pid = Process.whereis(:fixture_calls) do
        Process.exit(pid, :kill)
      end
    end)

    :ok
  end

  describe "fixture capture" do
    test "saves streaming fixture exactly once" do
      server = start_server(fixture_path: "test/fixture.json")

      StreamServer.set_fixture_context(server, %{request: %{}, response: %{}}, %{})

      StreamServer.http_event(server, {:data, "chunk1"})
      StreamServer.http_event(server, {:data, "chunk2"})

      StreamServer.http_event(server, :done)
      StreamServer.http_event(server, :done)

      calls = Agent.get(:fixture_calls, & &1)

      assert length(calls) == 1
      [{context, path, canonical_json, _model, raw_iodata}] = calls

      assert path == "test/fixture.json"
      assert IO.iodata_to_binary(raw_iodata) == "chunk1chunk2"
      assert context == %{request: %{}, response: %{}}
      assert canonical_json == %{}
    end

    test "fixture_path set but no http_context does not save" do
      server = start_server(fixture_path: "test/fixture.json")

      StreamServer.http_event(server, {:data, "chunk1"})
      StreamServer.http_event(server, :done)

      calls = Agent.get(:fixture_calls, & &1)

      assert calls == []
    end

    test "accumulates raw_iodata correctly across multiple chunks" do
      server = start_server(fixture_path: "test/fixture.json")

      StreamServer.set_fixture_context(server, %{request: %{}, response: %{}}, %{})

      StreamServer.http_event(server, {:data, "first"})
      StreamServer.http_event(server, {:data, "second"})
      StreamServer.http_event(server, {:data, "third"})
      StreamServer.http_event(server, :done)

      calls = Agent.get(:fixture_calls, & &1)

      assert length(calls) == 1
      [{_context, _path, _canonical_json, _model, raw_iodata}] = calls

      assert IO.iodata_to_binary(raw_iodata) == "firstsecondthird"
    end
  end
end

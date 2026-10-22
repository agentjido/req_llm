defmodule ReqLLM.TidewaveStartupTest do
  use ExUnit.Case, async: false

  setup do
    original_env = Map.new(["TIDEWAVE_REPL", "TIDEWAVE_PORT"], &{&1, System.get_env(&1)})

    on_exit(fn ->
      Application.stop(:req_llm)

      Enum.each(original_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Application.ensure_all_started(:req_llm)
    end)

    :ok
  end

  test "starts without Tidewave when the REPL flag is unset" do
    System.delete_env("TIDEWAVE_REPL")
    System.put_env("TIDEWAVE_PORT", "invalid")

    assert {:ok, _} = restart_req_llm()
  end

  test "ignores the REPL flag outside development even when it is enabled" do
    System.put_env("TIDEWAVE_REPL", "true")
    System.put_env("TIDEWAVE_PORT", "invalid")

    refute Code.ensure_loaded?(Tidewave)
    assert {:ok, _} = restart_req_llm()

    refute Enum.any?(Supervisor.which_children(ReqLLM.Supervisor), fn {_, _, _, modules} ->
             Bandit in modules
           end)
  end

  defp restart_req_llm do
    :ok = Application.stop(:req_llm)
    Application.ensure_all_started(:req_llm)
  end
end

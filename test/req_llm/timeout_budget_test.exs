defmodule ReqLLM.TimeoutBudgetTest do
  use ExUnit.Case, async: false

  alias ReqLLM.TimeoutBudget

  setup do
    total_timeout = Application.get_env(:req_llm, :total_timeout)
    stream_idle_timeout = Application.get_env(:req_llm, :stream_idle_timeout)

    on_exit(fn ->
      restore_env(:total_timeout, total_timeout)
      restore_env(:stream_idle_timeout, stream_idle_timeout)
    end)

    Application.delete_env(:req_llm, :total_timeout)
    Application.delete_env(:req_llm, :stream_idle_timeout)
    :ok
  end

  test "preserves unlimited and legacy defaults when options are omitted" do
    assert TimeoutBudget.total_timeout([]) == :infinity
    assert TimeoutBudget.stream_idle_timeout([]) == :legacy
    assert TimeoutBudget.deadline([]) == :infinity
  end

  test "reads opt-in application defaults and lets call options win" do
    Application.put_env(:req_llm, :total_timeout, 30_000)
    Application.put_env(:req_llm, :stream_idle_timeout, 5_000)

    assert TimeoutBudget.total_timeout([]) == 30_000
    assert TimeoutBudget.total_timeout(total_timeout: 60_000) == 60_000
    assert TimeoutBudget.stream_idle_timeout([]) == {:configured, 5_000}

    assert TimeoutBudget.stream_idle_timeout(stream_idle_timeout: :infinity) ==
             {:configured, :infinity}
  end

  test "rejects invalid application defaults" do
    Application.put_env(:req_llm, :total_timeout, 0)

    assert_raise ReqLLM.Error.Invalid.Parameter, ~r/total_timeout/, fn ->
      TimeoutBudget.total_timeout([])
    end

    Application.put_env(:req_llm, :stream_idle_timeout, "slow")

    assert_raise ReqLLM.Error.Invalid.Parameter, ~r/stream_idle_timeout/, fn ->
      TimeoutBudget.stream_idle_timeout([])
    end
  end

  test "bounds retries within the total deadline" do
    test_pid = self()

    request =
      Req.new(
        url: "https://example.invalid",
        adapter: fn request ->
          send(test_pid, :budget_attempt)
          Process.sleep(120)
          {request, %Req.TransportError{reason: :closed}}
        end
      )
      |> ReqLLM.Step.Retry.attach(max_retries: 3)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, %ReqLLM.Error.API.Timeout{kind: :total, timeout: 200}} =
             TimeoutBudget.request(request, TimeoutBudget.deadline(total_timeout: 200))

    assert System.monotonic_time(:millisecond) - started_at < 350
    assert_receive :budget_attempt
    assert_receive :budget_attempt, 250
    refute_receive :budget_attempt, 100
    refute_receive {ReqLLM.TimeoutBudget, _capture_ref, _context}
  end

  test "preserves request exceptions under a finite budget" do
    request =
      Req.new(
        url: "https://example.invalid",
        adapter: fn _request -> raise "adapter failed" end
      )

    assert_raise RuntimeError, "adapter failed", fn ->
      TimeoutBudget.request(request, TimeoutBudget.deadline(total_timeout: 1_000))
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:req_llm, key)
  defp restore_env(key, value), do: Application.put_env(:req_llm, key, value)
end

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
    attempts = :atomics.new(1, [])

    request =
      Req.new(
        url: "https://example.invalid",
        adapter: fn request ->
          :atomics.add(attempts, 1, 1)
          Process.sleep(120)
          {request, %Req.TransportError{reason: :closed}}
        end
      )
      |> ReqLLM.Step.Retry.attach(max_retries: 3)

    assert {:error, %ReqLLM.Error.API.Timeout{kind: :total, timeout: 200}} =
             TimeoutBudget.request(request, TimeoutBudget.deadline(total_timeout: 200))

    assert :atomics.get(attempts, 1) == 2
    refute_received {ReqLLM.TimeoutBudget, _capture_ref, _context}
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

  for budget <- [1_000, :infinity] do
    @budget budget

    test "preserves the caller's OpenTelemetry context with a #{@budget} budget" do
      parent = :otel_tracer.from_remote_span(123, 456, 1)

      caller_ctx =
        :otel_ctx.new()
        |> :otel_tracer.set_current_span(parent)
        |> :otel_baggage.set("timeout-test", "caller")

      token = :otel_ctx.attach(caller_ctx)
      test_pid = self()

      request =
        Req.new(
          url: "https://example.invalid",
          adapter: fn request ->
            send(test_pid, {:request_ctx, self(), :otel_ctx.get_current()})
            {request, Req.Response.new(status: 200)}
          end
        )

      try do
        assert {:ok, %Req.Response{status: 200}} =
                 TimeoutBudget.request(request, TimeoutBudget.deadline(total_timeout: @budget))

        assert_received {:request_ctx, request_pid, ^caller_ctx}
        assert :otel_tracer.current_span_ctx() == parent
        assert :otel_baggage.get_all() == %{"timeout-test" => {"caller", []}}

        if @budget == :infinity do
          assert request_pid == self()
        else
          assert request_pid != self()
        end
      after
        :otel_ctx.detach(token)
      end
    end
  end

  test "isolates task context changes from the caller and subsequent requests" do
    caller_ctx = :otel_ctx.new() |> :otel_ctx.set_value(:caller, make_ref())
    token = :otel_ctx.attach(caller_ctx)

    request =
      Req.new(
        url: "https://example.invalid",
        adapter: fn request ->
          assert :otel_ctx.get_current() == caller_ctx
          :otel_ctx.set_value(:task_only, true)
          {request, Req.Response.new(status: 200)}
        end
      )

    try do
      for _ <- 1..2 do
        assert {:ok, %Req.Response{status: 200}} =
                 TimeoutBudget.request(request, TimeoutBudget.deadline(total_timeout: 1_000))

        assert :otel_ctx.get_current() == caller_ctx
      end
    after
      :otel_ctx.detach(token)
    end
  end

  test "accepts a finite budget without an active OpenTelemetry context" do
    token = :otel_ctx.attach(:otel_ctx.new())

    request =
      Req.new(
        url: "https://example.invalid",
        adapter: fn request ->
          assert :otel_ctx.get_current() == %{}
          {request, Req.Response.new(status: 200)}
        end
      )

    try do
      assert {:ok, %Req.Response{status: 200}} =
               TimeoutBudget.request(request, TimeoutBudget.deadline(total_timeout: 1_000))
    after
      :otel_ctx.detach(token)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:req_llm, key)
  defp restore_env(key, value), do: Application.put_env(:req_llm, key, value)
end

defmodule ReqLLM.TransportTest do
  use ExUnit.Case, async: false

  alias ReqLLM.TimeoutBudget

  @finch ReqLLM.TransportTest.Finch

  defmodule OptionsAdapter do
    def run(request), do: {request, %Req.Response{status: 200, body: request.options}}
  end

  defmodule FailingAdapter do
    def run(_request), do: raise("adapter failed")
  end

  defmodule CompletionPlug do
    @behaviour Plug

    def init(owner), do: owner

    def call(conn, owner) do
      label = List.first(Plug.Conn.get_req_header(conn, "x-test-call"))
      send(owner, {:provider_call, self(), label})

      receive do
        :reply -> :ok
      after
        15_000 -> raise "test response was not released"
      end

      body = %{
        id: "chatcmpl-test",
        object: "chat.completion",
        model: "gpt-4o-mini",
        choices: [
          %{index: 0, message: %{role: "assistant", content: "hi"}, finish_reason: "stop"}
        ],
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end
  end

  test "uses the receive timeout for pool checkout and keeps infinite receives finite" do
    for {options, expected} <- [
          {[], 30_000},
          {[receive_timeout: 42_000], 42_000},
          {[receive_timeout: :infinity], 30_000},
          {[receive_timeout: 42_000, finch: [pool_timeout: 10]], 10}
        ] do
      request = Req.new([url: "https://example.invalid", adapter: OptionsAdapter] ++ options)

      assert {:ok, response} = TimeoutBudget.request(request, :infinity)
      assert response.body.finch[:pool_timeout] == expected
    end
  end

  test "preserves nested Finch timeout options" do
    request =
      Req.new(
        url: "https://example.invalid",
        adapter: OptionsAdapter,
        receive_timeout: 42_000,
        finch: [name: @finch, pool_timeout: 10, pool_tag: :bulk]
      )

    assert {:ok, response} = TimeoutBudget.request(request, :infinity)
    assert response.body.finch == [name: @finch, pool_timeout: 10, pool_tag: :bulk]
  end

  test "preserves unrelated adapter exceptions with finite and unlimited budgets" do
    request = Req.new(url: "https://example.invalid", adapter: FailingAdapter)

    for deadline <- [:infinity, TimeoutBudget.deadline(total_timeout: 1_000)] do
      assert_raise RuntimeError, "adapter failed", fn ->
        TimeoutBudget.request(request, deadline)
      end
    end
  end

  test "all eight default connections can serve overlapping calls" do
    url = start_server()

    tasks =
      for index <- 1..8 do
        Task.async(fn -> generate_text(url, ReqLLM.Application.finch_name(), "#{index}") end)
      end

    connections =
      for _ <- 1..8 do
        assert_receive {:provider_call, pid, _label}, 2_000
        pid
      end

    Enum.each(connections, &send(&1, :reply))
    Enum.each(tasks, fn task -> assert {:ok, _} = Task.await(task, 2_000) end)
  end

  test "a queued call can wait more than Finch's five-second default" do
    url = start_server()
    start_pool()
    first = Task.async(fn -> generate_text(url, @finch, "first") end)
    assert_receive {:provider_call, first_connection, "first"}, 2_000

    second = Task.async(fn -> generate_text(url, @finch, "second") end)
    assert Task.yield(second, 5_100) == nil

    send(first_connection, :reply)
    assert {:ok, _} = Task.await(first, 2_000)
    assert_receive {:provider_call, second_connection, "second"}, 2_000
    send(second_connection, :reply)
    assert {:ok, _} = Task.await(second, 2_000)
  end

  test "checkout failures return errors for text and object calls under both budgets" do
    url = start_server()
    start_pool()
    handler = "pool-timeout-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:req_llm, :request, :exception],
      &__MODULE__.handle_exception/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    holder = Task.async(fn -> generate_text(url, @finch, "holder") end)
    assert_receive {:provider_call, connection, "holder"}, 2_000

    for budget <- [[], [total_timeout: 1_000]], operation <- [:text, :object] do
      opts =
        request_options(url, "queued", finch: [name: @finch, pool_timeout: 25]) ++ budget

      result =
        case operation do
          :text ->
            ReqLLM.generate_text("openai:gpt-4o-mini", "hi", opts)

          :object ->
            ReqLLM.generate_object("openai:gpt-4o-mini", "hi", [answer: [type: :string]], opts)
        end

      assert {:error, %ReqLLM.Error.API.Request{cause: %RuntimeError{}} = error} = result
      assert error.reason =~ "Finch was unable to provide a connection"
      assert is_binary(error.request_body)
      assert_receive {:queue_exception, measurements, %{error: ^error}}
      assert System.convert_time_unit(measurements.duration, :native, :millisecond) >= 25
      refute_received {:provider_call, _, "queued"}
    end

    send(connection, :reply)
    assert {:ok, _} = Task.await(holder, 2_000)
  end

  def handle_exception(_event, measurements, metadata, owner) do
    send(owner, {:queue_exception, measurements, metadata})
  end

  test "total timeout bounds a longer pool checkout wait" do
    url = start_server()
    start_pool()
    holder = Task.async(fn -> generate_text(url, @finch, "holder") end)
    assert_receive {:provider_call, connection, "holder"}, 2_000

    assert {:error, %ReqLLM.Error.API.Timeout{kind: :total, timeout: 50}} =
             generate_text(url, @finch, "queued", total_timeout: 50)

    refute_received {:provider_call, _, "queued"}
    send(connection, :reply)
    assert {:ok, _} = Task.await(holder, 2_000)
  end

  defp start_server do
    server =
      start_supervised!({Bandit, plug: {CompletionPlug, self()}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    "http://localhost:#{port}"
  end

  defp start_pool do
    start_supervised!({Finch, name: @finch, pools: %{default: [size: 1, count: 1]}})
  end

  defp generate_text(url, finch, label, extra \\ []) do
    opts = request_options(url, label, finch: finch) ++ extra
    ReqLLM.generate_text("openai:gpt-4o-mini", "hi", opts)
  end

  defp request_options(url, label, http_opts) do
    [
      base_url: url,
      api_key: "test",
      receive_timeout: 10_000,
      max_retries: 0,
      req_http_options: [headers: [{"x-test-call", label}]] ++ http_opts
    ]
  end
end

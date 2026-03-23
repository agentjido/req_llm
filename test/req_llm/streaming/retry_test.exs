defmodule ReqLLM.Streaming.RetryTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Streaming.Retry

  test "retries transient transport errors before any data is received" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    stream_fun = fn _request, _finch_name, acc, callback, _opts ->
      attempt = Agent.get_and_update(counter, fn current -> {current + 1, current + 1} end)
      acc = callback.({:status, 200}, acc)
      acc = callback.({:headers, [{"content-type", "text/event-stream"}]}, acc)

      case attempt do
        1 ->
          {:error, %Mint.TransportError{reason: :closed}, acc}

        2 ->
          acc = callback.({:data, "hello"}, acc)
          acc = callback.(:done, acc)
          {:ok, acc}
      end
    end

    callback = fn event, acc -> [event | acc] end

    assert {:ok, events} =
             Retry.stream(
               Finch.build(:post, "https://example.com/stream"),
               ReqLLM.Finch,
               [],
               callback,
               [max_retries: 1, receive_timeout: 1_000],
               stream_fun
             )

    assert Agent.get(counter, & &1) == 2

    assert Enum.reverse(events) == [
             {:status, 200},
             {:headers, [{"content-type", "text/event-stream"}]},
             {:data, "hello"},
             :done
           ]
  end

  test "does not retry transient transport errors after data has been received" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    stream_fun = fn _request, _finch_name, acc, callback, _opts ->
      Agent.update(counter, &(&1 + 1))
      acc = callback.({:data, "partial"}, acc)
      {:error, %Mint.TransportError{reason: :timeout}, acc}
    end

    callback = fn event, acc -> [event | acc] end

    assert {:error, %Mint.TransportError{reason: :timeout}, events} =
             Retry.stream(
               Finch.build(:post, "https://example.com/stream"),
               ReqLLM.Finch,
               [],
               callback,
               [max_retries: 3, receive_timeout: 1_000],
               stream_fun
             )

    assert Agent.get(counter, & &1) == 1
    assert Enum.reverse(events) == [{:data, "partial"}]
  end

  test "does not retry non-retryable transport errors" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    stream_fun = fn _request, _finch_name, acc, _callback, _opts ->
      Agent.update(counter, &(&1 + 1))
      {:error, %Mint.TransportError{reason: :protocol_not_negotiated}, acc}
    end

    callback = fn event, acc -> [event | acc] end

    assert {:error, %Mint.TransportError{reason: :protocol_not_negotiated}, []} =
             Retry.stream(
               Finch.build(:post, "https://example.com/stream"),
               ReqLLM.Finch,
               [],
               callback,
               [max_retries: 3, receive_timeout: 1_000],
               stream_fun
             )

    assert Agent.get(counter, & &1) == 1
  end
end

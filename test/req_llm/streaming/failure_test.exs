defmodule ReqLLM.Streaming.FailureTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ReqLLM.Streaming.Failure

  test "classifies structured HTTP failures as retryable provider/API failures" do
    error =
      Failure.api_error(
        429,
        ~s({"error":{"code":"traffic_queue_timeout","message":"traffic queue wait expired"}}),
        [{"retry-after", "1"}]
      )

    assert error.status == 429
    assert error.provider_code == "traffic_queue_timeout"
    assert error.retryable == true
    assert error.reason == "traffic queue wait expired"

    assert %{
             category: :api,
             severity: :warning,
             status: 429,
             provider_code: "traffic_queue_timeout",
             retryable: true
           } = Failure.classify(error)

    log = capture_log(fn -> Failure.log(error) end)

    assert log =~ "Streaming provider/API request failed"
    assert log =~ "status=429"
    assert log =~ "provider_code=\"traffic_queue_timeout\""
    refute log =~ "Finch streaming failed"
  end

  test "marks streamed 503 responses as retryable API failures" do
    error = Failure.api_error(503, ~s({"error":{"code":"overloaded"}}), [])

    assert %{category: :api, status: 503, provider_code: "overloaded", retryable: true} =
             Failure.classify(error)
  end

  test "classifies Finch errors backed by Mint as transport failures" do
    error = %Finch.TransportError{source: %Mint.TransportError{reason: :closed}}

    assert %{
             category: :transport,
             severity: :error,
             transport_reason: :closed,
             retryable: true
           } = Failure.classify(error)

    log = capture_log(fn -> Failure.log(error) end)

    assert log =~ "Finch streaming transport failed"
    assert log =~ "reason=:closed"
  end

  test "treats expected cancellation as a non-logged terminal outcome" do
    assert %{category: :cancelled, severity: nil, retryable: false} =
             Failure.classify({:exit, :cancelled})

    assert capture_log(fn -> Failure.log({:exit, :cancelled}) end) == ""
  end
end
